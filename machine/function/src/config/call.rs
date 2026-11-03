//! The call a request came in with, held for that request so each store call carries its step,
//! RFC 49qyg. An app's entry is wrapped by a module of the driver's, which holds its `Call` header
//! in `AsyncLocalStorage`, and the slot modules read it through `slots:call`.

use super::quoted;

/// The internal module holding each request's call, which the slot modules import.
const MODULE: &str = "slots:call";

/// The module the wrapping entry reaches [`MODULE`] through, giving `entered` alone.
const ENTRY: &str = "slots:entry";

/// The module's source, small enough to read whole.
const SOURCE: &str = include_str!("call.mjs");

/// The protocol's call timing, whose `idLife` the held call reads, RFC 49qyg.
const CALLS: &str = include_str!("../../../../../platform/model/protocol/calls.json");

/// The worker module wrapping the app's main one, a name no bundle's module has, each of those
/// named with an extension.
const ENTERED: &str = "driver:entry";

/// The compatibility flag giving `node:async_hooks` at any compatibility date.
pub(super) const FLAG: &str = "nodejs_als";

/// The extension giving the held call, its storage handed in by the wrapping entry alone.
pub(super) fn extension() -> String {
	let entry = format!("export {{ entered }} from '{MODULE}';\n");
	format!(
		"(modules = [(name = {}, internal = true, esModule = {}), (name = {}, esModule = {})])",
		quoted(MODULE),
		quoted(SOURCE),
		quoted(ENTRY),
		quoted(&entry)
	)
}

/// The module wrapping the app's main one, first among the worker's modules, exporting all it
/// does with its default export's fetch run within its request's call.
pub(super) fn module(main: &str) -> String {
	let from = serde_json::Value::String(format!("./{main}")).to_string();
	let source = format!(
		"import {{ AsyncLocalStorage }} from 'node:async_hooks';
import {{ entered }} from '{ENTRY}';
import * as app from {from};
export * from {from};
export default entered(app.default, new AsyncLocalStorage(), {});
",
		CALLS.trim()
	);
	format!("(name = {}, esModule = {})", quoted(ENTERED), quoted(&source))
}
