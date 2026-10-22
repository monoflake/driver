//! `driver(machine)`'s function, modules run by workerd, one process for each deployment in a
//! container of its binding's, RFC vr5lw. This file is its interface, the model's, `docs/code.md`.

use std::path::PathBuf;

use driver_machine_container::Refused;
use envelope::contracts::{DeploymentDeploy, DeploymentIsolation};

mod bundle;
mod config;
mod functions;

/// The port workerd listens on in its container, which its deployment's address names.
pub const PORT: u16 = 8080;

/// Where workerd's configuration and modules are bound in its container, read-only.
pub const AT: &str = "/worker";

/// workerd's configuration, below [`AT`].
pub const CONFIG: &str = "config.capnp";

/// The directory below [`AT`] holding each module by its name.
pub const MODULES: &str = "modules";

/// What names a bundle's main module and its compatibility, beside its modules in its archive,
/// RFC dg903.
pub const METADATA: &str = "metadata.json";

/// What names the footing's address to a worker, as the container kind names it to an image.
pub const FOOTING: &str = "MONOFLAKE_FOOTING";

/// The isolation workerd in a container stands on, RFC vr5lw.
pub const STANDS: [DeploymentIsolation; 2] =
	[DeploymentIsolation::Isolate, DeploymentIsolation::Kernel];

/// The function kind, modules run by workerd as containers of the container kind, which fetches,
/// networks, bounds and keeps secrets for it; `driver-machine-container`'s `Deployments`.
#[derive(Debug, Clone)]
pub struct Functions<K> {
	/// The container kind.
	pub containers: K,
	/// workerd's image, monoflake/runtime's OCI archive on the machine.
	pub workerd: PathBuf,
}

/// A module's type, as workerd's configuration names it, read from its name's extension.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
	/// `.js` or `.mjs`, an ES module.
	Es,
	/// `.cjs`, a CommonJS module.
	CommonJs,
	/// `.wasm`, a WebAssembly module.
	Wasm,
	/// `.txt`, a text.
	Text,
	/// `.bin`, bytes.
	Data,
	/// `.json`, a JSON value.
	Json,
}

/// A module of a bundle, by the name its imports give it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Module {
	/// Its name, its path in the bundle.
	pub name: String,
	/// Its type.
	pub kind: Kind,
	/// Its bytes.
	pub bytes: Vec<u8>,
}

/// A bundle of modules as its artifact holds it, RFC dg903.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bundle {
	/// Its modules, its main one first.
	pub modules: Vec<Module>,
	/// The date of workerd's behavior it is written for, `YYYY-MM-DD`.
	pub compatibility_date: String,
	/// The flags of workerd's behavior it asks beyond its date.
	pub compatibility_flags: Vec<String>,
}

/// A binding workerd gives a worker, by its name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Bound {
	/// A text written in the configuration.
	Text {
		/// Its name.
		name: String,
		/// Its text.
		text: String,
	},
	/// A secret, its text read from its file among the container's secrets as workerd starts.
	Secret {
		/// Its name, its file's.
		name: String,
	},
}

/// What workerd is configured with for one deployment, its bundle's modules, its bindings, its
/// address and whether it may reach out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Worker {
	/// Each module's name and type, its main one first.
	pub modules: Vec<(String, Kind)>,
	/// Its bundle's compatibility date.
	pub compatibility_date: String,
	/// Its bundle's compatibility flags.
	pub compatibility_flags: Vec<String>,
	/// Its bindings, the footing's address first.
	pub bindings: Vec<Bound>,
	/// The port it listens on, at every address of its container's.
	pub port: u16,
	/// Whether it may reach the internet, as its deployment's `http` or `tcp` network allows.
	pub outbound: bool,
}

/// A bundle read from its artifact's bytes, RFC dg903; implemented for [`Bundle`].
pub trait Unpack: Sized {
	/// The bundle, or `malformed` where the bytes are none.
	fn unpack(bytes: &[u8]) -> Result<Self, Refused>;
}

/// workerd's configuration made for a deployment and written; implemented for [`Worker`].
pub trait Configure: Sized {
	/// What workerd runs a deployment's bundle with.
	fn of(input: &DeploymentDeploy, bundle: &Bundle) -> Self;
	/// Its configuration in Cap'n Proto's text, as `workerd serve` reads it, its modules embedded
	/// from [`MODULES`] beside it.
	fn capnp(&self) -> String;
}
