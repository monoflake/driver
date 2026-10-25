//! What the tests of `Containers` share, its containerd, network, btrfs and fetch faked, and the
//! deployments they send.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]
#![allow(dead_code, reason = "each test file uses its own part of what is here")]

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use driver_machine_container::{
	Attachment, Binding, Capacity, Containerd, Containers, Fault, Fetch, Image, ImageConfig, Listed,
	Mount, Network, Quota, Refused, Roots, Runtimes, Spec, Task, Unfetched,
};
use envelope::contracts::{
	DeploymentArtifact, DeploymentDeploy, DeploymentForm, DeploymentIsolation, DeploymentNetwork,
	DeploymentOf, DeploymentRuns, DeploymentRuntime, DeploymentState,
};
use sha2::{Digest, Sha256};

/// What every fake did, in order.
pub type Log = Arc<Mutex<Vec<String>>>;

pub struct Held {
	pub labels: BTreeMap<String, String>,
	pub task: Option<Task>,
	pub spec: Spec,
}

pub struct Machine {
	pub log: Log,
	pub config: ImageConfig,
	pub rootfs: PathBuf,
	pub held: Mutex<BTreeMap<(String, String), Held>>,
	/// The containers whose start fails, by their ids.
	pub unstartable: Mutex<Vec<String>>,
	/// The namespaces whose list fails.
	pub unlistable: Mutex<Vec<String>>,
	/// A container another driver makes once a list is answered, by its namespace and id.
	pub arriving: Mutex<Option<((String, String), Held)>>,
	/// Whether a list never answers, as a containerd wedged.
	pub wedged: Mutex<bool>,
}

impl Machine {
	fn note(&self, line: String) {
		self.log.lock().unwrap().push(line);
	}
}

impl Containerd for Machine {
	async fn import(&self, namespace: &str, archive: &Path) -> Result<Image, Fault> {
		let bytes = std::fs::read(archive).map_err(|e| Fault(e.to_string()))?;
		self.note(format!("import {namespace} {}", String::from_utf8_lossy(&bytes)));
		Ok(Image {
			name: "artifact/x".into(),
			chain: "sha256:top".into(),
			config: self.config.clone(),
			size: 100,
		})
	}

	async fn prepare(&self, namespace: &str, key: &str, image: &Image) -> Result<Vec<Mount>, Fault> {
		self.note(format!("prepare {namespace} {key} on {}", image.chain));
		Ok(vec![Mount {
			kind: "btrfs".into(),
			source: "/dev/fake".into(),
			options: vec!["subvolid=300".into()],
		}])
	}

	async fn snapshot_path(&self, _: &str, key: &str) -> Result<PathBuf, Fault> {
		self.note(format!("snapshot_path {key}"));
		Ok(self.rootfs.clone())
	}

	async fn create(
		&self,
		namespace: &str,
		spec: &Spec,
		rootfs: &[Mount],
		output: &Path,
	) -> Result<(), Fault> {
		self.note(format!(
			"create {namespace} {} with {} mounts to {}",
			spec.id,
			rootfs.len(),
			output.display()
		));
		let held = Held { labels: spec.labels.clone(), task: Some(Task::Created), spec: spec.clone() };
		self.held.lock().unwrap().insert((namespace.into(), spec.id.clone()), held);
		Ok(())
	}

	async fn start(&self, namespace: &str, id: &str) -> Result<u32, Fault> {
		self.note(format!("start {id}"));
		if self.unstartable.lock().unwrap().iter().any(|u| u == id) {
			return Err(Fault(format!("{id} does not start")));
		}
		let mut held = self.held.lock().unwrap();
		let held =
			held.get_mut(&(namespace.into(), id.into())).ok_or_else(|| Fault("no container".into()))?;
		held.task = Some(Task::Running);
		Ok(42)
	}

	async fn stop(&self, namespace: &str, id: &str, grace: u64) -> Result<(), Fault> {
		self.note(format!("stop {id} within {grace}"));
		if let Some(held) = self.held.lock().unwrap().get_mut(&(namespace.into(), id.into())) {
			held.task = Some(Task::Stopped(143));
		}
		Ok(())
	}

	async fn remove(&self, namespace: &str, id: &str) -> Result<(), Fault> {
		self.note(format!("remove {id}"));
		self.held.lock().unwrap().remove(&(namespace.into(), id.into()));
		Ok(())
	}

	async fn list(&self, namespace: &str) -> Result<Vec<Listed>, Fault> {
		if *self.wedged.lock().unwrap() {
			std::future::pending::<()>().await;
		}
		if self.unlistable.lock().unwrap().iter().any(|n| n == namespace) {
			return Err(Fault(format!("{namespace} is not listed")));
		}
		let mut held = self.held.lock().unwrap();
		let listed = held
			.iter()
			.filter(|((n, _), _)| n == namespace)
			.map(|((_, id), h)| Listed {
				id: id.clone(),
				labels: h.labels.clone(),
				task: h.task,
				binary: Some(h.spec.binary.clone()),
			})
			.collect();
		if let Some((key, arrived)) = self.arriving.lock().unwrap().take() {
			held.insert(key, arrived);
		}
		Ok(listed)
	}
}

