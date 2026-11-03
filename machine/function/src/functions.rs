//! The `deployments` interface for modules, each deployment's workerd hosted by the container kind,
//! which keeps what it runs as it keeps an image's container.

use std::collections::{BTreeMap, BTreeSet};

use driver_machine_container::{Binding, Deployments, Host, Hosted, Refused, SECRETS, Sockets};
use envelope::contracts::{
	DeploymentDeleted, DeploymentDeploy, DeploymentDescribed, DeploymentForm, DeploymentHanded,
	DeploymentOf, DeploymentRuns, DeploymentRuntime,
};

use crate::{
	AT, BUCKETS, Bound, Bundle, CONFIG, Configure, Functions, MODULES, OBJECT, OBJECTS, PORT, SLOTS,
	STANDS, STORED, Unpack, Worker, bucketed, objected, slots, slotted, stored,
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
		Bound::Text { .. } | Bound::Database { .. } | Bound::Bucket { .. } | Bound::Object => false,
	});
	let config = format!("{AT}/{CONFIG}");
	let mut cmd: Vec<String> = ["serve", config.as_str(), "config"].map(str::to_owned).to_vec();
	if secret {
		cmd.extend(["--import-path", SECRETS].map(str::to_owned));
	}
	cmd
}

/// The directories of sockets a deployment is given, each where its worker reaches it, RFC ahcrp.
/// A database slot reaches its binding's, a bucket slot its own, and the storage component the
/// object kind's and the one it listens for data calls in.
fn sockets<K>(
	functions: &Functions<K>,
	namespace: &str,
	worker: &Worker,
	runs: &DeploymentRuns,
) -> Vec<Sockets> {
	let bound = |directory, at: &str, writable| Sockets { directory, at: at.to_owned(), writable };
	let has = |wanted: fn(&Bound) -> bool| worker.bindings.iter().any(wanted);
	let mut given = Vec::new();
	if has(|b| matches!(b, Bound::Database { .. })) {
		given.push(bound(slotted(&functions.slots, namespace), SLOTS, false));
	}
	if has(|b| matches!(b, Bound::Bucket { .. })) {
		given.push(bound(bucketed(&functions.slots, namespace, runs), BUCKETS, false));
	}
	if worker.data {
		given.push(bound(objected(&functions.slots, namespace), OBJECTS, false));
		given.push(bound(stored(&functions.slots, namespace), STORED, true));
	}
	given
}

/// A directory it mounts, made where absent before its container starts, at the mode given.
fn opened(directory: &std::path::Path, mode: u32) -> Result<(), Refused> {
	use std::os::unix::fs::PermissionsExt;
	let failed = |e: std::io::Error| Refused {
		reason: "fault",
		message: Some(format!("{}: {e}", directory.display())),
	};
	std::fs::create_dir_all(directory).map_err(failed)?;
	std::fs::set_permissions(directory, std::fs::Permissions::from_mode(mode)).map_err(failed)
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
		let held = self.containers.secret_names(binding, &input.runs).await?;
		slots::filled(&input, &bundle.slots, &held)?;
		let mut worker = Worker::of(&input, &bundle);
		let mut names: BTreeSet<String> = worker
			.bindings
			.iter()
			.map(|b| match b {
				Bound::Secret { name }
				| Bound::Text { name, .. }
				| Bound::Database { name }
				| Bound::Bucket { name } => name.clone(),
				Bound::Object => OBJECT.to_owned(),
			})
			.collect();
		worker.bindings.extend(
			held.into_iter().filter(|name| names.insert(name.clone())).map(|name| Bound::Secret { name }),
		);
		let hosted = Hosted {
			image: self.workerd.clone(),
			cmd: command(&worker),
			port: PORT,
			files: files(&worker, bundle),
			at: AT.to_owned(),
			runtime: DeploymentRuntime::Workerd,
			isolation: STANDS.to_vec(),
			sockets: sockets(self, &binding.namespace, &worker, &input.runs),
		};
		// The driver's sockets come into them only once the deploy is answered.
		if worker.bindings.iter().any(|b| matches!(b, Bound::Bucket { .. })) {
			opened(&bucketed(&self.slots, &binding.namespace, &input.runs), 0o755)?;
		}
		if worker.data {
			opened(&objected(&self.slots, &binding.namespace), 0o755)?;
			let storage = stored(&self.slots, &binding.namespace);
			opened(&storage, 0o700)?;
		}
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
