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
		let held = Held {
			version: input.version,
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
	}
}
