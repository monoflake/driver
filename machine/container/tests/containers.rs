//! `Containers` driven through every operation and reason of `deployments` with containerd, the
//! network, btrfs and the fetch faked.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use driver_machine_container::{
	Attachment, Binding, Capacity, Chosen, Containerd, Containers, Deployments, Fault, Fetch, Host,
	Hosted, Image, ImageConfig, Listed, Mount, Network, Quota, Reached, Refused, Restart, Runtimes,
	Spec, Task, Unfetched, Unmake, reached,
};
use envelope::contracts::{
	Architecture, DeploymentArtifact, DeploymentDeploy, DeploymentDescribed, DeploymentForm,
	DeploymentHanded, DeploymentIsolation, DeploymentNetwork, DeploymentOf, DeploymentRuns,
	DeploymentRuntime, DeploymentState,
};
use serde_json::Value;
use sha2::{Digest, Sha256};

/// What every fake did, in order.
type Log = Arc<Mutex<Vec<String>>>;

struct Held {
	labels: BTreeMap<String, String>,
	task: Option<Task>,
	spec: Spec,
}

struct Machine {
	log: Log,
	config: ImageConfig,
	rootfs: PathBuf,
	held: Mutex<BTreeMap<(String, String), Held>>,
	/// The containers whose start fails, by their ids.
	unstartable: Mutex<Vec<String>>,
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
		let held = self.held.lock().unwrap();
		Ok(
			held
				.iter()
				.filter(|((n, _), _)| n == namespace)
				.map(|((_, id), h)| Listed { id: id.clone(), labels: h.labels.clone(), task: h.task })
				.collect(),
		)
	}
}

