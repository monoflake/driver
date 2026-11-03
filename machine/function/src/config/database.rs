//! A slot filled with the binding's database, a wrapped binding over a service reaching its socket,
//! RFC rt6gi. Nothing of a credential is written here, the socket's directory being the binding's.

use super::quoted;
use crate::{DATABASE, SLOTS};

/// The internal module a database slot's binding is made by, as an extension gives it.
const MODULE: &str = "slots:database";

/// The module's source, small enough to read whole.
const SOURCE: &str = include_str!("database.mjs");

/// The service reaching the binding's database socket.
const SERVICE: &str = "database";

/// The name the module reads the service by, among its inner bindings.
const INNER: &str = "socket";

/// The service reaching the socket by HTTP.
pub(super) fn service() -> String {
	let address = quoted(&format!("unix:{SLOTS}/{DATABASE}"));
	format!("(name = {}, external = (address = {address}, http = ()))", quoted(SERVICE))
}

/// The extension giving the module, internal so no worker imports it itself.
pub(super) fn extension() -> String {
	format!(
		"(modules = [(name = {}, internal = true, esModule = {})])",
		quoted(MODULE),
		quoted(SOURCE)
	)
}

/// The slot's binding, its name the build's, wrapping the service.
pub(super) fn binding(name: &str) -> String {
	format!(
		"(name = {}, wrapped = (moduleName = {}, innerBindings = [(name = {}, service = {})]))",
		quoted(name),
		quoted(MODULE),
		quoted(INNER),
		quoted(SERVICE)
	)
}
