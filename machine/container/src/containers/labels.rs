//! What the driver keeps of a container, written on it as labels, so a restart reads it back.

use std::collections::BTreeMap;

use envelope::contracts::{DeploymentIsolation, DeploymentRuns, DeploymentRuntime};

/// What the container runs, as [`runs`] writes it.
pub(super) const RUNS: &str = "driver.runs";
/// The version, its hash in hex.
pub(super) const VERSION: &str = "driver.version";
const RUNTIME: &str = "driver.runtime";
const ADDRESS: &str = "driver.address";
const PORT: &str = "driver.port";
const USER: &str = "driver.user";
const ISOLATION: &str = "driver.isolation";
const INTO: &str = "driver.into";
/// The deployments it reaches, each as [`runs`] writes it, apart by commas.
pub(super) const REACHING: &str = "driver.reaching";
/// The entry a reacher reaches, the host's own address on the bridge and the entry's port.
const ENTRY: &str = "driver.entry";

/// A deployment's runs as a label holds it, `app/<id>` or `component/<id in 8 hex digits>`, as
/// every resource of a scope is known by its id alone, RFC y2xd3.
pub(super) fn runs(runs: &DeploymentRuns) -> String {
	match runs {
		DeploymentRuns::App { id } => format!("app/{id}"),
		DeploymentRuns::Component { id, .. } => format!("component/{id:08x}"),
	}
}

/// A hash from its hex, none where it is not 64 hex digits.
pub(super) fn unhex(text: &str) -> Option<[u8; 32]> {
	let mut hash = [0u8; 32];
	if text.len() != 64 {
		return None;
	}
	for (byte, at) in hash.iter_mut().zip((0..64).step_by(2)) {
		*byte = u8::from_str_radix(text.get(at..at + 2)?, 16).ok()?;
	}
	Some(hash)
}

fn runtime_name(runtime: DeploymentRuntime) -> &'static str {
	match runtime {
		DeploymentRuntime::Workers => "workers",
		DeploymentRuntime::Workerd => "workerd",
		DeploymentRuntime::Wasmtime => "wasmtime",
		DeploymentRuntime::Runc => "runc",
		DeploymentRuntime::Crun => "crun",
		DeploymentRuntime::Youki => "youki",
	}
}

fn runtime_named(name: &str) -> Option<DeploymentRuntime> {
	match name {
		"workers" => Some(DeploymentRuntime::Workers),
		"workerd" => Some(DeploymentRuntime::Workerd),
		"wasmtime" => Some(DeploymentRuntime::Wasmtime),
		"runc" => Some(DeploymentRuntime::Runc),
		"crun" => Some(DeploymentRuntime::Crun),
		"youki" => Some(DeploymentRuntime::Youki),
		_ => None,
	}
}

fn isolation_name(isolation: DeploymentIsolation) -> &'static str {
	match isolation {
		DeploymentIsolation::Isolate => "isolate",
		DeploymentIsolation::Kernel => "kernel",
		DeploymentIsolation::Userspace => "userspace",
		DeploymentIsolation::Vm => "vm",
	}
}

fn isolation_named(name: &str) -> Option<DeploymentIsolation> {
	match name {
		"isolate" => Some(DeploymentIsolation::Isolate),
		"kernel" => Some(DeploymentIsolation::Kernel),
		"userspace" => Some(DeploymentIsolation::Userspace),
		"vm" => Some(DeploymentIsolation::Vm),
		_ => None,
	}
}

/// Everything a container's labels hold.
pub(super) struct Kept {
	pub(super) runs: String,
	pub(super) version: String,
	pub(super) runtime: DeploymentRuntime,
	pub(super) address: String,
	pub(super) port: u16,
	/// Who its process runs as, `uid:gid`, whose its secrets' files are.
	pub(super) user: (u32, u32),
	/// The isolation it stands on.
	pub(super) isolation: Vec<DeploymentIsolation>,
	/// The container of capacity it runs in, by its item's id, none on one labelled before it was.
	pub(super) into: Option<u32>,
	/// The deployments it reaches, each as [`runs`] writes it, none on one labelled before it was.
	pub(super) reaching: Vec<String>,
	/// The entry it reaches, none on one labelled before it was.
	pub(super) entry: Option<String>,
}

/// The deployments a container's labels say it reaches.
pub(super) fn reaching(labels: &BTreeMap<String, String>) -> Vec<String> {
	labels
		.get(REACHING)
		.map(|r| r.split(',').filter(|r| !r.is_empty()).map(str::to_owned).collect())
		.unwrap_or_default()
}

impl Kept {
	pub(super) fn write(&self) -> BTreeMap<String, String> {
		let mut labels = BTreeMap::from([
			(RUNS.to_owned(), self.runs.clone()),
			(VERSION.to_owned(), self.version.clone()),
			(RUNTIME.to_owned(), runtime_name(self.runtime).to_owned()),
			(ADDRESS.to_owned(), self.address.clone()),
			(PORT.to_owned(), self.port.to_string()),
			(USER.to_owned(), format!("{}:{}", self.user.0, self.user.1)),
			(
				ISOLATION.to_owned(),
				self.isolation.iter().map(|i| isolation_name(*i)).collect::<Vec<_>>().join(","),
			),
		]);
		if let Some(into) = self.into {
			labels.insert(INTO.to_owned(), into.to_string());
		}
		if !self.reaching.is_empty() {
			labels.insert(REACHING.to_owned(), self.reaching.join(","));
		}
		if let Some(entry) = &self.entry {
			labels.insert(ENTRY.to_owned(), entry.clone());
		}

		labels
	}

	/// What the labels hold, or which is missing or spoiled.
	pub(super) fn read(labels: &BTreeMap<String, String>) -> Result<Self, String> {
		let get = |key: &str| labels.get(key).ok_or_else(|| format!("no label {key}"));
		Ok(Self {
			runs: get(RUNS)?.clone(),
			version: get(VERSION)?.clone(),
			runtime: runtime_named(get(RUNTIME)?)
				.ok_or_else(|| format!("the label {RUNTIME} names no runtime"))?,
			address: get(ADDRESS)?.clone(),
			port: get(PORT)?.parse().map_err(|_| format!("the label {PORT} is no port"))?,
			user: get(USER)?
				.split_once(':')
				.and_then(|(u, g)| Some((u.parse().ok()?, g.parse().ok()?)))
				.ok_or_else(|| format!("the label {USER} is no uid:gid"))?,
			// A container labelled before its isolation was is an image's, on the kernel's alone.
			isolation: match labels.get(ISOLATION) {
				None => vec![DeploymentIsolation::Kernel],
				Some(named) => named
					.split(',')
					.map(|n| isolation_named(n).ok_or_else(|| format!("the label {ISOLATION} names {n:?}")))
					.collect::<Result<_, _>>()?,
			},
			into: labels
				.get(INTO)
				.map(|n| n.parse().map_err(|_| format!("the label {INTO} is no item's id")))
				.transpose()?,
			reaching: reaching(labels),
			entry: labels.get(ENTRY).cloned(),
		})
	}
}
