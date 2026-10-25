//! The `deployments` interface for modules, each deployment's workerd hosted by the container kind,
//! which keeps what it runs as it keeps an image's container.

use std::collections::BTreeMap;

use driver_machine_container::{Binding, Deployments, Host, Hosted, Refused, SECRETS};
use envelope::contracts::{
	DeploymentDeleted, DeploymentDeploy, DeploymentDescribed, DeploymentForm, DeploymentHanded,
	DeploymentOf, DeploymentRuns, DeploymentRuntime,
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
	if !input.isolation.iter().all(|i| STANDS.contains(i)) {
		return Err(beyond("workerd stands on an isolate and the kernel's isolation alone"));
	}
	once(input.handed.as_deref().unwrap_or_default())
}

/// Each value handed once, as the container kind holds it, refused before anything is fetched.
fn once(handed: &[DeploymentHanded]) -> Result<(), Refused> {
	let mut seen = std::collections::HashSet::new();
	let twice = !handed.iter().all(|h| seen.insert(std::mem::discriminant(h)));
	match twice {
		false => Ok(()),
		true => Err(Refused {
			reason: "invalid",
			message: Some("a value is handed more than once".to_owned()),
		}),
	}
}

/// A deployment as a person reads it.
fn named(runs: &DeploymentRuns) -> String {
	match runs {
		DeploymentRuns::App { id } => format!("the app {id:08x}"),
		DeploymentRuns::Component { component, id } => format!("the component {component} {id:08x}"),
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
		// What it reaches is deployed on its binding, stopped or not, RFC y2xd3.
		for target in input.reaching.iter().flatten() {
			let of = DeploymentOf { runs: target.clone() };
			match self.containers.describe(binding, of).await {
				Ok(_) => {}
				Err(refused) if refused.reason == "not_found" => {
					let message = format!("{} is not deployed on this binding", named(target));
					return Err(Refused { reason: "invalid", message: Some(message) });
				}
				Err(refused) => return Err(refused),
			}
		}
		// Whether it is the one deployment already is the container kind's to tell, which keeps what
		// it reaches, so the bundle is fetched each time.
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