pub struct Net {
	pub log: Log,
	pub given: Mutex<u8>,
	/// How many times more an address refuses a connection, as one whose server is still starting.
	pub refusing: Mutex<u32>,
	/// How many times an address was asked whether it accepts a connection.
	pub probed: Mutex<usize>,
	/// Each network's address while it is attached, a new one for a new network, as the bridge
	/// gives.
	pub held: Mutex<BTreeMap<String, u8>>,
	/// What each namespace's fence lets through, as last written.
	pub fences: Mutex<BTreeMap<String, Vec<SocketAddr>>>,
	/// Whether removing an element fails, as `nft` may.
	pub unfenceable: Mutex<bool>,
	/// The entry's port the bridge answers, as `--entry` gives it now.
	pub entry: Mutex<u16>,
}

impl Network for Net {
	async fn attach(&self, id: &str, port: u16) -> Result<Attachment, Fault> {
		self.log.lock().unwrap().push(format!("attach {id} {port}"));
		let mut given = self.given.lock().unwrap();
		let mut held = self.held.lock().unwrap();
		let last = held.entry(id.to_owned()).or_insert_with(|| {
			*given += 1;
			*given + 1
		});
		let address: SocketAddr = format!("10.88.0.{last}:{port}").parse().unwrap();
		// The entry at the host's address and a port no default holds, so it is read, not assumed.
		let entry = SocketAddr::from(([10, 88, 0, 1], *self.entry.lock().unwrap()));
		Ok(Attachment { netns: PathBuf::from("/run/netns").join(id), address, entry })
	}

	async fn detach(&self, id: &str) -> Result<(), Fault> {
		self.log.lock().unwrap().push(format!("detach {id}"));
		self.held.lock().unwrap().remove(id);
		Ok(())
	}

	async fn fence(&self, id: &str, reached: &[SocketAddr]) -> Result<(), Fault> {
		self.log.lock().unwrap().push(format!("fence {id} {reached:?}"));
		if reached.is_empty() && *self.unfenceable.lock().unwrap() {
			return Err(Fault("nft delete element: refused".into()));
		}
		let mut fences = self.fences.lock().unwrap();
		match reached.is_empty() {
			true => fences.remove(id),
			false => fences.insert(id.to_owned(), reached.to_vec()),
		};
		Ok(())
	}

	async fn reached(&self, address: SocketAddr) -> bool {
		assert_ne!(address.port(), 0);
		*self.probed.lock().unwrap() += 1;
		let mut refusing = self.refusing.lock().unwrap();
		*refusing = refusing.saturating_sub(1);
		*refusing == 0
	}
}

pub struct Share {
	pub log: Log,
	pub refuse: bool,
}

impl Quota for Share {
	async fn assign(&self, subvolume: &Path, qgroup: &str) -> Result<(), Fault> {
		self.log.lock().unwrap().push(format!("assign {} {qgroup}", subvolume.display()));
		if self.refuse { Err(Fault("ERROR: quotas not enabled".into())) } else { Ok(()) }
	}

	async fn limit(&self, qgroup: &str, bytes: Option<u64>) -> Result<(), Fault> {
		self.log.lock().unwrap().push(format!("limit {qgroup} {bytes:?}"));
		Ok(())
	}
}

/// Two fetches put in order, the first held after it wrote until the test lets it answer.
#[derive(Default)]
pub struct Gate {
	pub written: tokio::sync::Notify,
	pub go: tokio::sync::Notify,
}

