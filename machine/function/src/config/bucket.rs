//! A slot filled with a bucket of the storage product, a wrapped binding over a service reaching
//! the deployment's own socket for it, RFC ahcrp. The driver sets the bucket, so none is written.

use super::quoted;
use crate::{BUCKETS, bucket_socket};

/// The internal module a bucket slot's binding is made by, as an extension gives it.
const MODULE: &str = "slots:bucket";

/// The module's source, small enough to read whole.
const SOURCE: &str = include_str!("bucket.mjs");

/// The name the module reads the service by, among its inner bindings.
const INNER: &str = "socket";

/// The service reaching a slot's socket, by the slot's name.
fn named(slot: &str) -> String {
	format!("bucket-{slot}")
}

/// The service reaching the slot's socket by HTTP.
pub(super) fn service(slot: &str) -> String {
	let address = quoted(&format!("unix:{BUCKETS}/{}", bucket_socket(slot)));
	format!("(name = {}, external = (address = {address}, http = ()))", quoted(&named(slot)))
}

/// The extension giving the module, internal so no worker imports it itself.
pub(super) fn extension() -> String {
	format!(
		"(modules = [(name = {}, internal = true, esModule = {})])",
		quoted(MODULE),
		quoted(SOURCE)
	)
}

/// The slot's binding, its name the build's, wrapping its service.
pub(super) fn binding(slot: &str) -> String {
	format!(
		"(name = {}, wrapped = (moduleName = {}, innerBindings = [(name = {}, service = {})]))",
		quoted(slot),
		quoted(MODULE),
		quoted(INNER),
		quoted(&named(slot))
	)
}
