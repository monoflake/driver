//! The container kind faked, as it answers the function kind, and the bundles the tests deploy.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]
#![allow(dead_code, reason = "each test file uses its own part of what is here")]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use driver_machine_container::{Binding, Capacity, Deployments, Host, Hosted, Refused};
use envelope::contracts::{
	DeploymentArtifact, DeploymentDeleted, DeploymentDeploy, DeploymentDescribed,
	DeploymentIsolation, DeploymentOf, DeploymentRuns, DeploymentRuntime, DeploymentState,
};
use sha2::{Digest, Sha256};

/// The most an artifact may be, small, so a padded one is cheap to make.
pub const LARGEST: u64 = 64 * 1024;

/// workerd's image, where a machine has it.
pub const WORKERD: &str = "/etc/driver-machine/images/workerd.tar";

fn refused(reason: &'static str) -> Refused {
	Refused { reason, message: None }
}

/// A deployment the fake runs.
struct Held {
	version: [u8; 32],
	secrets: std::collections::BTreeSet<String>,
	address: String,
	runtime: DeploymentRuntime,
	isolation: Vec<DeploymentIsolation>,
	running: bool,
}

/// The container kind faked, what each address serves, what it holds by namespace and runs, and
/// every fetch and host asked of it.
#[derive(Default)]
pub struct Fake {
	pub served: BTreeMap<String, Vec<u8>>,
	held: Mutex<BTreeMap<(String, String), Held>>,
	pub fetched: Mutex<Vec<String>>,
	pub hosted: Mutex<Vec<(DeploymentDeploy, Hosted)>>,
}

fn key(binding: &Binding, runs: &DeploymentRuns) -> (String, String) {
	(binding.namespace.clone(), format!("{runs:?}"))
}

impl Fake {
	fn described(
		&self,
		binding: &Binding,
		runs: &DeploymentRuns,
	) -> Result<DeploymentDescribed, Refused> {
		let held = self.held.lock().unwrap();
		let h = held.get(&key(binding, runs)).ok_or_else(|| refused("not_found"))?;
		let state = match h.running {
			true => DeploymentState::Running {
				address: h.address.clone(),
				runtime: h.runtime,
				isolation: h.isolation.clone(),
			},
			false => DeploymentState::Stopped,
		};
		Ok(DeploymentDescribed { runs: runs.clone(), version: h.version, state })
	}

	fn running(
		&self,
		binding: &Binding,
		runs: &DeploymentRuns,
		running: bool,
	) -> Result<(), Refused> {
		let mut held = self.held.lock().unwrap();
		held.get_mut(&key(binding, runs)).ok_or_else(|| refused("not_found"))?.running = running;
		Ok(())
	}
}

impl Deployments for Fake {
	async fn deploy(&self, _: &Binding, _: DeploymentDeploy) -> Result<DeploymentDescribed, Refused> {
		Err(refused("beyond_host"))
	}

