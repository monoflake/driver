//! The `deployments` interface for images, over containerd, the network, btrfs and the fetch.

mod files;
mod handed;
mod hosts;
mod labels;
mod marks;
mod secrets;
mod spec;

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use envelope::contracts::{
	Architecture, DeploymentArtifact, DeploymentDeleted, DeploymentDeploy, DeploymentDescribed,
	DeploymentForm, DeploymentIsolation, DeploymentOf, DeploymentRuns, DeploymentRuntime,
	DeploymentState,
};

use crate::{
	Binding, Chosen, Containerd, Containers, Deployments, Fault, Fetch, Host, Hosted, Image, Listed,
	Network, Quota, Reached, Refused, Restart, Runtimes, Spec, Task, Unfetched, Unmake,
};
use labels::Kept;
use secrets::{KeyFile, Places};
use sha2::{Digest as _, Sha256};

/// How long a task is given to stop on its signal before it is killed, in milliseconds.
const GRACE: u64 = 10_000;

/// How long a container's address is given to accept a connection once its task is started, in
/// milliseconds, before it is failed as unreachable.
const REACHED: u64 = 30_000;

/// How often a deploy or a resume asks again whether its container is reached, in milliseconds.
const ASKED: u64 = 100;

/// How many fetches this process began, so each is written to a file of its own.
static FETCHES: AtomicU64 = AtomicU64::new(0);

/// The isolation every container of an image stands on.
const ISOLATION: DeploymentIsolation = DeploymentIsolation::Kernel;

impl Refused {
	pub(crate) fn new(reason: &'static str, message: impl Into<String>) -> Self {
		Self { reason, message: Some(message.into()) }
	}

	fn bare(reason: &'static str) -> Self {
		Self { reason, message: None }
	}
}

impl From<Fault> for Refused {
	fn from(fault: Fault) -> Self {
		Self::new("fault", fault.0)
	}
}

impl Chosen for Runtimes {
	fn binary(&self, named: Option<&DeploymentRuntime>) -> &Path {
		match named {
			Some(DeploymentRuntime::Crun) => &self.crun,
			Some(DeploymentRuntime::Youki) => &self.youki,
			Some(
				DeploymentRuntime::Runc
				| DeploymentRuntime::Workers
				| DeploymentRuntime::Workerd
				| DeploymentRuntime::Wasmtime,
			)
			| None => &self.runc,
		}
	}
}

/// The architecture this driver was built for, as OCI names it, or none where those names lack it.
fn own() -> Option<Architecture> {
	match std::env::consts::ARCH {
		"x86_64" => Some(Architecture::Amd64),
		"aarch64" => Some(Architecture::Arm64),
		_ => None,
	}
}

/// What a deploy asks, checked against what the host gives.
struct Wanted<'a> {
	runs: String,
	kind: &'static str,
	version: String,
	runtime: DeploymentRuntime,
	isolation: Vec<DeploymentIsolation>,
	port: u16,
	/// The container of capacity it runs in, by its item's id, and that capacity.
	into: u32,
	capacity: &'a crate::Capacity,
	env: Vec<String>,
	/// Its own secrets and the secrets it is handed, by their names.
	secrets: BTreeMap<String, Vec<u8>>,
	/// What a hosted runtime is given, its files and where they are bound.
	files: Option<(&'a BTreeMap<String, Vec<u8>>, &'a str)>,
	/// The deployments it reaches, each as its label names it.
	reaching: Vec<String>,
	/// The deployments it reaches, each named in its hosts and its origins.
	targets: Vec<DeploymentRuns>,
}

