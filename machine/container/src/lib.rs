//! `driver(machine)`'s container, an image deployed by `deployments` through containerd, RFC vr5lw.
//! This file is its interface, the model's, `docs/code.md`.

use std::collections::BTreeMap;
use std::future::Future;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use envelope::contracts::{
	DeploymentArtifact, DeploymentDeleted, DeploymentDeploy, DeploymentDescribed,
	DeploymentIsolation, DeploymentOf, DeploymentRuns, DeploymentRuntime,
};

mod containerd;
mod containers;
mod fetch;
mod network;
mod quota;

/// Where a container finds its secrets, each a file by its name.
pub const SECRETS: &str = "/run/secrets";

/// The Nix store, whose collector a container's runtime binary is held from by a root.
pub const STORE: &str = "/nix/store";

/// A failure an operation answers, by its reason as the `deployments` interface declares it, or one
/// every operation may fail for; its message a person reads, none for the reason's own.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refused {
	/// The reason.
	pub reason: &'static str,
	/// A message more exact than the reason's own.
	pub message: Option<String>,
}

/// What a machine could not do at a moment, answered `fault`, RFC ge55b, unless the step says
/// otherwise.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fault(pub String);

/// A container's capacity, as `management-capacity`'s `container` case holds it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Capacity {
	/// Cores, in thousandths.
	pub millicores: u32,
	/// Memory, in bytes.
	pub memory: u64,
}

/// A binding as the management holds it, its containerd namespace, its qgroup and its containers of
/// capacity, RFC vr5lw.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Binding {
	/// Its containerd namespace.
	pub namespace: String,
	/// Its qgroup above every subvolume it holds, `1/<n>`.
	pub qgroup: String,
	/// Each container of capacity, by its `capacity` id.
	pub capacities: BTreeMap<u32, Capacity>,
}

