//! A slot filled with the binding's database, a wrapped binding over a service reaching its socket,
//! RFC rt6gi. Nothing of a credential is written here, the socket's directory being the binding's.

use super::quoted;
use crate::SLOTS;

/// The internal module a database slot's binding is made by, as an extension gives it.
const MODULE: &str = "slots:database";

/// The module's source, small enough to read whole.
const SOURCE: &str = include_str!("database.mjs");

/// The name the module reads the service by, among its inner bindings.
const INNER: &str = "socket";

/// The service's name, an item's whole socket or its status one.
fn named(id: u32, status: bool) -> String {
	match status {
		false => format!("database-{id:08x}"),
		true => format!("database-{id:08x}-status"),
	}
}

/// The service reaching the item's socket by HTTP, its status socket where `status`.
pub(super) fn service(id: u32, status: bool) -> String {
	let socket = match status {
		false => format!("database-{id:08x}.sock"),
		true => format!("database-{id:08x}.status.sock"),
	};
	let address = quoted(&format!("unix:{SLOTS}/{socket}"));
	format!("(name = {}, external = (address = {address}, http = ()))", quoted(&named(id, status)))
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
pub(super) fn binding(name: &str, id: u32, status: bool) -> String {
	format!(
		"(name = {}, wrapped = (moduleName = {}, innerBindings = [(name = {}, service = {})]))",
		quoted(name),
		quoted(MODULE),
		quoted(INNER),
		quoted(&named(id, status))
	)
}