impl<'a> Wanted<'a> {
	fn of(binding: &'a Binding, input: &'a DeploymentDeploy) -> Result<Self, Refused> {
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
	fn hosted(
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
		for name in input.secrets.keys() {
			secrets::named(name)?;
		}
		let handed = handed::bound(input.handed.as_deref().unwrap_or_default())?;
		let env =
			std::iter::once(format!("MONOFLAKE_FOOTING={}", input.footing)).chain(handed.env).collect();
		let mut secrets = input.secrets.clone();
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

/// The time now in milliseconds since the epoch.
fn now() -> u64 {
	let elapsed = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
	u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX)
}

/// A hash in lowercase hex.
fn hex(hash: &[u8; 32]) -> String {
	hash.iter().map(|b| format!("{b:02x}")).collect()
}

/// The containerd id within the namespace of what runs as one container, by the id of what it runs
/// in 8 hex digits, the version's first digits, and a hash of what it reaches where it reaches any.
fn container_id(runs: &DeploymentRuns, version: &str, reaching: &[String]) -> String {
	let short: String = version.chars().take(12).collect();
	let of = labels::runs(runs);
	match reaching.is_empty() {
		true => format!("{of}-{short}"),
		false => {
			let whole = Sha256::digest(reaching.join(",").as_bytes());
			let reached: String = whole.iter().take(4).map(|b| format!("{b:02x}")).collect();
			format!("{of}-{short}-{reached}")
		}
	}
}

/// A container's network, by a name unique on the machine, since containers of two bindings may
/// share an id.
fn network_id(namespace: &str, id: &str) -> String {
	format!("{namespace}-{id}")
}

/// Whether a container's labels name what it runs, as it is labeled now or was before.
fn runs_it(listed: &Listed, runs: &str) -> bool {
	listed.labels.get(labels::RUNS).is_some_and(|r| labels::named(r) == runs)
}

/// The containers of one deployment, those in a namespace whose labels name what it runs.
fn of_runs(listed: Vec<Listed>, runs: &str) -> Vec<Listed> {
	listed.into_iter().filter(|l| runs_it(l, runs)).collect()
}

/// The one container a deployment is answered by, a running one before any other.
fn chosen(mine: &[Listed]) -> Option<&Listed> {
	mine.iter().find(|l| l.task == Some(Task::Running)).or_else(|| mine.first())
}

/// Where a deployment runs, its chosen container read as `state` reads a running one.
pub(crate) fn reached(listed: &[Listed], runs: &DeploymentRuns) -> Reached {
	let runs = labels::runs(runs);
	let mine: Vec<Listed> = listed.iter().filter(|l| runs_it(l, &runs)).cloned().collect();
	match chosen(&mine) {
		None => Reached::Absent,
		Some(l) if l.task == Some(Task::Running) => {
			Kept::read(&l.labels).map_or(Reached::Down, |kept| Reached::Running(kept.address))
		}
		Some(_) => Reached::Down,
	}
}

/// A container's state, as its task and its labels say, and whether its stop was asked for.
fn state(listed: &Listed, asked: bool) -> DeploymentState {
	let ended = |message: String| match asked {
		true => DeploymentState::Stopped,
		false => DeploymentState::Failed { reason: "exited".into(), message: Some(message) },
	};
	match listed.task {
		Some(Task::Running) => match Kept::read(&listed.labels) {
			Ok(kept) => DeploymentState::Running {
				address: kept.address,
				runtime: kept.runtime,
				isolation: kept.isolation,
			},
			Err(why) => DeploymentState::Failed { reason: "fault".into(), message: Some(why) },
		},
		Some(Task::Created | Task::Other) => DeploymentState::Making,
		Some(Task::Stopped(status)) => ended(format!("exit status {status}")),
		None => ended("its task is gone".into()),
	}
}

fn described(
	runs: &DeploymentRuns,
	listed: &Listed,
	asked: bool,
) -> Result<DeploymentDescribed, Refused> {
	let version = listed
		.labels
		.get(labels::VERSION)
		.and_then(|v| labels::unhex(v))
		.ok_or_else(|| Refused::new("fault", format!("{}: no version in its labels", listed.id)))?;
	Ok(DeploymentDescribed { runs: runs.clone(), version, state: state(listed, asked) })
}

impl<C, N, Q, F> Containers<C, N, Q, F>
where
	C: Containerd,
	N: Network,
	Q: Quota,
	F: Fetch,
{
	async fn mine(&self, binding: &Binding, runs: &DeploymentRuns) -> Result<Vec<Listed>, Refused> {
		let listed = self.containerd.list(&binding.namespace).await?;
		Ok(of_runs(listed, &labels::runs(runs)))
	}

	/// The deployment answered as containerd now holds it, `not_found` where nothing runs it.
	async fn answer(
		&self,
		binding: &Binding,
		runs: &DeploymentRuns,
	) -> Result<DeploymentDescribed, Refused> {
		let mine = self.mine(binding, runs).await?;
		let listed = chosen(&mine).ok_or_else(|| Refused::bare("not_found"))?;
		self.told(binding, runs, listed).await
	}

	/// A container described, its stop marks read; one whose task runs is `running` once its
	/// address accepts a connection, `making` until then, and failed once [`REACHED`] has passed.
	async fn told(
		&self,
		binding: &Binding,
		runs: &DeploymentRuns,
		listed: &Listed,
	) -> Result<DeploymentDescribed, Refused> {
		let (namespace, id) = (binding.namespace.as_str(), listed.id.as_str());
		let asked = marks::is_set(&self.state, namespace, id).await;
		let mut told = described(runs, listed, asked)?;
		if let DeploymentState::Running { address, .. } = &told.state {
			let reached = match address.parse::<SocketAddr>() {
				Ok(at) => self.network.reached(at).await,
				Err(_) => false,
			};
			if !reached {
				let since = marks::started_at(&self.state, namespace, id).await;
				told.state = match since.is_some_and(|at| now() < at.saturating_add(REACHED)) {
					true => DeploymentState::Making,
					false => DeploymentState::Failed {
						reason: "unreachable".into(),
						message: Some(format!(
							"{address} accepted no connection within {} s of its start",
							REACHED / 1000
						)),
					},
				};
			}
		}
		Ok(told)
	}

	/// A container just started, described once its address accepts a connection or it is no
	/// longer `making`, asked again until [`REACHED`] has passed.
	async fn settled(
		&self,
		binding: &Binding,
		runs: &DeploymentRuns,
		id: &str,
	) -> Result<DeploymentDescribed, Refused> {
		let until = Instant::now() + Duration::from_millis(REACHED.saturating_add(1000));
		loop {
			let mine = self.mine(binding, runs).await?;
			let listed = mine.iter().find(|l| l.id == id).ok_or_else(|| Refused::bare("not_found"))?;
			let told = self.told(binding, runs, listed).await?;
			if !matches!(told.state, DeploymentState::Making) || Instant::now() >= until {
				return Ok(told);
			}
			tokio::time::sleep(Duration::from_millis(ASKED)).await;
		}
	}

	fn places(&self, namespace: &str, id: &str) -> Places {
		Places::of(&self.secrets, &self.state, namespace, id)
	}

	/// The artifact fetched and held to its hash, as a file of this fetch's alone, so what another
	/// fetch of the same artifact writes or removes never reaches the bytes checked here.
	async fn fetched(
		&self,
		namespace: &str,
		artifact: &DeploymentArtifact,
	) -> Result<PathBuf, Refused> {
		let directory = self.state.join("artifacts");
		tokio::fs::create_dir_all(&directory)
			.await
			.map_err(|e| Refused::new("fault", format!("{}: {e}", directory.display())))?;
		let n = FETCHES.fetch_add(1, Ordering::Relaxed);
		let own = format!("{namespace}-{}-{}-{n}.tar", hex(&artifact.hash), std::process::id());
		let file = directory.join(own);
		match self.fetch.fetch(&artifact.address, &file, self.largest).await {
			Ok(hash) if hash == artifact.hash => Ok(file),
			Ok(_) => {
				forget(&file).await;
				Err(Refused::bare("hash_mismatch"))
			}
			Err(Unfetched::TooLarge) => {
				forget(&file).await;
				Err(Refused::new("too_large", format!("an artifact is at most {} bytes", self.largest)))
			}
			Err(Unfetched::Unfetchable(why)) => {
				forget(&file).await;
				Err(Refused::new("unfetchable", why))
			}
		}
	}

	/// The image imported into the binding's namespace, the artifact fetched or the hosted runtime's
	/// own archive, which is kept, run with what it is hosted with.
	async fn imported(
		&self,
		namespace: &str,
		input: &DeploymentDeploy,
		hosted: Option<&Hosted>,
	) -> Result<Image, Refused> {
		if let Some(hosted) = hosted {
			let mut image = self.containerd.import(namespace, &hosted.image).await?;
			image.config.cmd.clone_from(&hosted.cmd);
			return Ok(image);
		}
		let archive = self.fetched(namespace, &input.artifact).await?;
		let imported = self.containerd.import(namespace, &archive).await;
		forget(&archive).await;
		Ok(imported?)
	}

	/// Each deployment it reaches by its id, `invalid` where one is not deployed on its binding,
	/// RFC y2xd3; a target stopped or being replaced is still there.
	async fn targets(
		&self,
		binding: &Binding,
		input: &DeploymentDeploy,
	) -> Result<Vec<DeploymentRuns>, Refused> {
		let reaching = input.reaching.as_deref().unwrap_or_default();
		if reaching.is_empty() {
			return Ok(Vec::new());
		}
		let listed = self.containerd.list(&binding.namespace).await?;
		match reaching.iter().find(|r| reached(&listed, r) == Reached::Absent) {
			None => Ok(reaching.to_vec()),
			Some(absent) => Err(Refused::new(
				"invalid",
				format!("{} is not deployed on this binding", labels::runs(absent)),
			)),
		}
	}

	/// The version wanted running in place of every other, once; what a version already made
	/// answers. The new one is reached before the old ones go, so a call finds one or the other.
	async fn replaced(
		&self,
		binding: &Binding,
		input: &DeploymentDeploy,
		mut wanted: Wanted<'_>,
		hosted: Option<&Hosted>,
	) -> Result<DeploymentDescribed, Refused> {
		let namespace = binding.namespace.as_str();
		let targets = self.targets(binding, input).await?;
		wanted.targets = targets;
		let mine = self.mine(binding, &input.runs).await?;
		let same = mine.iter().find(|l| {
			l.labels.get(labels::VERSION) == Some(&wanted.version)
				&& labels::reaching(&l.labels) == wanted.reaching
		});
		if let Some(same) = same {
			return self.told(binding, &input.runs, same).await;
		}
		let id = container_id(&input.runs, &wanted.version, &wanted.reaching);
		let image = self.imported(namespace, input, hosted).await?;
		if let Err(refused) = self.made(binding, &image, &wanted, &id).await {
			// What was made of it before the failure goes with it; the failure is what is answered.
			let _ = self.removed(namespace, &id, !wanted.reaching.is_empty()).await;
			return Err(refused);
		}
		self.settled(binding, &input.runs, &id).await?;
		for old in &mine {
			self.containerd.stop(namespace, &old.id, GRACE).await?;
			self.gone(namespace, old).await?;
		}
		self.answer(binding, &input.runs).await
	}

	/// A new container made and started on the image, its labels holding what it is.
	async fn made(
		&self,
		binding: &Binding,
		image: &Image,
		wanted: &Wanted<'_>,
		id: &str,
	) -> Result<(), Refused> {
		let namespace = binding.namespace.as_str();
		let mounts = self.containerd.prepare(namespace, id, image).await?;
		let rootfs = self.containerd.snapshot_path(namespace, id).await?;
		self.quota.assign(&rootfs, &binding.qgroup).await?;
		let network = network_id(namespace, id);
		let attachment = self.network.attach(&network, wanted.port).await?;
		let user = spec::User::resolve(image.config.user.as_deref(), &rootfs).await?;
		let places = self.places(namespace, id);
		let bound = match wanted.secrets.is_empty() {
			true => None,
			false => {
				let seal = KeyFile::of(&self.state).await?;
				secrets::write(&places, &wanted.secrets, &seal, user.uid, user.gid).await?;
				Some(places.open.as_path())
			}
		};
		let given = match wanted.files {
			None => None,
			Some((given, at)) => Some((files::write(&self.state, namespace, id, given).await?, at)),
		};
		// A reacher resolves the names it reaches, and no other, to the host's own address.
		// Both read the entry the attachment answered, its address and its port.
		let names: Vec<String> =
			wanted.targets.iter().map(|runs| handed::name(namespace, runs).1).collect();
		let mut env = wanted.env.clone();
		env.extend(handed::reaching(namespace, &wanted.targets, attachment.entry.port()));
		let hosts = match names.is_empty() {
			true => None,
			false => Some(hosts::write(&self.state, namespace, id, attachment.entry.ip(), &names).await?),
		};
		let runtime_spec = spec::build(&spec::Asked {
			id,
			namespace,
			config: &image.config,
			user,
			env: &env,
			capacity: wanted.capacity,
			netns: &attachment.netns,
			secrets: bound,
			files: given.as_ref().map(|(directory, at)| (directory.as_path(), *at)),
			hosts: hosts.as_deref(),
		})?;
		let kept = Kept {
			runs: wanted.runs.clone(),
			kind: Some(wanted.kind.to_owned()),
			version: wanted.version.clone(),
			runtime: wanted.runtime,
			address: attachment.address.to_string(),
			entry: Some(attachment.entry.to_string()),
			port: wanted.port,
			user: (user.uid, user.gid),
			isolation: wanted.isolation.clone(),
			into: Some(wanted.into),
			reaching: wanted.reaching.clone(),
		};
		let spec = Spec {
			id: id.to_owned(),
			image: image.name.clone(),
			binary: self.runtimes.binary(Some(&wanted.runtime)).to_path_buf(),
			snapshot: id.to_owned(),
			runtime_spec,
			labels: kept.write(),
		};
		let output = self.state.join("output").join(namespace).join(format!("{id}.log"));
		self.containerd.create(namespace, &spec, &mounts, &output).await?;
		self.containerd.start(namespace, id).await?;
		// Once its task runs, so no element names a container that is not running.
		if !wanted.reaching.is_empty() {
			self.network.fence(&network, &[attachment.entry]).await?;
		}
		marks::started(&self.state, namespace, id, now()).await
	}

	/// A container started again as it was, its secrets and its network put back where a reboot
	/// took them, and its stop mark cleared.
	async fn started(&self, binding: &Binding, listed: &Listed) -> Result<(), Refused> {
		let kept = Kept::read(&listed.labels).map_err(|why| Refused::new("fault", why))?;
		let places = self.places(&binding.namespace, &listed.id);
		if tokio::fs::try_exists(&places.sealed).await.unwrap_or(false) {
			let seal = KeyFile::of(&self.state).await?;
			secrets::restore(&places, &seal, kept.user.0, kept.user.1).await?;
		}
		// Its namespace is kept while stopped and made again at its address where a reboot lost it,
		// and a reacher let reach the entry again.
		let network = network_id(&binding.namespace, &listed.id);
		let attachment = self.network.attach(&network, kept.port).await?;
		self.containerd.start(&binding.namespace, &listed.id).await?;
		// The entry it was made with, as its environment and hosts name it.
		if !kept.reaching.is_empty() {
			let made = kept.entry.as_deref().and_then(|e| e.parse().ok());
			self.network.fence(&network, &[made.unwrap_or(attachment.entry)]).await?;
		}
		marks::started(&self.state, &binding.namespace, &listed.id, now()).await?;
		marks::clear(&self.state, &binding.namespace, &listed.id).await
	}

	/// A container listed removed with everything it held, as its labels say what it joined.
	async fn gone(&self, namespace: &str, listed: &Listed) -> Result<(), Refused> {
		let reaches = !labels::reaching(&listed.labels).is_empty();
		self.removed(namespace, &listed.id, reaches).await
	}

	/// Everything a container held removed, its network too.
	async fn removed(&self, namespace: &str, id: &str, reaches: bool) -> Result<(), Refused> {
		let network = network_id(namespace, id);
		// Every step is taken whatever one before failed, so no decrypted secret outlives its
		// container, and the first failure is answered after.
		let mut first: Option<Refused> = None;
		let mut kept = |done: Result<(), Refused>| {
			if let Err(refused) = done {
				first.get_or_insert(refused);
			}
		};
		kept(self.containerd.remove(namespace, id).await.map_err(Refused::from));
		// A reacher's element of the fence goes before its address is given back.
		if reaches {
			kept(self.network.fence(&network, &[]).await.map_err(Refused::from));
		}
		kept(self.network.detach(&network).await.map_err(Refused::from));
		kept(secrets::remove(&self.places(namespace, id)).await);
		kept(files::remove(&self.state, namespace, id).await);
		kept(hosts::remove(&self.state, namespace, id).await);
		kept(marks::unstarted(&self.state, namespace, id).await);
		kept(marks::clear(&self.state, namespace, id).await);
		first.map_or(Ok(()), Err)
	}
}

/// A file removed, if it is there; what is left of a fetch is not worth failing for.
async fn forget(file: &Path) {
	// Nothing there is what is wanted, so a failure to remove it is no failure of the call.
	let _ = tokio::fs::remove_file(file).await;
}

impl<C, N, Q, F> Deployments for Containers<C, N, Q, F>
where
	C: Containerd,
	N: Network,
	Q: Quota,
	F: Fetch,
{
	async fn deploy(
		&self,
		binding: &Binding,
		input: DeploymentDeploy,
	) -> Result<DeploymentDescribed, Refused> {
		let wanted = Wanted::of(binding, &input)?;
		self.replaced(binding, &input, wanted, None).await
	}

	async fn stop(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> Result<DeploymentDescribed, Refused> {
		let mine = self.mine(binding, &input.runs).await?;
		if mine.is_empty() {
			return Err(Refused::bare("not_found"));
		}
		for listed in &mine {
			marks::set(&self.state, &binding.namespace, &listed.id).await?;
			self.containerd.stop(&binding.namespace, &listed.id, GRACE).await?;
		}
		self.answer(binding, &input.runs).await
	}

	async fn resume(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> Result<DeploymentDescribed, Refused> {
		let mine = self.mine(binding, &input.runs).await?;
		let listed = chosen(&mine).ok_or_else(|| Refused::bare("not_found"))?;
		self.started(binding, listed).await?;
		self.settled(binding, &input.runs, &listed.id).await
	}

	async fn describe(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> Result<DeploymentDescribed, Refused> {
		self.answer(binding, &input.runs).await
	}

	async fn delete(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> Result<DeploymentDeleted, Refused> {
		let mine = self.mine(binding, &input.runs).await?;
		let running = mine.iter().any(|l| match l.task {
			Some(Task::Running | Task::Created | Task::Other) => true,
			Some(Task::Stopped(_)) | None => false,
		});
		if running {
			return Err(Refused::bare("still_running"));
		}
		for listed in &mine {
			self.gone(&binding.namespace, listed).await?;
		}
		Ok(DeploymentDeleted {})
	}
}

impl<C, N, Q, F> Restart for Containers<C, N, Q, F>
where
	C: Containerd,
	N: Network,
	Q: Quota,
	F: Fetch,
{
	/// Each container started past a failure of another; where any failed, a fault naming every
	/// one started and every one failed, and why.
	async fn restarted(&self, binding: &Binding) -> Result<Vec<String>, Refused> {
		let mut started = Vec::new();
		let mut failed = Vec::new();
		for listed in self.containerd.list(&binding.namespace).await? {
			let gone = listed.task.is_none() && listed.labels.contains_key(labels::RUNS);
			if gone && !marks::is_set(&self.state, &binding.namespace, &listed.id).await {
				match self.started(binding, &listed).await {
					Ok(()) => started.push(listed.id),
					Err(refused) => {
						let why = refused.message.unwrap_or_else(|| refused.reason.to_owned());
						failed.push(format!("{} not started, {why}", listed.id));
					}
				}
			}
		}
		match failed.is_empty() {
			true => Ok(started),
			false => {
				let started = started.iter().map(|id| format!("{id} started"));
				Err(Refused::new("fault", started.chain(failed).collect::<Vec<_>>().join("; ")))
			}
		}
	}
}

impl<C, N, Q, F> Unmake for Containers<C, N, Q, F>
where
	C: Containerd,
	N: Network,
	Q: Quota,
	F: Fetch,
{
	async fn emptied(&self, binding: &Binding, into: u32) -> Result<Vec<String>, Refused> {
		let mut removed = Vec::new();
		for listed in self.containerd.list(&binding.namespace).await? {
			if Kept::read(&listed.labels).is_ok_and(|kept| kept.into == Some(into)) {
				self.containerd.stop(&binding.namespace, &listed.id, GRACE).await?;
				self.gone(&binding.namespace, &listed).await?;
				removed.push(listed.id);
			}
		}
		Ok(removed)
	}
}

impl<C, N, Q, F> Host for Containers<C, N, Q, F>
where
	C: Containerd,
	N: Network,
	Q: Quota,
	F: Fetch,
{
	async fn fetch(
		&self,
		namespace: &str,
		artifact: &DeploymentArtifact,
	) -> Result<Vec<u8>, Refused> {
		let file = self.fetched(namespace, artifact).await?;
		let bytes = tokio::fs::read(&file).await;
		forget(&file).await;
		bytes.map_err(|e| Refused::new("fault", format!("{}: {e}", file.display())))
	}

	async fn host(
		&self,
		binding: &Binding,
		input: DeploymentDeploy,
		hosted: Hosted,
	) -> Result<DeploymentDescribed, Refused> {
		let wanted = Wanted::hosted(binding, &input, &hosted)?;
		self.replaced(binding, &input, wanted, Some(&hosted)).await
	}
}