/// The `deployments` interface for images, RFC vr5lw, implemented for [`Containers`]. Deploying is
/// idempotent.
pub trait Deployments {
	/// Deploys, and answers at once, `making` until it runs.
	fn deploy(
		&self,
		binding: &Binding,
		input: DeploymentDeploy,
	) -> impl Future<Output = Result<DeploymentDescribed, Refused>> + Send;
	/// Stops it, its container kept.
	fn stop(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> impl Future<Output = Result<DeploymentDescribed, Refused>> + Send;
	/// Starts it again as it was.
	fn resume(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> impl Future<Output = Result<DeploymentDescribed, Refused>> + Send;
	/// What runs, and its state.
	fn describe(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> impl Future<Output = Result<DeploymentDescribed, Refused>> + Send;
	/// Removes it and everything it held, once stopped.
	fn delete(
		&self,
		binding: &Binding,
		input: DeploymentOf,
	) -> impl Future<Output = Result<DeploymentDeleted, Refused>> + Send;
}

/// A runtime of the machine's own run as a container for another kind, as the function kind runs
/// workerd, RFC vr5lw, its image, what it is run with, the files it is given, how it is described.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hosted {
	/// Its image's OCI archive on the machine, imported as a fetched one is and never removed.
	pub image: PathBuf,
	/// What its image's entrypoint is run with, in place of its `Cmd`.
	pub cmd: Vec<String>,
	/// The port it is called on.
	pub port: u16,
	/// The files it is given, by their paths below `at`, kept and removed with its container.
	pub files: BTreeMap<String, Vec<u8>>,
	/// Where in it the files are bound, read-only.
	pub at: String,
	/// The runtime it is described as running on.
	pub runtime: DeploymentRuntime,
	/// The isolation it stands on.
	pub isolation: Vec<DeploymentIsolation>,
}

/// What another kind asks of the containers, an artifact fetched as an image's is and a runtime of
/// the machine's run as an image is, RFC vr5lw; implemented for [`Containers`].
pub trait Host {
	/// An artifact fetched for the namespace, held to its bound and its hash; its bytes.
	fn fetch(
		&self,
		namespace: &str,
		artifact: &DeploymentArtifact,
	) -> impl Future<Output = Result<Vec<u8>, Refused>> + Send;
	/// The deployment run on the hosted runtime in the container of capacity its `into` names, as
	/// idempotent as `deploy`; its form, runtime and isolation are the caller's to have checked.
	fn host(
		&self,
		binding: &Binding,
		input: DeploymentDeploy,
		hosted: Hosted,
	) -> impl Future<Output = Result<DeploymentDescribed, Refused>> + Send;
}

/// What a list dropping a `container` item asks of the containers, implemented for [`Containers`].
pub trait Unmake {
	/// Every container run in the container of capacity `into` stopped and removed with everything
	/// it held; the ids removed.
	fn emptied(
		&self,
		binding: &Binding,
		into: u32,
	) -> impl Future<Output = Result<Vec<String>, Refused>> + Send;
}

/// What a start of the driver asks of the containers, implemented for [`Containers`].
pub trait Restart {
	/// Every container of the binding whose task is gone and whose stop no call asked, as after a
	/// reboot, started again as `resume` starts one; the ids started.
	fn restarted(
		&self,
		binding: &Binding,
	) -> impl Future<Output = Result<Vec<String>, Refused>> + Send;
	/// Within the time given, each container of the namespaces named or found among the roots rooted
	/// and each root of one gone removed; a line for each change, failure and namespace left.
	fn rooted(
		&self,
		namespaces: &[String],
		within: Duration,
	) -> impl Future<Output = Vec<String>> + Send;
}

/// An image's configuration, as its OCI config gives it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ImageConfig {
	/// `Entrypoint`.
	pub entrypoint: Vec<String>,
	/// `Cmd`.
	pub cmd: Vec<String>,
	/// `Env`, each `NAME=value`.
	pub env: Vec<String>,
	/// `WorkingDir`.
	pub working_dir: Option<String>,
	/// `User`.
	pub user: Option<String>,
}

/// An image imported into a namespace and unpacked onto the btrfs snapshotter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Image {
	/// Its name in the namespace.
	pub name: String,
	/// The chain id of its top layer, the parent its container's snapshot is prepared on.
	pub chain: String,
	/// Its configuration.
	pub config: ImageConfig,
	/// Its layers' size unpacked, in bytes, counted once, at unpacking.
	pub size: u64,
}

/// A mount, as containerd's snapshots give it and a task's rootfs takes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mount {
	/// Its type, `btrfs`.
	pub kind: String,
	/// Its source.
	pub source: String,
	/// Its options.
	pub options: Vec<String>,
}

/// A container to create, its id, image, runtime, snapshot, OCI spec and the labels holding all the
/// driver keeps of it.
#[derive(Debug, Clone, PartialEq)]
pub struct Spec {
	/// Its id within the namespace.
	pub id: String,
	/// Its image's name.
	pub image: String,
	/// The runtime binary the runc v2 shim runs, by its path.
	pub binary: PathBuf,
	/// Its snapshot's key.
	pub snapshot: String,
	/// Its OCI runtime spec.
	pub runtime_spec: serde_json::Value,
	/// Its labels.
	pub labels: BTreeMap<String, String>,
}

/// A task's state, as containerd's tasks give it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Task {
	/// Created, not started.
	Created,
	/// Running.
	Running,
	/// Stopped, with its exit status.
	Stopped(u32),
	/// Paused or anything else containerd says.
	Other,
}

/// A container as containerd lists it, its id, labels and its task's state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Listed {
	/// Its id.
	pub id: String,
	/// Its labels.
	pub labels: BTreeMap<String, String>,
	/// Its task.
	pub task: Option<Task>,
	/// The runtime binary its runc options name, none where they name none.
	pub binary: Option<PathBuf>,
}

/// Where a deployment runs as its containers' labels say, read from containerd alone, so the entry
/// finds it with no call to the driver, RFC rmll5.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reached {
	/// Running, at the address its labels hold.
	Running(String),
	/// Held, and not running now.
	Down,
	/// No container runs it.
	Absent,
}