struct Net {
	log: Log,
	given: Mutex<u8>,
	/// How many times more an address refuses a connection, as one whose server is still starting.
	refusing: Mutex<u32>,
	/// How many times an address was asked whether it accepts a connection.
	probed: Mutex<usize>,
	/// Each network's address while it is attached, a new one for a new network, as the bridge
	/// gives.
	held: Mutex<BTreeMap<String, u8>>,
	/// What each namespace's fence lets through, as last written.
	fences: Mutex<BTreeMap<String, Vec<SocketAddr>>>,
	/// Whether removing an element fails, as `nft` may.
	unfenceable: Mutex<bool>,
	/// The entry's port the bridge answers, as `--entry` gives it now.
	entry: Mutex<u16>,
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

struct Share {
	log: Log,
	refuse: bool,
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
struct Gate {
	written: tokio::sync::Notify,
	go: tokio::sync::Notify,
}

/// What an address serves.
#[derive(Clone)]
enum Served {
	Bytes(&'static [u8]),
	TooLarge,
	Nothing,
	/// Its bytes, written and then held at the gate before it answers.
	Held(&'static [u8], Arc<Gate>),
}

struct Artifacts {
	log: Log,
	served: BTreeMap<&'static str, Served>,
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

const LARGEST: u64 = 1 << 30;
const ECHO: &[u8] = b"echo image";
const ECHO_TWO: &[u8] = b"echo image, two";

fn hash(bytes: &[u8]) -> [u8; 32] {
	Sha256::digest(bytes).into()
}

type Driver = Containers<Machine, Net, Share, Artifacts>;

/// A tree removed whole, its directories opened first, as a container's secrets are closed to
/// writing.
fn cleared(path: &Path) {
	use std::os::unix::fs::PermissionsExt;
	if path.is_dir() && !path.is_symlink() {
		let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
		for entry in std::fs::read_dir(path).unwrap() {
			cleared(&entry.unwrap().path());
		}
	}
}

/// A driver with nothing deployed, its state in a directory of the test's own.
fn driver(test: &str, config: ImageConfig, refuse: bool) -> (Driver, Log) {
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
		secrets: state.join("tmpfs"),
		state,
		largest: LARGEST,
	};
	(driver, log)
}

fn shell() -> ImageConfig {
	ImageConfig {
		cmd: vec!["/bin/sh".into()],
		env: vec!["PATH=/usr/bin:/bin".into()],
		working_dir: Some("/".into()),
		..ImageConfig::default()
	}
}

fn binding() -> Binding {
	Binding {
		namespace: "b1".into(),
		qgroup: "1/7".into(),
		capacities: BTreeMap::from([(3, Capacity { millicores: 500, memory: 268_435_456 })]),
	}
}

fn app() -> DeploymentRuns {
	DeploymentRuns::App { id: 1 }
}

fn of() -> DeploymentOf {
	DeploymentOf { runs: app() }
}

/// The deployment of the image `forms.json` sends, as `tests/kinds/deployments/` has it.
fn deploy(address: &str, bytes: &[u8]) -> DeploymentDeploy {
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

fn echo() -> DeploymentDeploy {
	deploy("file:///echo.tar", ECHO)
}

fn running(address: &str) -> DeploymentState {
	DeploymentState::Running {
		address: address.into(),
		runtime: DeploymentRuntime::Runc,
		isolation: vec![DeploymentIsolation::Kernel],
	}
}

fn reason(refused: Refused) -> &'static str {
	refused.reason
}

fn lines(log: &Log) -> Vec<String> {
	log.lock().unwrap().clone()
}

fn spec_of(driver: &Driver) -> Spec {
	driver.containerd.held.lock().unwrap().values().next().unwrap().spec.clone()
}

#[tokio::test]
async fn an_image_deployed_runs_and_is_described_at_its_port() {
	let (driver, _) = driver("deployed", shell(), false);
	let deployed = driver.deploy(&binding(), echo()).await.unwrap();
	let expected =
		DeploymentDescribed { runs: app(), version: hash(ECHO), state: running("10.88.0.2:8080") };
	assert_eq!(deployed, expected);
	assert_eq!(driver.describe(&binding(), of()).await.unwrap(), expected);
}

#[tokio::test]
async fn its_layer_joins_the_qgroup_before_its_task_starts() {
	let (driver, log) = driver("ordered", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let id =
		"app-1-".to_owned() + &hash(ECHO).iter().map(|b| format!("{b:02x}")).collect::<String>()[..12];
	let rootfs = driver.containerd.rootfs.display().to_string();
	let output = driver.state.join("output/b1").join(format!("{id}.log"));
	assert_eq!(
		lines(&log),
		[
			format!("fetch file:///echo.tar at most {LARGEST}"),
			"import b1 echo image".to_owned(),
			format!("prepare b1 {id} on sha256:top"),
			format!("snapshot_path {id}"),
			format!("assign {rootfs} 1/7"),
			format!("attach b1-{id} 8080"),
			format!("create b1 {id} with 1 mounts to {}", output.display()),
			format!("start {id}"),
		]
	);
	// The archive is not kept once containerd holds the image.
	assert_eq!(std::fs::read_dir(driver.state.join("artifacts")).unwrap().count(), 0);
}

#[tokio::test]
async fn its_spec_holds_its_capacity_its_network_and_what_it_is_given() {
	let (driver, _) = driver("spec", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let spec = spec_of(&driver);
	assert_eq!(spec.binary, PathBuf::from("/bin/runc"));
	assert_eq!(spec.snapshot, spec.id);
	assert_eq!(spec.image, "artifact/x");
	let s = &spec.runtime_spec;
	assert_eq!(s["process"]["args"], serde_json::json!(["/bin/sh"]));
	assert_eq!(
		s["process"]["env"],
		serde_json::json!(["PATH=/usr/bin:/bin", "MONOFLAKE_FOOTING=https://footing.invalid"])
	);
	assert_eq!(s["process"]["cwd"], "/");
	// No container holds a raw socket, RFC p95sv.
	for set in ["bounding", "effective", "permitted"] {
		let held = s["process"]["capabilities"][set].as_array().unwrap();
		assert!(held.contains(&"CAP_CHOWN".into()), "{set}");
		assert!(!held.contains(&"CAP_NET_RAW".into()), "{set}");
	}
	assert_eq!(s["process"]["user"], serde_json::json!({ "uid": 0, "gid": 0 }));
	assert_eq!(s["root"]["path"], "rootfs");
	assert_eq!(
		s["linux"]["resources"]["cpu"],
		serde_json::json!({ "period": 100_000, "quota": 50_000 })
	);
	assert_eq!(s["linux"]["resources"]["memory"]["limit"], 268_435_456);
	assert_eq!(s["linux"]["cgroupsPath"], format!("/b1/{}", spec.id));
	let network =
		s["linux"]["namespaces"].as_array().unwrap().iter().find(|n| n["type"] == "network").unwrap();
	assert_eq!(network["path"], format!("/run/netns/b1-{}", spec.id), "reaching nothing, its own");
	// A secret is a file bound into the container, never in its spec, labels or sealed copy.
	let open = driver.secrets.join("b1").join(&spec.id);
	let bound = s["mounts"].as_array().unwrap().iter().find(|m| m["destination"] == "/run/secrets");
	assert_eq!(
		bound.unwrap(),
		&serde_json::json!({
			"destination": "/run/secrets",
			"type": "bind",
			"source": open,
			"options": ["rbind", "ro", "nosuid", "nodev", "noexec"],
		})
	);
	assert_eq!(std::fs::read(open.join("TOKEN")).unwrap(), b"hidden");
	// The machine's resolver is bound read only, as an image may hold none.
	let resolver =
		s["mounts"].as_array().unwrap().iter().find(|m| m["destination"] == "/etc/resolv.conf");
	assert_eq!(resolver.unwrap()["source"], "/etc/resolv.conf");
	assert!(resolver.unwrap()["options"].as_array().unwrap().iter().any(|o| o == "ro"));
	let sealed = std::fs::read(driver.state.join("secrets/b1").join(&spec.id).join("TOKEN")).unwrap();
	assert!(!sealed.windows(6).any(|w| w == b"hidden"));
	assert!(!s.to_string().contains("hidden"));
	assert!(spec.labels.values().all(|v| !v.contains("hidden")));
}

#[tokio::test]
async fn a_deployment_without_secrets_binds_none() {
	let (driver, _) = driver("secretless", shell(), false);
	driver.deploy(&binding(), DeploymentDeploy { secrets: BTreeMap::new(), ..echo() }).await.unwrap();
	let s = spec_of(&driver).runtime_spec;
	assert!(s["mounts"].as_array().unwrap().iter().all(|m| m["destination"] != "/run/secrets"));
	assert!(!driver.state.join("secrets.key").exists());
}

#[tokio::test]
async fn secrets_lost_to_a_reboot_are_put_back_on_resuming() {
	let (driver, _) = driver("rebooted", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	driver.stop(&binding(), of()).await.unwrap();
	let tmpfs = driver.secrets.clone();
	cleared(&tmpfs);
	std::fs::remove_dir_all(&tmpfs).unwrap();
	driver.resume(&binding(), of()).await.unwrap();
	let id = spec_of(&driver).id;
	assert_eq!(std::fs::read(tmpfs.join("b1").join(id).join("TOKEN")).unwrap(), b"hidden");
}

#[tokio::test]
async fn a_real_image_configuration_runs_as_its_user_in_its_directory() {
	let config: Value = serde_json::from_str(include_str!("images/prometheus.json")).unwrap();
	let strings =
		|v: &Value| v.as_array().unwrap().iter().map(|s| s.as_str().unwrap().to_owned()).collect();
	let runs = &config["config"];
	let image = ImageConfig {
		entrypoint: strings(&runs["Entrypoint"]),
		cmd: strings(&runs["Cmd"]),
		env: strings(&runs["Env"]),
		working_dir: runs["WorkingDir"].as_str().map(str::to_owned),
		user: runs["User"].as_str().map(str::to_owned),
	};
	let (driver, _) = driver("prometheus", image, false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let s = spec_of(&driver).runtime_spec;
	assert_eq!(
		s["process"]["args"],
		serde_json::json!([
			"/bin/prometheus",
			"--config.file=/etc/prometheus/prometheus.yml",
			"--storage.tsdb.path=/prometheus"
		])
	);
	assert_eq!(s["process"]["cwd"], "/prometheus");
	assert_eq!(s["process"]["user"], serde_json::json!({ "uid": 65534, "gid": 65534 }));
	assert_eq!(
		s["process"]["env"][0],
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	);
}

#[tokio::test]
async fn a_user_and_group_named_are_read_from_the_image() {
	let config = ImageConfig { user: Some("nobody:nogroup".into()), ..shell() };
	let (named, _) = driver("named", config, false);
	named.deploy(&binding(), echo()).await.unwrap();
	assert_eq!(
		spec_of(&named).runtime_spec["process"]["user"],
		serde_json::json!({ "uid": 65534, "gid": 65533 })
	);
	let config = ImageConfig { user: Some("nobody-at-all".into()), ..shell() };
	let (unnamed, _) = driver("unnamed", config, false);
	assert_eq!(reason(unnamed.deploy(&binding(), echo()).await.unwrap_err()), "malformed");
}

#[tokio::test]
async fn an_image_naming_nothing_to_run_is_refused_and_leaves_nothing() {
	let (driver, log) = driver("empty", ImageConfig::default(), false);
	assert_eq!(reason(driver.deploy(&binding(), echo()).await.unwrap_err()), "malformed");
	assert!(driver.containerd.held.lock().unwrap().is_empty());
	assert!(lines(&log).iter().any(|l| l.starts_with("remove ")));
	assert!(lines(&log).iter().any(|l| l.starts_with("detach ")));
}

#[tokio::test]
async fn deploying_the_same_again_is_the_one_deployment() {
	let (driver, log) = driver("again", shell(), false);
	let first = driver.deploy(&binding(), echo()).await.unwrap();
	let before = lines(&log).len();
	let second = driver.deploy(&binding(), echo()).await.unwrap();
	assert_eq!(first, second);
	assert_eq!(lines(&log).len(), before);
	assert_eq!(driver.containerd.held.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn a_new_version_replaces_the_one_before() {
	let (driver, log) = driver("replaced", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let two = driver.deploy(&binding(), deploy("file:///echo-two.tar", ECHO_TWO)).await.unwrap();
	assert_eq!(two.version, hash(ECHO_TWO));
	assert_eq!(two.state, running("10.88.0.3:8080"), "the new serves beside the old");
	let held = driver.containerd.held.lock().unwrap();
	assert_eq!(held.len(), 1);
	let old =
		"app-1-".to_owned() + &hash(ECHO).iter().map(|b| format!("{b:02x}")).collect::<String>()[..12];
	let log = lines(&log);
	let start_two = log.iter().position(|l| l.starts_with("start ") && !l.ends_with(&old)).unwrap();
	let stop_one = log.iter().position(|l| *l == format!("stop {old} within 10000")).unwrap();
	assert!(start_two < stop_one, "reaching nothing, the new runs before the old is stopped");
	assert!(log.contains(&format!("remove {old}")));
	assert!(log.contains(&format!("detach b1-{old}")));
}

#[tokio::test]
async fn what_the_host_cannot_give_is_beyond_it_and_nothing_is_fetched() {
	let (driver, log) = driver("beyond", shell(), false);
	let modules = DeploymentDeploy { form: DeploymentForm::Modules, ..echo() };
	let vm = DeploymentDeploy { isolation: vec![DeploymentIsolation::Vm], ..echo() };
	let isolate = DeploymentDeploy {
		isolation: vec![DeploymentIsolation::Kernel, DeploymentIsolation::Isolate],
		..echo()
	};
	let workerd = DeploymentDeploy { runtime: Some(DeploymentRuntime::Workerd), ..echo() };
	let elsewhere = DeploymentDeploy { into: Some(9), ..echo() };
	for input in [modules, vm, isolate, workerd, elsewhere] {
		assert_eq!(reason(driver.deploy(&binding(), input).await.unwrap_err()), "beyond_host");
	}
	assert!(lines(&log).is_empty());
}

/// The architecture these tests run on, and the other, as OCI names them.
fn architectures() -> (Architecture, Architecture) {
	match std::env::consts::ARCH {
		"aarch64" => (Architecture::Arm64, Architecture::Amd64),
		_ => (Architecture::Amd64, Architecture::Arm64),
	}
}

fn built_for(architecture: Architecture) -> DeploymentDeploy {
	let mut input = echo();
	input.artifact.architecture = Some(architecture);
	input
}

#[tokio::test]
async fn an_image_of_the_machines_architecture_deploys() {
	let (driver, log) = driver("native", shell(), false);
	let deployed = driver.deploy(&binding(), built_for(architectures().0)).await.unwrap();
	assert_eq!(deployed.state, running("10.88.0.2:8080"));
	assert_eq!(lines(&log).first().unwrap(), &format!("fetch file:///echo.tar at most {LARGEST}"));
}

#[tokio::test]
async fn an_image_of_another_architecture_is_beyond_the_host_and_nothing_is_fetched() {
	let (driver, log) = driver("foreign", shell(), false);
	let refused = driver.deploy(&binding(), built_for(architectures().1)).await.unwrap_err();
	assert_eq!(reason(refused), "beyond_host");
	assert!(lines(&log).is_empty());
}

#[tokio::test]
async fn an_image_without_its_port_or_with_a_secret_misnamed_is_malformed() {
	let (driver, log) = driver("unplaced", shell(), false);
	let portless = DeploymentDeploy { port: None, ..echo() };
	let wide = DeploymentDeploy { port: Some(70_000), ..echo() };
	let secret = |name: &str| DeploymentDeploy {
		secrets: BTreeMap::from([(name.to_owned(), b"x".to_vec())]),
		..echo()
	};
	let platform = secret("MONOFLAKE_FOOTING");
	let escaping = secret("../TOKEN");
	let hidden = secret(".TOKEN");
	for input in [portless, wide, platform, escaping, hidden] {
		assert_eq!(reason(driver.deploy(&binding(), input).await.unwrap_err()), "malformed");
	}
	assert!(lines(&log).is_empty());
}

#[tokio::test]
async fn an_image_naming_no_container_runs_in_the_binding_s_first_and_none_held_is_beyond_it() {
	let (driver, _) = driver("first", shell(), false);
	let mut two = binding();
	two.capacities.insert(9, Capacity { millicores: 250, memory: 268_435_456 });
	driver.deploy(&two, DeploymentDeploy { into: None, ..echo() }).await.unwrap();
	assert_eq!(spec_of(&driver).labels["driver.into"], "3");
	// One named is the one it runs in.
	let named = DeploymentDeploy { runs: DeploymentRuns::App { id: 2 }, into: Some(9), ..echo() };
	driver.deploy(&two, named).await.unwrap();
	let into: Vec<String> = {
		let held = driver.containerd.held.lock().unwrap();
		held.values().map(|h| h.labels["driver.into"].clone()).collect()
	};
	assert_eq!(into, ["3", "9"]);
	let none = Binding { capacities: BTreeMap::new(), ..binding() };
	let refused = driver.deploy(&none, DeploymentDeploy { into: None, ..echo() }).await.unwrap_err();
	assert_eq!(reason(refused), "beyond_host");
}

#[tokio::test]
async fn an_artifact_past_its_bound_is_too_large() {
	let (driver, log) = driver("large", shell(), false);
	let input = deploy("https://artifacts.invalid/large.tar", ECHO);
	assert_eq!(reason(driver.deploy(&binding(), input).await.unwrap_err()), "too_large");
	assert_eq!(lines(&log).len(), 1);
}

#[tokio::test]
async fn an_artifact_not_as_its_hash_says_is_refused_and_not_kept() {
	let (driver, log) = driver("mismatched", shell(), false);
	let input = DeploymentDeploy {
		artifact: DeploymentArtifact {
			address: "file:///echo.tar".into(),
			hash: hash(ECHO_TWO),
			architecture: None,
		},
		..echo()
	};
	assert_eq!(reason(driver.deploy(&binding(), input).await.unwrap_err()), "hash_mismatch");
	assert_eq!(lines(&log).len(), 1);
	assert_eq!(std::fs::read_dir(driver.state.join("artifacts")).unwrap().count(), 0);
}

#[tokio::test]
async fn an_artifact_nothing_serves_is_unfetchable() {
	let (driver, _) = driver("unfetchable", shell(), false);
	let refused =
		driver.deploy(&binding(), deploy("https://nothing.invalid/x.tar", ECHO)).await.unwrap_err();
	assert_eq!(refused.reason, "unfetchable");
	assert!(refused.message.unwrap().contains("nothing serves it"));
}

#[tokio::test]
async fn a_failure_of_the_machine_is_a_fault_and_undoes_what_was_made() {
	let (driver, log) = driver("refused", shell(), true);
	let refused = driver.deploy(&binding(), echo()).await.unwrap_err();
	assert_eq!(refused.reason, "fault");
	assert_eq!(refused.message.as_deref(), Some("ERROR: quotas not enabled"));
	let log = lines(&log);
	assert!(!log.iter().any(|l| l.starts_with("start ")));
	assert!(log.iter().any(|l| l.starts_with("remove ")));
}

#[tokio::test]
async fn what_was_never_deployed_is_not_found_and_deleting_it_succeeds() {
	let (driver, log) = driver("never", shell(), false);
	assert_eq!(reason(driver.describe(&binding(), of()).await.unwrap_err()), "not_found");
	assert_eq!(reason(driver.stop(&binding(), of()).await.unwrap_err()), "not_found");
	assert_eq!(reason(driver.resume(&binding(), of()).await.unwrap_err()), "not_found");
	driver.delete(&binding(), of()).await.unwrap();
	assert!(lines(&log).is_empty());
}

#[tokio::test]
async fn another_binding_sees_none_of_it() {
	let (driver, _) = driver("apart", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let other = Binding { namespace: "b2".into(), ..binding() };
	assert_eq!(reason(driver.describe(&other, of()).await.unwrap_err()), "not_found");
}

#[tokio::test]
async fn a_deployment_stopped_is_stopped_and_resumed_runs_again() {
	let (driver, log) = driver("lifecycle", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let stopped = driver.stop(&binding(), of()).await.unwrap();
	assert_eq!(stopped.state, DeploymentState::Stopped);
	assert_eq!(driver.describe(&binding(), of()).await.unwrap().state, DeploymentState::Stopped);
	let resumed = driver.resume(&binding(), of()).await.unwrap();
	assert_eq!(resumed.state, running("10.88.0.2:8080"));
	let log = lines(&log);
	assert_eq!(
		log.iter().filter(|l| l.starts_with("attach ")).count(),
		2,
		"resuming makes its network where it is gone"
	);
	assert_eq!(log.iter().filter(|l| l.starts_with("start ")).count(), 2);
}

fn refusing(driver: &Driver, times: u32) {
	*driver.network.refusing.lock().unwrap() = times;
}

fn probes(driver: &Driver) -> usize {
	*driver.network.probed.lock().unwrap()
}

#[tokio::test]
async fn a_deployment_is_running_only_once_its_address_accepts_a_connection() {
	let (driver, _) = driver("waited", shell(), false);
	refusing(&driver, 4);
	let deployed = driver.deploy(&binding(), echo()).await.unwrap();
	assert_eq!(deployed.state, running("10.88.0.2:8080"));
	assert!(probes(&driver) >= 4, "the deploy waited for its address");
	// Refused again, as its server restarting, it is making until it answers.
	refusing(&driver, u32::MAX);
	assert_eq!(driver.describe(&binding(), of()).await.unwrap().state, DeploymentState::Making);
	refusing(&driver, 0);
	assert_eq!(driver.describe(&binding(), of()).await.unwrap().state, running("10.88.0.2:8080"));
}

#[tokio::test]
async fn a_deployment_resumed_is_running_only_once_its_address_accepts_a_connection() {
	let (driver, _) = driver("resumed-reached", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	driver.stop(&binding(), of()).await.unwrap();
	refusing(&driver, 3);
	let before = probes(&driver);
	assert_eq!(driver.resume(&binding(), of()).await.unwrap().state, running("10.88.0.2:8080"));
	assert!(probes(&driver) - before >= 3, "the resume waited for its address");
}

#[tokio::test]
async fn a_deployment_its_address_never_accepts_is_failed_once_its_start_is_long_past() {
	let (driver, _) = driver("unreachable", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let id = driver.containerd.held.lock().unwrap().keys().next().unwrap().1.clone();
	std::fs::write(driver.state.join("started/b1").join(&id), "0").unwrap();
	refusing(&driver, u32::MAX);
	let state = driver.describe(&binding(), of()).await.unwrap().state;
	let DeploymentState::Failed { reason, message } = state else { panic!("{state:?}") };
	assert_eq!(reason, "unreachable");
	assert!(message.unwrap().starts_with("10.88.0.2:8080 accepted no connection within 30 s"));
}

#[tokio::test]
async fn the_labels_alone_say_where_a_deployment_runs_as_the_entry_reads_them() {
	let (driver, _) = driver("reached", shell(), false);
	let listed = async || driver.containerd.list("b1").await.unwrap();
	assert_eq!(reached(&listed().await, &app()), Reached::Absent);
	driver.deploy(&binding(), echo()).await.unwrap();
	assert_eq!(reached(&listed().await, &app()), Reached::Running("10.88.0.2:8080".into()));
	assert_eq!(reached(&listed().await, &DeploymentRuns::App { id: 2 }), Reached::Absent);
	driver.stop(&binding(), of()).await.unwrap();
	assert_eq!(reached(&listed().await, &app()), Reached::Down);
}

#[tokio::test]
async fn a_container_item_emptied_takes_what_runs_in_it_and_nothing_else() {
	let (driver, log) = driver("emptied", shell(), false);
	let mut two = binding();
	two.capacities.insert(4, Capacity { millicores: 250, memory: 268_435_456 });
	driver.deploy(&two, echo()).await.unwrap();
	let other = DeploymentDeploy { runs: DeploymentRuns::App { id: 2 }, into: Some(4), ..echo() };
	driver.deploy(&two, other).await.unwrap();
	let into: Vec<String> = {
		let held = driver.containerd.held.lock().unwrap();
		held.values().map(|h| h.labels["driver.into"].clone()).collect()
	};
	assert_eq!(into, ["3", "4"], "each container is labelled with the capacity it runs in");
	assert_eq!(driver.emptied(&two, 5).await.unwrap(), Vec::<String>::new());
	let removed = driver.emptied(&two, 3).await.unwrap();
	assert!(matches!(&removed[..], [id] if id.starts_with("app-1-")), "{removed:?}");
	assert_eq!(reason(driver.describe(&two, of()).await.unwrap_err()), "not_found");
	let still = DeploymentOf { runs: DeploymentRuns::App { id: 2 } };
	assert_eq!(driver.describe(&two, still).await.unwrap().state, running("10.88.0.3:8080"));
	let log = lines(&log);
	assert!(log.iter().any(|l| l.starts_with("stop app-1-")), "{log:#?}");
	assert!(log.iter().any(|l| l.starts_with("detach b1-app-1-")), "{log:#?}");
	assert!(!log.iter().any(|l| l.starts_with("detach b1-app-2-")), "{log:#?}");
}

#[tokio::test]
async fn a_deployment_is_deleted_only_once_stopped_and_is_then_not_found() {
	let (driver, log) = driver("deleted", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	assert_eq!(reason(driver.delete(&binding(), of()).await.unwrap_err()), "still_running");
	driver.stop(&binding(), of()).await.unwrap();
	driver.delete(&binding(), of()).await.unwrap();
	assert_eq!(reason(driver.describe(&binding(), of()).await.unwrap_err()), "not_found");
	assert!(lines(&log).iter().any(|l| l.starts_with("detach b1-app-1-")));
	// Its secrets, both copies, and its stop's mark go with it.
	assert_eq!(std::fs::read_dir(driver.secrets.join("b1")).unwrap().count(), 0);
	assert_eq!(std::fs::read_dir(driver.state.join("secrets/b1")).unwrap().count(), 0);
	assert_eq!(std::fs::read_dir(driver.state.join("stopped/b1")).unwrap().count(), 0);
}

#[tokio::test]
async fn the_runtime_named_runs_it_and_runc_otherwise() {
	for (named, binary) in
		[(DeploymentRuntime::Crun, "/bin/crun"), (DeploymentRuntime::Youki, "/bin/youki")]
	{
		let (driver, _) = driver(&format!("runtime-{binary}").replace('/', "-"), shell(), false);
		let deployed =
			driver.deploy(&binding(), DeploymentDeploy { runtime: Some(named), ..echo() }).await.unwrap();
		assert_eq!(spec_of(&driver).binary, PathBuf::from(binary));
		let DeploymentState::Running { runtime, .. } = deployed.state else {
			panic!("not running: {deployed:?}")
		};
		assert_eq!(runtime, named);
	}
	let runtimes = Runtimes { runc: "/r".into(), crun: "/c".into(), youki: "/y".into() };
	assert_eq!(runtimes.binary(None), Path::new("/r"));
	assert_eq!(runtimes.binary(Some(&DeploymentRuntime::Runc)), Path::new("/r"));
	assert_eq!(runtimes.binary(Some(&DeploymentRuntime::Crun)), Path::new("/c"));
	assert_eq!(runtimes.binary(Some(&DeploymentRuntime::Youki)), Path::new("/y"));
}

#[tokio::test]
async fn a_container_ended_unasked_has_failed_and_one_made_is_making() {
	let (driver, _) = driver("exited", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let exited = |message: &str| DeploymentState::Failed {
		reason: "exited".into(),
		message: Some(message.into()),
	};
	for (task, state) in [
		(Some(Task::Stopped(1)), exited("exit status 1")),
		(None, exited("its task is gone")),
		(Some(Task::Created), DeploymentState::Making),
		(Some(Task::Other), DeploymentState::Making),
	] {
		driver.containerd.held.lock().unwrap().values_mut().for_each(|h| h.task = task);
		assert_eq!(driver.describe(&binding(), of()).await.unwrap().state, state);
	}
}

/// A runtime of the machine's own, as the function kind hosts workerd, its archive in the state.
fn hosted(driver: &Driver) -> Hosted {
	let image = driver.state.join("workerd.tar");
	std::fs::write(&image, b"workerd image").unwrap();
	Hosted {
		image,
		cmd: vec!["serve".into(), "/worker/config.capnp".into()],
		port: 8080,
		files: BTreeMap::from([
			("config.capnp".into(), b"config".to_vec()),
			("modules/index.js".into(), b"export default {}".to_vec()),
		]),
		at: "/worker".into(),
		runtime: DeploymentRuntime::Workerd,
		isolation: vec![DeploymentIsolation::Isolate, DeploymentIsolation::Kernel],
	}
}

#[tokio::test]
async fn a_hosted_runtime_runs_from_its_own_archive_with_its_files_bound() {
	let (driver, log) = driver("hosted", shell(), false);
	let hosted = hosted(&driver);
	let input = DeploymentDeploy { form: DeploymentForm::Modules, port: None, ..echo() };
	let deployed = driver.host(&binding(), input.clone(), hosted.clone()).await.unwrap();
	let isolation = vec![DeploymentIsolation::Isolate, DeploymentIsolation::Kernel];
	let running = DeploymentState::Running {
		address: "10.88.0.2:8080".into(),
		runtime: DeploymentRuntime::Workerd,
		isolation: isolation.clone(),
	};
	assert_eq!(deployed.state, running);
	assert_eq!(driver.describe(&binding(), of()).await.unwrap().state, running);
	// Its archive is the machine's, imported and kept, and nothing is fetched for it.
	assert!(hosted.image.exists());
	assert!(lines(&log).contains(&"import b1 workerd image".to_owned()));
	assert!(!lines(&log).iter().any(|l| l.starts_with("fetch")));
	let spec = spec_of(&driver);
	assert_eq!(spec.binary, PathBuf::from("/bin/runc"));
	let s = &spec.runtime_spec;
	assert_eq!(s["process"]["args"], serde_json::json!(["serve", "/worker/config.capnp"]));
	let files = driver.state.join("files/b1").join(&spec.id);
	let bound = s["mounts"].as_array().unwrap().iter().find(|m| m["destination"] == "/worker");
	assert_eq!(
		bound.unwrap(),
		&serde_json::json!({
			"destination": "/worker",
			"type": "bind",
			"source": files,
			"options": ["rbind", "ro", "nosuid", "nodev", "noexec"],
		})
	);
	assert_eq!(std::fs::read(files.join("modules/index.js")).unwrap(), b"export default {}");
	// Hosted again the same, it is the one deployment, and stopped and deleted, its files go.
	driver.host(&binding(), input, hosted).await.unwrap();
	assert_eq!(driver.containerd.held.lock().unwrap().len(), 1);
	driver.stop(&binding(), of()).await.unwrap();
	driver.delete(&binding(), of()).await.unwrap();
	assert!(!files.exists());
}

#[tokio::test]
async fn a_hosted_runtime_runs_in_a_container_of_the_binding_and_names_its_files_below_it() {
	let (driver, _) = driver("hosted-refused", shell(), false);
	let modules = DeploymentDeploy { form: DeploymentForm::Modules, port: None, ..echo() };
	let refused = driver
		.host(&binding(), DeploymentDeploy { into: Some(9), ..modules.clone() }, hosted(&driver))
		.await;
	assert_eq!(refused.map_err(reason), Err("beyond_host"));
	let escaping =
		Hosted { files: BTreeMap::from([("../escaped".into(), b"x".to_vec())]), ..hosted(&driver) };
	assert_eq!(driver.host(&binding(), modules, escaping).await.map_err(reason), Err("malformed"));
	assert!(!driver.state.join("files/b1/escaped").exists());
	assert!(driver.containerd.held.lock().unwrap().is_empty());
}

#[tokio::test]
async fn an_artifact_fetched_for_another_kind_is_held_to_its_hash_and_not_kept() {
	let (driver, _) = driver("fetched", shell(), false);
	let artifact = echo().artifact;
	assert_eq!(driver.fetch("b1", &artifact).await.unwrap(), ECHO);
	let mismatched = DeploymentArtifact { hash: hash(ECHO_TWO), ..artifact };
	assert_eq!(driver.fetch("b1", &mismatched).await.map_err(reason), Err("hash_mismatch"));
	assert_eq!(std::fs::read_dir(driver.state.join("artifacts")).unwrap().count(), 0);
}

#[tokio::test]
async fn two_fetches_of_one_artifact_at_once_each_read_what_they_checked() {
	let (mut driver, _) = driver("fetched-twice", shell(), false);
	let gate = Arc::new(Gate::default());
	driver.fetch.served.insert("file:///held.tar", Served::Held(ECHO, gate.clone()));
	let held = DeploymentArtifact { address: "file:///held.tar".into(), ..echo().artifact };
	// The second serves other bytes under the same hash, so it is refused and its file removed.
	let other = DeploymentArtifact { address: "file:///echo-two.tar".into(), ..echo().artifact };
	let second = async {
		gate.written.notified().await;
		let refused = driver.fetch("b1", &other).await.map_err(reason);
		gate.go.notify_one();
		refused
	};
	let (first, second) = tokio::join!(driver.fetch("b1", &held), second);
	assert_eq!(second, Err("hash_mismatch"));
	assert_eq!(first.unwrap(), ECHO);
	assert_eq!(std::fs::read_dir(driver.state.join("artifacts")).unwrap().count(), 0);
}

#[tokio::test]
async fn a_component_is_known_by_its_id_and_not_its_name() {
	let (driver, _) = driver("components", shell(), false);
	let component = |name: &str, id: u32| DeploymentDeploy {
		runs: DeploymentRuns::Component { component: name.into(), id },
		..echo()
	};
	driver.deploy(&binding(), component("issuer", 0x1a2b_3c4d)).await.unwrap();
	driver.deploy(&binding(), component("issuer", 0x0000_0007)).await.unwrap();
	let ids: Vec<String> =
		driver.containerd.held.lock().unwrap().keys().map(|k| k.1.clone()).collect();
	let short = &hash(ECHO).iter().map(|b| format!("{b:02x}")).collect::<String>()[..12];
	assert_eq!(ids, [format!("component-00000007-{short}"), format!("component-1a2b3c4d-{short}")]);
	// The same id under another name is the one deployment, described as it is asked.
	let renamed = DeploymentOf { runs: DeploymentRuns::Component { component: "x".into(), id: 7 } };
	assert_eq!(driver.describe(&binding(), renamed.clone()).await.unwrap().runs, renamed.runs);
}

#[tokio::test]
async fn what_is_handed_is_bound_under_its_reserved_name() {
	let (driver, _) = driver("handed", shell(), false);
	let handed = vec![
		DeploymentHanded::Root { value: vec![0xc0, 0x01] },
		DeploymentHanded::Key { value: b"made-up key".to_vec() },
		DeploymentHanded::Certificate { value: vec![0x0e] },
		DeploymentHanded::SigningKey { value: b"made-up signing key".to_vec() },
	];
	driver.deploy(&binding(), DeploymentDeploy { handed: Some(handed), ..echo() }).await.unwrap();
	let spec = spec_of(&driver);
	assert_eq!(
		spec.runtime_spec["process"]["env"],
		serde_json::json!([
			"PATH=/usr/bin:/bin",
			"MONOFLAKE_FOOTING=https://footing.invalid",
			"MONOFLAKE_ROOT=c001",
			"MONOFLAKE_CERTIFICATE=0e",
		])
	);
	// A secret handed is a file among its secrets, beside its own.
	let open = driver.secrets.join("b1").join(&spec.id);
	// Every value handed is hex text, a secret's too.
	let hex = |b: &[u8]| b.iter().map(|b| format!("{b:02x}")).collect::<String>().into_bytes();
	assert_eq!(std::fs::read(open.join("MONOFLAKE_KEY")).unwrap(), hex(b"made-up key"));
	let signing = std::fs::read(open.join("MONOFLAKE_SIGNING_KEY")).unwrap();
	assert_eq!(signing, hex(b"made-up signing key"));
	assert_eq!(std::fs::read(open.join("TOKEN")).unwrap(), b"hidden");
	let labels = serde_json::to_string(&spec.labels).unwrap();
	assert!(!labels.contains(&String::from_utf8(hex(b"made-up")).unwrap()), "{labels}");
}

#[tokio::test]
async fn a_value_handed_twice_is_invalid_and_nothing_is_made() {
	let (driver, log) = driver("handed-twice", shell(), false);
	let twice =
		vec![DeploymentHanded::Root { value: vec![1] }, DeploymentHanded::Root { value: vec![2] }];
	let refused = driver.deploy(&binding(), DeploymentDeploy { handed: Some(twice), ..echo() }).await;
	assert_eq!(refused.map_err(reason), Err("invalid"));
	assert!(lines(&log).is_empty());
}

#[tokio::test]
async fn a_deployment_reaches_only_what_is_deployed_on_its_binding() {
	let (driver, _) = driver("reaching", shell(), false);
	let target = DeploymentRuns::Component { component: "stand-in".into(), id: 9 };
	let reaching = |runs: DeploymentRuns| DeploymentDeploy { reaching: Some(vec![runs]), ..echo() };
	// Not deployed yet, so not reached.
	let refused = driver.deploy(&binding(), reaching(target.clone())).await;
	assert_eq!(refused.map_err(reason), Err("invalid"));
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	// Deployed on another binding is not on this one.
	let other = Binding { namespace: "b2".into(), ..binding() };
	assert_eq!(driver.deploy(&other, reaching(target.clone())).await.map_err(reason), Err("invalid"));
	driver.deploy(&binding(), reaching(target)).await.unwrap();
}

/// The networks whose reacher's element is written, each by its name.
fn fenced(driver: &Driver) -> Vec<String> {
	driver.network.fences.lock().unwrap().keys().cloned().collect()
}

/// The environment of the container running a deployment of the label given.
fn env_of(driver: &Driver, runs: &str) -> Vec<Value> {
	let held = driver.containerd.held.lock().unwrap();
	let mine =
		held.values().find(|h| h.labels["driver.runs"] == runs && h.task == Some(Task::Running));
	mine.unwrap().spec.runtime_spec["process"]["env"].as_array().unwrap().clone()
}

fn reaching(runs: DeploymentRuns) -> DeploymentDeploy {
	DeploymentDeploy { reaching: Some(vec![runs]), ..echo() }
}

/// The id of the one container of a deployment's label.
fn id_of(driver: &Driver, runs: &str) -> String {
	let held = driver.containerd.held.lock().unwrap();
	held.iter().find(|(_, h)| h.labels["driver.runs"] == runs).unwrap().0.1.clone()
}

#[tokio::test]
async fn a_reacher_is_told_each_target_by_its_name_at_the_entry() {
	let (driver, _) = driver("reacher-told", shell(), false);
	let target = DeploymentRuns::Component { component: "stand-in".into(), id: 0x1a2b_3c4d };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.deploy(&binding(), reaching(target)).await.unwrap();
	let origins = r#"MONOFLAKE_REACHING={"1a2b3c4d":"http://component-1a2b3c4d.b1:4321"}"#;
	assert!(env_of(&driver, "app/1").contains(&origins.into()));
}

/// The spec of the container running a deployment of the label given.
fn spec_running(driver: &Driver, runs: &str) -> Value {
	let held = driver.containerd.held.lock().unwrap();
	let mine =
		held.values().find(|h| h.labels["driver.runs"] == runs && h.task == Some(Task::Running));
	mine.unwrap().spec.runtime_spec.clone()
}

/// What a container's spec binds at `/etc/hosts`, read, none where it binds nothing there.
fn hosts_of(spec: &Value) -> Option<String> {
	let mounts = spec["mounts"].as_array().unwrap();
	let bound = mounts.iter().find(|m| m["destination"] == "/etc/hosts")?;
	assert_eq!(bound["options"], serde_json::json!(["rbind", "ro", "nosuid", "nodev", "noexec"]));
	Some(std::fs::read_to_string(bound["source"].as_str().unwrap()).unwrap())
}

#[tokio::test]
async fn a_reacher_resolves_the_names_it_reaches_alone_to_the_host() {
	let (driver, _) = driver("hosts", shell(), false);
	// The image's own is never read, so what it holds is not carried.
	std::fs::write(driver.containerd.rootfs.join("etc/hosts"), "192.0.2.200\timage.example\n")
		.unwrap();
	let target = DeploymentRuns::Component { component: "stand-in".into(), id: 0x1a2b_3c4d };
	let other = DeploymentRuns::App { id: 2 };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.deploy(&binding(), DeploymentDeploy { runs: other, ..echo() }).await.unwrap();
	driver.deploy(&binding(), reaching(target)).await.unwrap();
	let hosts = hosts_of(&spec_running(&driver, "app/1")).unwrap();
	assert_eq!(hosts, "127.0.0.1\tlocalhost\n::1\tlocalhost\n10.88.0.1\tcomponent-1a2b3c4d.b1\n");
	// Reaching nothing, it is given nothing, and keeps the image's own.
	assert_eq!(hosts_of(&spec_running(&driver, "app/2")), None);
	assert_eq!(hosts_of(&spec_running(&driver, "component/1a2b3c4d")), None);
}

#[tokio::test]
async fn a_reacher_alone_is_let_reach_the_entry_and_its_element_goes_with_it() {
	let (driver, log) = driver("elements", shell(), false);
	let target = DeploymentRuns::App { id: 9 };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	assert!(fenced(&driver).is_empty(), "nothing for a deployment reaching nothing");
	driver.deploy(&binding(), reaching(target)).await.unwrap();
	let reacher = format!("b1-{}", id_of(&driver, "app/1"));
	assert_eq!(fenced(&driver), std::slice::from_ref(&reacher));
	// The entry the attachment answered.
	let entry: SocketAddr = "10.88.0.1:4321".parse().unwrap();
	assert_eq!(driver.network.fences.lock().unwrap()[&reacher], [entry]);
	driver.stop(&binding(), of()).await.unwrap();
	driver.delete(&binding(), of()).await.unwrap();
	assert!(fenced(&driver).is_empty());
	let log = lines(&log);
	let unfenced = log.iter().position(|l| *l == format!("fence {reacher} []")).unwrap();
	let detached = log.iter().position(|l| *l == format!("detach {reacher}")).unwrap();
	assert!(unfenced < detached, "its element goes before its address is given back");
}

#[tokio::test]
async fn a_reacher_resumed_is_let_reach_the_entry_again() {
	let (driver, _) = driver("resumed-fence", shell(), false);
	let target = DeploymentRuns::App { id: 9 };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.deploy(&binding(), reaching(target)).await.unwrap();
	driver.stop(&binding(), of()).await.unwrap();
	// As a boot empties the set.
	driver.network.fences.lock().unwrap().clear();
	driver.resume(&binding(), of()).await.unwrap();
	assert_eq!(fenced(&driver), [format!("b1-{}", id_of(&driver, "app/1"))]);
}

#[tokio::test]
async fn a_target_stopped_is_still_reached_and_one_never_deployed_is_invalid() {
	let (driver, _) = driver("stopped-target", shell(), false);
	let target = DeploymentRuns::App { id: 9 };
	assert_eq!(
		driver.deploy(&binding(), reaching(target.clone())).await.map_err(reason),
		Err("invalid")
	);
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.stop(&binding(), DeploymentOf { runs: target.clone() }).await.unwrap();
	driver.deploy(&binding(), reaching(target)).await.unwrap();
}

#[tokio::test]
async fn a_reacher_is_replaced_with_no_gap_and_each_container_has_its_element() {
	let (driver, log) = driver("no-gap", shell(), false);
	let target = DeploymentRuns::App { id: 9 };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.deploy(&binding(), reaching(target.clone())).await.unwrap();
	let old = id_of(&driver, "app/1");
	let two =
		DeploymentDeploy { reaching: Some(vec![target]), ..deploy("file:///echo-two.tar", ECHO_TWO) };
	driver.deploy(&binding(), two).await.unwrap();
	let new = id_of(&driver, "app/1");
	let log = lines(&log);
	let start_two = log.iter().position(|l| *l == format!("start {new}")).unwrap();
	let stop_one = log.iter().position(|l| l.starts_with(&format!("stop {old} "))).unwrap();
	assert!(start_two < stop_one, "{log:#?}");
	assert_eq!(fenced(&driver), [format!("b1-{new}")]);
}

#[tokio::test]
async fn reaching_nothing_again_takes_effect_at_the_same_version() {
	let (driver, _) = driver("unreached", shell(), false);
	let target = DeploymentRuns::App { id: 9 };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.deploy(&binding(), reaching(target)).await.unwrap();
	driver.deploy(&binding(), echo()).await.unwrap();
	let env = env_of(&driver, "app/1");
	assert!(!env.iter().any(|e| e.as_str().unwrap().starts_with("MONOFLAKE_REACHING=")), "{env:?}");
	assert!(fenced(&driver).is_empty());
}

#[tokio::test]
async fn a_new_version_reaching_nothing_failing_leaves_the_one_before_running() {
	let (mut driver, _) = driver("failed-overlapped", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	driver.containerd.config = ImageConfig::default();
	let two = deploy("file:///echo-two.tar", ECHO_TWO);
	assert_eq!(driver.deploy(&binding(), two).await.map_err(reason), Err("malformed"));
	let described = driver.describe(&binding(), of()).await.unwrap();
	assert_eq!((described.version, described.state), (hash(ECHO), running("10.88.0.2:8080")));
}

#[tokio::test]
async fn a_restart_goes_on_past_a_failure_and_names_each() {
	let (driver, _) = driver("restarted", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let other = DeploymentDeploy { runs: DeploymentRuns::App { id: 2 }, ..echo() };
	driver.deploy(&binding(), other).await.unwrap();
	let (one, two) = (id_of(&driver, "app/1"), id_of(&driver, "app/2"));
	// As a reboot ends every task.
	for held in driver.containerd.held.lock().unwrap().values_mut() {
		held.task = None;
	}
	driver.containerd.unstartable.lock().unwrap().push(one.clone());
	let refused = driver.restarted(&binding()).await.unwrap_err();
	assert_eq!(refused.reason, "fault");
	let message = refused.message.unwrap();
	assert!(message.contains(&format!("{two} started")), "{message}");
	assert!(message.contains(&format!("{one} not started, {one} does not start")), "{message}");
	let held = driver.containerd.held.lock().unwrap();
	assert_eq!(held[&("b1".to_owned(), two)].task, Some(Task::Running));
}

#[tokio::test]
async fn a_reacher_removed_while_nft_fails_still_gives_everything_back() {
	let (driver, log) = driver("unfenced", shell(), false);
	let target = DeploymentRuns::App { id: 9 };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.deploy(&binding(), reaching(target)).await.unwrap();
	let reacher = id_of(&driver, "app/1");
	driver.stop(&binding(), of()).await.unwrap();
	*driver.network.unfenceable.lock().unwrap() = true;
	let refused = driver.delete(&binding(), of()).await.unwrap_err();
	assert_eq!(refused.message.as_deref(), Some("nft delete element: refused"));
	// Its network, its decrypted secrets and its hosts go all the same.
	assert!(lines(&log).contains(&format!("detach b1-{reacher}")));
	assert!(!driver.secrets.join("b1").join(&reacher).exists());
	assert!(!driver.state.join("hosts/b1").join(&reacher).exists());
	assert!(driver.containerd.held.lock().unwrap().keys().all(|k| k.1 != reacher));
}

#[tokio::test]
async fn a_reacher_resumed_is_let_reach_the_entry_it_was_made_with() {
	let (driver, _) = driver("resumed-entry", shell(), false);
	let target = DeploymentRuns::App { id: 9 };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.deploy(&binding(), reaching(target)).await.unwrap();
	driver.stop(&binding(), of()).await.unwrap();
	driver.network.fences.lock().unwrap().clear();
	// The driver started again with another entry.
	*driver.network.entry.lock().unwrap() = 4999;
	driver.resume(&binding(), of()).await.unwrap();
	let reacher = format!("b1-{}", id_of(&driver, "app/1"));
	let made: SocketAddr = "10.88.0.1:4321".parse().unwrap();
	assert_eq!(driver.network.fences.lock().unwrap()[&reacher], [made]);
}
