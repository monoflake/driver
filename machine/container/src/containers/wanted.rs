//! What a deploy asks of a container, checked against what the host gives.

use std::collections::BTreeMap;

use envelope::contracts::{
	Architecture, DeploymentDeploy, DeploymentForm, DeploymentIsolation, DeploymentRuns,
	DeploymentRuntime,
};

use super::{handed, hex, labels, secrets};
use crate::{Binding, Hosted, Refused};

/// The isolation every container of an image stands on.
const ISOLATION: DeploymentIsolation = DeploymentIsolation::Kernel;

/// The architecture this driver was built for, as OCI names it, or none where those names lack it.
fn own() -> Option<Architecture> {
	match std::env::consts::ARCH {
		"x86_64" => Some(Architecture::Amd64),
		"aarch64" => Some(Architecture::Arm64),
		_ => None,
	}
}

/// What a deploy asks, checked against what the host gives.
pub(super) struct Wanted<'a> {
	pub(super) runs: String,
	pub(super) kind: &'static str,
	pub(super) version: String,
	pub(super) runtime: DeploymentRuntime,
	pub(super) isolation: Vec<DeploymentIsolation>,
	pub(super) port: u16,
	/// The container of capacity it runs in, by its item's id, and that capacity.
	pub(super) into: u32,
	pub(super) capacity: &'a crate::Capacity,
	pub(super) env: Vec<String>,
	/// Its own secrets and the secrets it is handed, by their names.
	pub(super) secrets: BTreeMap<String, Vec<u8>>,
	/// What a hosted runtime is given, its files and where they are bound.
	pub(super) files: Option<(&'a BTreeMap<String, Vec<u8>>, &'a str)>,
	/// The deployments it reaches, each as its label names it.
	pub(super) reaching: Vec<String>,
	/// The deployments it reaches, each named in its hosts and its origins.
	pub(super) targets: Vec<DeploymentRuns>,
}

impl<'a> Wanted<'a> {
	pub(super) fn of(binding: &'a Binding, input: &'a DeploymentDeploy) -> Result<Self, Refused> {
		match input.form {
			DeploymentForm::Image => {}
			DeploymentForm::Modules | DeploymentForm::Component => {
				return Err(Refused::new("beyond_host", "a container runs an image alone"));
			}
		}
		// An artifact naming another architecture than the machine's is beyond the host, RFC ge55b.
		if let Some(named) = input.artifact.architecture
			&& own() != Some(named)
		{
			return Err(Refused::new(
				"beyond_host",
				"an image runs on the architecture it was built for",
			));
		}
		for isolation in &input.isolation {
			match isolation {
				DeploymentIsolation::Kernel => {}
				DeploymentIsolation::Isolate | DeploymentIsolation::Userspace | DeploymentIsolation::Vm => {
					return Err(Refused::new(
						"beyond_host",
						"a container stands on the kernel's isolation alone",
					));
				}
			}
		}
		let runtime = match input.runtime {
			None => DeploymentRuntime::Runc,
			Some(r @ (DeploymentRuntime::Runc | DeploymentRuntime::Crun | DeploymentRuntime::Youki)) => r,
			Some(
				DeploymentRuntime::Workers | DeploymentRuntime::Workerd | DeploymentRuntime::Wasmtime,
			) => {
				return Err(Refused::new("beyond_host", "a container runs on runc, crun or youki"));
			}
		};
		let port = input
			.port
			.ok_or_else(|| {
				Refused::new("malformed", "an image is deployed with the port it is called on")
			})
			.and_then(|p| {
				u16::try_from(p).map_err(|_| Refused::new("malformed", "a port is at most 65535"))
			})?;
		Self::within(binding, input, runtime, vec![ISOLATION], port, None)
	}

	/// What a deploy asks of a hosted runtime, its form, runtime and isolation the caller's.
	pub(super) fn hosted(
		binding: &'a Binding,
		input: &'a DeploymentDeploy,
		hosted: &'a Hosted,
	) -> Result<Self, Refused> {
		let files = Some((&hosted.files, hosted.at.as_str()));
		Self::within(binding, input, hosted.runtime, hosted.isolation.clone(), hosted.port, files)
	}

	/// What every deploy asks, checked against the binding, its container and its secrets' names.
	fn within(
		binding: &'a Binding,
		input: &'a DeploymentDeploy,
		runtime: DeploymentRuntime,
		isolation: Vec<DeploymentIsolation>,
		port: u16,
		files: Option<(&'a BTreeMap<String, Vec<u8>>, &'a str)>,
	) -> Result<Self, Refused> {
		// The container it names, or else the binding's first, as the function kind chooses.
		let into = input
			.into
			.or_else(|| binding.capacities.keys().next().copied())
			.ok_or_else(|| Refused::new("beyond_host", "the binding holds no capacity"))?;
		let capacity = binding.capacities.get(&into).ok_or_else(|| {
			Refused::new("beyond_host", format!("the binding holds no capacity {into}"))
		})?;
		for name in input.secrets.iter().flat_map(|s| s.keys()) {
			secrets::named(name)?;
		}
		let handed = handed::bound(input.handed.as_deref().unwrap_or_default())?;
		let env =
			std::iter::once(format!("MONOFLAKE_FOOTING={}", input.footing)).chain(handed.env).collect();
		let mut secrets = input.secrets.clone().unwrap_or_default();
		secrets.extend(handed.secrets);
		Ok(Self {
			runs: labels::runs(&input.runs),
			kind: labels::kind(&input.runs),
			version: hex(&input.version),
			runtime,
			isolation,
			port,
			into,
			capacity,
			env,
			secrets,
			files,
			reaching: input.reaching.iter().flatten().map(labels::runs).collect(),
			targets: Vec::new(),
		})
	}
}