/// What an address serves.
#[derive(Clone)]
pub enum Served {
	Bytes(&'static [u8]),
	TooLarge,
	Nothing,
	/// Its bytes, written and then held at the gate before it answers.
	Held(&'static [u8], Arc<Gate>),
}

pub struct Artifacts {
	pub log: Log,
	pub served: BTreeMap<&'static str, Served>,
}

impl Fetch for Artifacts {
	async fn fetch(&self, address: &str, into: &Path, most: u64) -> Result<[u8; 32], Unfetched> {
		self.log.lock().unwrap().push(format!("fetch {address} at most {most}"));
		match self.served.get(address).cloned().unwrap_or(Served::Nothing) {
			Served::Bytes(bytes) => {
				std::fs::write(into, bytes).unwrap();
				Ok(Sha256::digest(bytes).into())
			}
			Served::Held(bytes, gate) => {
				std::fs::write(into, bytes).unwrap();
				gate.written.notify_one();
				gate.go.notified().await;
				Ok(Sha256::digest(bytes).into())
			}
			Served::TooLarge => Err(Unfetched::TooLarge),
			Served::Nothing => Err(Unfetched::Unfetchable(format!("{address}: nothing serves it"))),
		}
	}
}

pub const LARGEST: u64 = 1 << 30;
/// How long a nix-store stand-in is waited on, short as a test is.
pub const WAITED: std::time::Duration = std::time::Duration::from_millis(500);
pub const ECHO: &[u8] = b"echo image";
pub const ECHO_TWO: &[u8] = b"echo image, two";

pub fn hash(bytes: &[u8]) -> [u8; 32] {
	Sha256::digest(bytes).into()
}

pub type Driver = Containers<Machine, Net, Share, Artifacts>;

/// A tree removed whole, its directories opened first, as a container's secrets are closed to
/// writing.
pub fn cleared(path: &Path) {
	use std::os::unix::fs::PermissionsExt;
	if path.is_dir() && !path.is_symlink() {
		let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
		for entry in std::fs::read_dir(path).unwrap() {
			cleared(&entry.unwrap().path());
		}
	}
}

/// A driver with nothing deployed, its state in a directory of the test's own.
pub fn driver(test: &str, config: ImageConfig, refuse: bool) -> (Driver, Log) {
	let log: Log = Arc::default();
	let state = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("containers").join(test);
	// What an earlier run left is not this run's.
	if state.exists() {
		cleared(&state);
		std::fs::remove_dir_all(&state).unwrap();
	}
	let rootfs = state.join("rootfs");
	std::fs::create_dir_all(rootfs.join("etc")).unwrap();
	std::fs::write(
		rootfs.join("etc/passwd"),
		"root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:/:/sbin/nologin\n",
	)
	.unwrap();
	std::fs::write(rootfs.join("etc/group"), "root:x:0:\nnogroup:x:65533:\n").unwrap();
	// A store of the test's own, resolved as the driver resolves a binary.
	std::fs::create_dir_all(state.join("store")).unwrap();
	let store = state.join("store").canonicalize().unwrap();
	let served = BTreeMap::from([
		("file:///echo.tar", Served::Bytes(ECHO)),
		("file:///echo-two.tar", Served::Bytes(ECHO_TWO)),
		("https://artifacts.invalid/large.tar", Served::TooLarge),
	]);
	let driver = Containers {
		containerd: Machine {
			log: log.clone(),
			config,
			rootfs,
			held: Mutex::default(),
			unstartable: Mutex::default(),
			unlistable: Mutex::default(),
			arriving: Mutex::default(),
			wedged: Mutex::default(),
		},
		network: Net {
			log: log.clone(),
			given: Mutex::default(),
			refusing: Mutex::default(),
			probed: Mutex::default(),
			held: Mutex::default(),
			fences: Mutex::default(),
			unfenceable: Mutex::default(),
			entry: Mutex::new(4321),
		},
		quota: Share { log: log.clone(), refuse },
		fetch: Artifacts { log: log.clone(), served },
		runtimes: Runtimes {
			runc: "/bin/runc".into(),
			crun: "/bin/crun".into(),
			youki: "/bin/youki".into(),
		},
		roots: Roots { directory: state.join("roots"), store, nix: None, waited: WAITED },
		secrets: state.join("tmpfs"),
		state,
		largest: LARGEST,
	};
	(driver, log)
}

pub fn shell() -> ImageConfig {
	ImageConfig {
		cmd: vec!["/bin/sh".into()],
		env: vec!["PATH=/usr/bin:/bin".into()],
		working_dir: Some("/".into()),
		..ImageConfig::default()
	}
}

pub fn binding() -> Binding {
	Binding {
		namespace: "b1".into(),
		qgroup: "1/7".into(),
		capacities: BTreeMap::from([(3, Capacity { millicores: 500, memory: 268_435_456 })]),
	}
}

pub fn app() -> DeploymentRuns {
	DeploymentRuns::App { id: 1 }
}

pub fn of() -> DeploymentOf {
	DeploymentOf { runs: app() }
}

/// The deployment of the image `forms.json` sends, as `tests/kinds/deployments/` has it.
pub fn deploy(address: &str, bytes: &[u8]) -> DeploymentDeploy {
	DeploymentDeploy {
		runs: app(),
		version: hash(bytes),
		form: DeploymentForm::Image,
		runtime: None,
		isolation: vec![DeploymentIsolation::Kernel],
		artifact: DeploymentArtifact { address: address.into(), hash: hash(bytes), architecture: None },
		footing: "https://footing.invalid".into(),
		secrets: BTreeMap::from([("TOKEN".into(), b"hidden".to_vec())]),
		network: vec![DeploymentNetwork::Http],
		into: Some(3),
		port: Some(8080),
		handed: None,
		reaching: None,
	}
}

pub fn echo() -> DeploymentDeploy {
	deploy("file:///echo.tar", ECHO)
}

pub fn running(address: &str) -> DeploymentState {
	DeploymentState::Running {
		address: address.into(),
		runtime: DeploymentRuntime::Runc,
		isolation: vec![DeploymentIsolation::Kernel],
	}
}

pub fn reason(refused: Refused) -> &'static str {
	refused.reason
}

pub fn lines(log: &Log) -> Vec<String> {
	log.lock().unwrap().clone()
}

pub fn spec_of(driver: &Driver) -> Spec {
	driver.containerd.held.lock().unwrap().values().next().unwrap().spec.clone()
}

/// The id of the one container of a deployment's label.
pub fn id_of(driver: &Driver, runs: &str) -> String {
	let held = driver.containerd.held.lock().unwrap();
	held.iter().find(|(_, h)| h.labels["driver.runs"] == runs).unwrap().0.1.clone()
}
