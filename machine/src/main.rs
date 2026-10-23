//! `driver-machine`, serving a machine's management and kinds at `POST /{interface}/{operation}`,
//! RFCs 8c0rg and vr5lw. This file is its interface, the model's, `docs/code.md`.

use std::collections::{BTreeMap, BTreeSet};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::{Arc, RwLock};

use clap::Parser;
use driver_machine_container::{Bridge, Btrfs, Containers, Https, Refused, Socket};
use driver_machine_function::Functions;
use driver_machine_management::{Binding, Tokens};
use envelope::contracts::{
	ManagementApply, ManagementCapacity, ManagementDescribed, ManagementEnd, ManagementEnded,
	ManagementHeld, ManagementPolicy, ManagementState,
};

mod answer;
mod entry;
mod kept;
mod listed;
mod served;

/// The port it listens on, DRIVE on a keypad, RFC 8c0rg.
const PORT: u16 = 37483;

/// Where it listens unless told, every address of the machine, its firewall opening the port on
/// the tailnet's interface alone.
const LISTEN: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), PORT);

/// The entry's port, ENTRY on a keypad, as the driver's is DRIVE.
const ENTRY_PORT: u16 = 36879;

/// Where the entry listens unless told, loopback alone, so only what is put in front of it reaches
/// it and nothing is opened by a default.
const ENTRY: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), ENTRY_PORT);

/// The palette its help is painted in, cargo's, the workspace's `docs/toolchain.md`.
const STYLES: clap::builder::Styles = clap::builder::Styles::styled()
	.header(clap::builder::styling::AnsiColor::Green.on_default().bold())
	.usage(clap::builder::styling::AnsiColor::Green.on_default().bold())
	.literal(clap::builder::styling::AnsiColor::Cyan.on_default().bold())
	.placeholder(clap::builder::styling::AnsiColor::Cyan.on_default())
	.error(clap::builder::styling::AnsiColor::Red.on_default().bold())
	.valid(clap::builder::styling::AnsiColor::Cyan.on_default().bold())
	.invalid(clap::builder::styling::AnsiColor::Yellow.on_default().bold());

/// What it is started with, its address, its bindings' tokens, its state, and what the container
/// kind reaches, each named as `driver-machine-container` names it.
#[derive(Debug, Clone, Parser)]
#[command(version, about, styles = STYLES)]
struct Arguments {
	/// The address and port it listens on, plain HTTP, TLS a reverse proxy's.
	#[arg(long, value_name = "address:port", default_value_t = LISTEN)]
	listen: SocketAddr,
	/// The address and port the entry listens on, plain HTTP, TLS the tunnel's in front of it now.
	#[arg(long, value_name = "address:port", default_value_t = ENTRY)]
	entry: SocketAddr,
	/// A binding token's file, `<id>.<secret>`, read at start and again on SIGHUP; repeated.
	#[arg(long = "bindings", value_name = "file")]
	bindings: Vec<PathBuf>,
	/// Where it keeps its own state, on the host's file system, root's alone.
	#[arg(long, value_name = "directory", default_value = "/var/lib/monoflake/driver")]
	state: PathBuf,
	/// containerd's socket.
	#[arg(long, value_name = "socket", default_value = "/run/containerd/containerd.sock")]
	containerd: PathBuf,
	/// runc's binary, the runtime a container runs on unless it names another.
	#[arg(long, value_name = "binary")]
	runc: PathBuf,
	/// crun's binary.
	#[arg(long, value_name = "binary")]
	crun: PathBuf,
	/// youki's binary.
	#[arg(long, value_name = "binary")]
	youki: PathBuf,
	/// The directory holding the CNI plugins `bridge`, `host-local` and `loopback`.
	#[arg(long, value_name = "directory")]
	plugins: PathBuf,
	/// The bridge's name.
	#[arg(long, value_name = "name")]
	bridge: String,
	/// The subnet each container's address is given from, in CIDR notation.
	#[arg(long, value_name = "subnet")]
	subnet: String,
	/// The mount the workloads' btrfs lies on.
	#[arg(long, value_name = "directory", default_value = "/data")]
	mount: PathBuf,
	/// The `btrfs` binary.
	#[arg(long, value_name = "binary")]
	btrfs: PathBuf,
	/// The one directory a `file:` artifact's address may name; without it they are refused.
	#[arg(long, value_name = "directory")]
	local: Option<PathBuf>,
	/// Where each container's secrets are written as files on tmpfs.
	#[arg(long, value_name = "directory", default_value = "/run/monoflake/secrets")]
	secrets: PathBuf,
	/// The most an artifact may be, in bytes.
	#[arg(long, value_name = "bytes")]
	largest: u64,
	/// workerd's image, the OCI archive monoflake/runtime releases, which a function runs on.
	#[arg(long, value_name = "archive", default_value = "/etc/monoflake/images/workerd.tar")]
	workerd: PathBuf,
}

/// An item of a binding's list as the driver holds it, its credentials by their hashes.
#[derive(Debug, Clone, PartialEq)]
struct Item {
	capacity: ManagementCapacity,
	credentials: Vec<[u8; 32]>,
	state: ManagementState,
	/// When the list was first found not asking it, in milliseconds, none while it asks.
	unasked: Option<u64>,
}

/// A binding's list, its generations, grace and items, the hashes of its tokens an apply forgot,
/// and what the machine made of it, which its deployments run within, and its bucket.
#[derive(Debug, Clone)]
struct Listed {
	binding: Binding,
	generation: u64,
	policy: u64,
	grace: u32,
	items: BTreeMap<u32, Item>,
	forgotten: BTreeSet<[u8; 32]>,
	made: Option<driver_machine_container::Binding>,
	bucket: Option<Arc<driver_machine_object::Bucket>>,
}

/// What the machine holds whole, every core in thousandths and its memory in bytes, read at start,
/// and the address it is reached at as a `container` item reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Machine {
	millicores: u64,
	memory: u64,
	address: String,
}

/// Management's operations on one binding's list, RFC vr5lw; implemented for [`Listed`]. A time is
/// in milliseconds since the epoch.
trait Manage {
	/// The list taken where it is not older than the one held and fits the machine, answered with
	/// the generation held.
	fn apply(
		&mut self,
		input: &ManagementApply,
		machine: &Machine,
		now: u64,
	) -> Result<ManagementHeld, Refused>;
	/// The grace taken where its policy is not older than the one held.
	fn set_policy(&mut self, input: &ManagementPolicy) -> Result<ManagementHeld, Refused>;
	/// What is held, once every item past its grace is removed.
	fn describe(&mut self, now: u64) -> Result<ManagementDescribed, Refused>;
	/// An item the list no longer asks removed at once; one absent is no failure.
	fn end(&mut self, input: &ManagementEnd) -> Result<ManagementEnded, Refused>;
}

/// What every call is served with, the tokens and their files, the machine, each binding's list and
/// where it is kept, and the function kind over the container kind, each bucket a list's.
struct Driver {
	files: Vec<PathBuf>,
	tokens: RwLock<Tokens>,
	machine: Machine,
	lists: tokio::sync::Mutex<BTreeMap<Binding, Listed>>,
	kept: PathBuf,
	functions: Functions<Containers<Socket, Bridge, Btrfs, Https>>,
}

#[tokio::main]
async fn main() -> ExitCode {
	served::run(Arguments::parse()).await
}
