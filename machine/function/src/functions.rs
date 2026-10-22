//! The `deployments` interface for modules, each deployment's workerd hosted by the container kind,
//! which keeps what it runs as it keeps an image's container.

use std::collections::BTreeMap;

use driver_machine_container::{Binding, Deployments, Host, Hosted, Refused, SECRETS};
use envelope::contracts::{
	DeploymentDeleted, DeploymentDeploy, DeploymentDescribed, DeploymentForm, DeploymentOf,
	DeploymentRuntime,
};

use crate::{
	AT, Bound, Bundle, CONFIG, Configure, Functions, MODULES, PORT, STANDS, Unpack, Worker,
};

fn beyond(message: &str) -> Refused {
	Refused { reason: "beyond_host", message: Some(message.to_owned()) }
}

/// What a deploy asks that workerd cannot give, refused before anything is fetched.
fn checked(input: &DeploymentDeploy) -> Result<(), Refused> {
	match input.form {
		DeploymentForm::Modules => {}
		DeploymentForm::Component | DeploymentForm::Image => {
			return Err(beyond("a function here runs modules alone, by workerd"));
		}
	}
	match input.runtime {
		None | Some(DeploymentRuntime::Workerd) => {}
		Some(
			DeploymentRuntime::Workers
			| DeploymentRuntime::Wasmtime
			| DeploymentRuntime::Runc
			| DeploymentRuntime::Crun
			| DeploymentRuntime::Youki,
		) => return Err(beyond("modules run on workerd alone")),
	}
	match input.isolation.iter().all(|i| STANDS.contains(i)) {
		true => Ok(()),
		false => Err(beyond("workerd stands on an isolate and the kernel's isolation alone")),
	}
}

/// The container of capacity it runs in, the one it names or else the binding's first, RFC dg903.
fn container(binding: &Binding, into: Option<u32>) -> Result<u32, Refused> {
	into
		.or_else(|| binding.capacities.keys().next().copied())
		.ok_or_else(|| beyond("the binding holds no capacity"))
}

/// workerd serving its configuration, a secret's file found where the container kind binds it.
/// The kind binds that directory only for a deployment with secrets, so only then is it named.
fn command(worker: &Worker) -> Vec<String> {
	let secret = worker.bindings.iter().any(|b| match b {
		Bound::Secret { .. } => true,
		Bound::Text { .. } => false,
	});
	let config = format!("{AT}/{CONFIG}");
	let mut cmd: Vec<String> = ["serve", config.as_str(), "config"].map(str::to_owned).to_vec();
	if secret {
		cmd.extend(["--import-path", SECRETS].map(str::to_owned));
	}
	cmd
}

/// What workerd is given, its configuration and each module below [`MODULES`].
fn files(worker: &Worker, bundle: Bundle) -> BTreeMap<String, Vec<u8>> {
	let mut files: BTreeMap<String, Vec<u8>> =
		bundle.modules.into_iter().map(|m| (format!("{MODULES}/{}", m.name), m.bytes)).collect();
	files.insert(CONFIG.to_owned(), worker.capnp().into_bytes());
	files
}

impl<K> Deployments for Functions<K>
where
	K: Deployments + Host + Sync,
{
	async fn deploy(
		&self,
		binding: &Binding,
		mut input: DeploymentDeploy,
	) -> Result<DeploymentDescribed, Refused> {
		checked(&input)?;
		input.into = Some(container(binding, input.into)?);
		// Deployed again the same, it is the one deployment, and nothing is fetched for it.
		let of = DeploymentOf { runs: input.runs.clone() };
		match self.containers.describe(binding, of).await {
			Ok(described) if described.version == input.version => return Ok(described),
			Ok(_) => {}
			Err(refused) if refused.reason == "not_found" => {}
			Err(refused) => return Err(refused),
		}
		let bytes = self.containers.fetch(&binding.namespace, &input.artifact).await?;
		let bundle = Bundle::unpack(&bytes)?;
		let worker = Worker::of(&input, &bundle);
		let hosted = Hosted {
			image: self.workerd.clone(),
			cmd: command(&worker),
			port: PORT,
			files: files(&worker, bundle),
			at: AT.to_owned(),
			runtime: DeploymentRuntime::Workerd,
			isolation: STANDS.to_vec(),
		};
		self.containers.host(binding, input, hosted).await
	}

	async fn stop(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> Result<DeploymentDescribed, Refused> {
		self.containers.stop(binding, input).await
	}

	async fn resume(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> Result<DeploymentDescribed, Refused> {
		self.containers.resume(binding, input).await
	}

	async fn describe(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> Result<DeploymentDescribed, Refused> {
		self.containers.describe(binding, input).await
	}

	async fn delete(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> Result<DeploymentDeleted, Refused> {
		self.containers.delete(binding, input).await
	}
}