	async fn stop(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> Result<DeploymentDescribed, Refused> {
		self.running(binding, &input.runs, false)?;
		self.described(binding, &input.runs)
	}

	async fn resume(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> Result<DeploymentDescribed, Refused> {
		self.running(binding, &input.runs, true)?;
		self.described(binding, &input.runs)
	}

	async fn describe(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> Result<DeploymentDescribed, Refused> {
		self.described(binding, &input.runs)
	}

	async fn delete(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> Result<DeploymentDeleted, Refused> {
		let mut held = self.held.lock().unwrap();
		if held.get(&key(binding, &input.runs)).is_some_and(|h| h.running) {
			return Err(refused("still_running"));
		}
		held.remove(&key(binding, &input.runs));
		Ok(DeploymentDeleted {})
	}
}

impl Host for Fake {
	async fn secret_names(
		&self,
		binding: &Binding,
		runs: &DeploymentRuns,
	) -> Result<Vec<String>, Refused> {
		Ok(
			self
				.held
				.lock()
				.unwrap()
				.get(&key(binding, runs))
				.map(|h| h.secrets.iter().cloned().collect())
				.unwrap_or_default(),
		)
	}

	async fn fetch(&self, _: &str, artifact: &DeploymentArtifact) -> Result<Vec<u8>, Refused> {
		self.fetched.lock().unwrap().push(artifact.address.clone());
		let bytes = self.served.get(&artifact.address).ok_or_else(|| refused("unfetchable"))?;
		if u64::try_from(bytes.len()).unwrap() > LARGEST {
			return Err(refused("too_large"));
		}
		if hash(bytes) != artifact.hash {
			return Err(refused("hash_mismatch"));
		}
		Ok(bytes.clone())
	}

	async fn host(
		&self,
		binding: &Binding,
		input: DeploymentDeploy,
		hosted: Hosted,
	) -> Result<DeploymentDescribed, Refused> {
		if !input.into.is_some_and(|into| binding.capacities.contains_key(&into)) {
			return Err(refused("beyond_host"));
		}
		let mut secrets = self
			.held
			.lock()
			.unwrap()
			.get(&key(binding, &input.runs))
			.map(|h| h.secrets.clone())
			.unwrap_or_default();
		secrets.extend(input.secrets.iter().flat_map(|s| s.keys()).cloned());
		let held = Held {
			version: input.version,
			secrets,
			address: format!("10.88.0.2:{}", hosted.port),
			runtime: hosted.runtime,
			isolation: hosted.isolation.clone(),
			running: true,
		};
		self.held.lock().unwrap().insert(key(binding, &input.runs), held);
		let runs = input.runs.clone();
		self.hosted.lock().unwrap().push((input, hosted));
		self.described(binding, &runs)
	}
}

/// A binding holding one container of capacity, as `forms.json` gives an image's.
pub fn binding() -> Binding {
	Binding {
		namespace: "b1".into(),
		qgroup: "1/1".into(),
		capacities: BTreeMap::from([(1, Capacity { millicores: 500, memory: 268_435_456 })]),
	}
}

pub fn hash(bytes: &[u8]) -> [u8; 32] {
	Sha256::digest(bytes).into()
}

pub fn hex(hash: &[u8; 32]) -> String {
	hash.iter().map(|b| format!("{b:02x}")).collect()
}

/// This crate's directory.
pub fn here() -> PathBuf {
	PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// A file of this repository by its path from its root, as the model names a sample.
pub fn from_root(path: &str) -> PathBuf {
	here().join("../..").join(path)
}

/// A JSON file read as it stands.
pub fn json(path: &Path) -> serde_json::Value {
	serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

/// A bundle of `tests/bundles/`, archived as a builder would, each file by its path in order.
pub fn bundle(name: &str) -> Vec<u8> {
	let directory = here().join("tests/bundles").join(name);
	let mut files = Vec::new();
	let mut pending = vec![directory.clone()];
	while let Some(at) = pending.pop() {
		for entry in std::fs::read_dir(at).unwrap() {
			let path = entry.unwrap().path();
			if path.is_dir() { pending.push(path) } else { files.push(path) }
		}
	}
	files.sort();
	let mut archive = tar::Builder::new(Vec::new());
	for file in files {
		let name = file.strip_prefix(&directory).unwrap();
		let bytes = std::fs::read(&file).unwrap();
		let mut header = tar::Header::new_ustar();
		header.set_size(u64::try_from(bytes.len()).unwrap());
		header.set_mode(0o644);
		header.set_cksum();
		archive.append_data(&mut header, name, bytes.as_slice()).unwrap();
	}
	archive.into_inner().unwrap()
}

/// The functions kind on a fake serving each address given.
pub fn functions(served: BTreeMap<String, Vec<u8>>) -> driver_machine_function::Functions<Fake> {
	driver_machine_function::Functions {
		containers: Fake { served, ..Fake::default() },
		workerd: WORKERD.into(),
		slots: "/slots.invalid".into(),
	}
}

/// A Cap'n Proto string read back from where it opens, its escapes undone.
pub fn unquoted(from: &str) -> String {
	let mut bytes = Vec::new();
	let mut chars = from.strip_prefix('"').unwrap().chars();
	while let Some(c) = chars.next() {
		match c {
			'"' => return String::from_utf8(bytes).unwrap(),
			'\\' => match chars.next().unwrap() {
				'x' => {
					let hex: String = chars.by_ref().take(2).collect();
					bytes.push(u8::from_str_radix(&hex, 16).unwrap());
				}
				escaped => bytes.extend(escaped.to_string().bytes()),
			},
			c => bytes.extend(c.to_string().bytes()),
		}
	}
	panic!("a string left open")
}

/// Every extension module of a configuration by its name, its source as written.
pub fn extended(config: &str) -> serde_json::Value {
	let mut modules = serde_json::Map::new();
	for (at, _) in config.match_indices("(name = \"slots:") {
		let name = unquoted(&config[at + "(name = ".len()..]);
		let opening = config[at..].find("esModule = ").unwrap() + "esModule = ".len();
		modules.insert(name, unquoted(&config[at + opening..]).into());
	}
	modules.into()
}

/// What opens a node script given [`extended`]'s modules on its input, `imported(name)` importing
/// one as workerd would, each `slots:` it imports resolved to another of them.
pub const IMPORTING: &str = "const modules = JSON.parse(await new Response(process.stdin).text());
const urls = {};
const url = (name) => (urls[name] ??= 'data:text/javascript,' + encodeURIComponent(
	modules[name].replace(/(['\"])(slots:[a-z]+)\\1/g, (_, quote, inner) => JSON.stringify(url(inner))),
));
const imported = (name) => import(url(name));
";

/// What node prints running a script opening with [`IMPORTING`], given a configuration's modules.
pub fn node(config: &str, script: &str) -> String {
	use std::io::Write;
	let script = format!("{IMPORTING}{script}");
	let mut node = std::process::Command::new("node")
		.args(["--input-type=module", "--eval", &script])
		.stdin(std::process::Stdio::piped())
		.stdout(std::process::Stdio::piped())
		.spawn()
		.expect("node, as mise gives it");
	node.stdin.take().unwrap().write_all(extended(config).to_string().as_bytes()).unwrap();
	let out = node.wait_with_output().unwrap();
	assert!(out.status.success(), "node failed");
	String::from_utf8(out.stdout).unwrap()
}

/// An archive of a main module and metadata declaring the slots given, as a builder would.
pub fn declaring(slots: &str) -> Vec<u8> {
	let metadata = format!(
		r#"{{ "main_module": "index.js", "compatibility_date": "2026-10-21", "slots": {slots} }}"#
	);
	let mut archive = tar::Builder::new(Vec::new());
	for (name, bytes) in [("metadata.json", metadata.as_bytes()), ("index.js", b"".as_slice())] {
		let mut header = tar::Header::new_ustar();
		header.set_size(u64::try_from(bytes.len()).unwrap());
		header.set_mode(0o644);
		header.set_cksum();
		archive.append_data(&mut header, name, bytes).unwrap();
	}
	archive.into_inner().unwrap()
}