/// Where a deployment runs, of the containers listed in its binding's namespace, a running one
/// chosen before any other as `describe` chooses.
#[must_use]
pub fn reached(listed: &[Listed], runs: &DeploymentRuns) -> Reached {
	containers::reached(listed, runs)
}

/// What the driver asks of containerd, over its gRPC API by `containerd-client`; implemented for
/// [`Socket`]. Every call is within a namespace.
pub trait Containerd: Send + Sync {
	/// An OCI image layout archive imported and unpacked onto the btrfs snapshotter.
	fn import(
		&self,
		namespace: &str,
		archive: &std::path::Path,
	) -> impl Future<Output = Result<Image, Fault>> + Send;
	/// A writable snapshot prepared on the image's top layer, and its mounts.
	fn prepare(
		&self,
		namespace: &str,
		key: &str,
		image: &Image,
	) -> impl Future<Output = Result<Vec<Mount>, Fault>> + Send;
	/// The snapshot's directory on the host, which the qgroup is assigned by.
	fn snapshot_path(
		&self,
		namespace: &str,
		key: &str,
	) -> impl Future<Output = Result<PathBuf, Fault>> + Send;
	/// The container created, and its task, on the mounts, its output to the files named.
	fn create(
		&self,
		namespace: &str,
		spec: &Spec,
		rootfs: &[Mount],
		output: &std::path::Path,
	) -> impl Future<Output = Result<(), Fault>> + Send;
	/// Its task started; its process's id.
	fn start(&self, namespace: &str, id: &str) -> impl Future<Output = Result<u32, Fault>> + Send;
	/// Its task signalled, and waited on up to so many milliseconds, then killed.
	fn stop(
		&self,
		namespace: &str,
		id: &str,
		grace: u64,
	) -> impl Future<Output = Result<(), Fault>> + Send;
	/// Its task, the container and its snapshot removed.
	fn remove(&self, namespace: &str, id: &str) -> impl Future<Output = Result<(), Fault>> + Send;
	/// Every container of the namespace.
	fn list(&self, namespace: &str) -> impl Future<Output = Result<Vec<Listed>, Fault>> + Send;
}

/// containerd at its socket.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Socket {
	/// Its path, `/run/containerd/containerd.sock`.
	pub path: PathBuf,
}

/// A container's network, its namespace and its address on the bridge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attachment {
	/// Its network namespace, by path, which its spec joins.
	pub netns: PathBuf,
	/// Its address, at the port the image is called on.
	pub address: SocketAddr,
	/// The machine's entry as a container reaches it, the host's own address on the bridge as the
	/// plugin answered it, at the entry's port.
	pub entry: SocketAddr,
}

/// A container's network made and unmade; implemented for [`Bridge`]. What making it answered is
/// kept, so unmaking it after a restart undoes the same.
pub trait Network: Send + Sync {
	/// A namespace for the container, joined to the bridge.
	fn attach(&self, id: &str, port: u16) -> impl Future<Output = Result<Attachment, Fault>> + Send;
	/// Its namespace removed and its address given back; none to remove is no failure.
	fn detach(&self, id: &str) -> impl Future<Output = Result<(), Fault>> + Send;
	/// Whether its address accepts a connection now, so what runs there is reached.
	fn reached(&self, address: SocketAddr) -> impl Future<Output = bool> + Send;
	/// Its namespace let reach the addresses given alone, the rules written again whole.
	fn fence(
		&self,
		id: &str,
		reached: &[SocketAddr],
	) -> impl Future<Output = Result<(), Fault>> + Send;
}

/// A bridge, made by the CNI plugins `bridge`, `host-local` and `loopback`, run by their binaries
/// as the CNI specification has a runtime run them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bridge {
	/// The directory the plugins are in.
	pub plugins: PathBuf,
	/// The bridge's name.
	pub name: String,
	/// The subnet addresses are given from, `10.88.0.0/16`.
	pub subnet: String,
	/// Where what each plugin answered is kept, and the namespaces made.
	pub state: PathBuf,
	/// The port the machine's entry listens on, which a reacher's hosts and fence name.
	pub entry: u16,
}

/// A binding's share of btrfs, RFC vr5lw; implemented for [`Btrfs`].
pub trait Quota: Send + Sync {
	/// A subvolume made a member of the binding's qgroup, the qgroup made first where it is not,
	/// while nothing is written in the subvolume yet.
	fn assign(
		&self,
		subvolume: &std::path::Path,
		qgroup: &str,
	) -> impl Future<Output = Result<(), Fault>> + Send;
	/// The qgroup's limit set, in bytes, none for no limit.
	fn limit(
		&self,
		qgroup: &str,
		bytes: Option<u64>,
	) -> impl Future<Output = Result<(), Fault>> + Send;
}

/// btrfs at the mount its workloads lie on, the volume kind's, which owns subvolumes and qgroups.
pub use driver_machine_volume::Btrfs;

/// Why an artifact was not fetched, past its bound or not to be had now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Unfetched {
	/// More bytes than the bound.
	TooLarge,
	/// It could not be fetched, and why.
	Unfetchable(String),
}

/// An artifact fetched to a file, at most so many bytes, and the SHA-256 of what was fetched;
/// implemented for [`Https`].
pub trait Fetch: Send + Sync {
	/// The artifact at its address into the file, and its hash.
	fn fetch(
		&self,
		address: &str,
		into: &std::path::Path,
		most: u64,
	) -> impl Future<Output = Result<[u8; 32], Unfetched>> + Send;
}

/// Fetching over HTTPS, from a `file:` address only within the directory the machine's holder
/// named, through no link and saying no path back, and over plain HTTP from one origin alone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Https {
	/// The one directory `file:` addresses may name, none where they are refused.
	pub local: Option<PathBuf>,
	/// The one origin, `http://` and its host and port, fetched from over plain HTTP, none where
	/// every plain address is refused.
	pub plain: Option<String>,
}

/// The OCI runtime binaries, by their paths.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Runtimes {
	/// runc, the default.
	pub runc: PathBuf,
	/// crun.
	pub crun: PathBuf,
	/// youki.
	pub youki: PathBuf,
}

/// Where each container's runtime binary is held from the Nix store's collector, by a link of its
/// own at `<namespace>/<id>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Roots {
	/// The directory of the links, `/nix/var/nix/gcroots/driver-machine`.
	pub directory: PathBuf,
	/// The store, [`STORE`]; a binary resolving outside it is given no root.
	pub store: PathBuf,
	/// nix-store's binary, which makes each link a root by Nix's own protocol; none links by hand.
	pub nix: Option<PathBuf>,
	/// How long a call of nix-store is waited on before it is killed and its root failed.
	pub waited: Duration,
}

/// The containers of a machine, what reaches containerd, the network, btrfs and an artifact, and
/// where things are kept.
#[derive(Debug, Clone)]
pub struct Containers<C, N, Q, F> {
	/// containerd.
	pub containerd: C,
	/// The network.
	pub network: N,
	/// btrfs.
	pub quota: Q,
	/// The fetch.
	pub fetch: F,
	/// The runtimes.
	pub runtimes: Runtimes,
	/// Where their binaries are held from the collector.
	pub roots: Roots,
	/// Where artifacts are fetched to and each container's output is written, on ext4, root's
	/// alone; each container's secrets kept sealed there too, so a reboot puts them back.
	pub state: PathBuf,
	/// Where each container's secrets are written as files on tmpfs, `/run/driver-machine/secrets`,
	/// mounted read-only into it.
	pub secrets: PathBuf,
	/// The most an artifact may be.
	pub largest: u64,
}

/// The runtime a deployment runs on, the one it names or runc, implemented for [`Runtimes`].
pub trait Chosen {
	/// The binary of the runtime named, or runc's.
	fn binary(&self, named: Option<&DeploymentRuntime>) -> &std::path::Path;
}
