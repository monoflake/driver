# workerd's configuration for one deployment, written by driver(machine)'s function kind.
using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
	services = [
		(name = "main", worker = .worker),
		(name = "outbound", network = (allow = ["public"], tlsOptions = (trustBrowserCas = true)))
	],
	sockets = [(name = "http", address = "*:8080", http = (), service = "main")]
);

const worker :Workerd.Worker = (
	modules = [
		(name = "index.js", esModule = embed "modules/index.js"),
		(name = "lib/answer.js", esModule = embed "modules/lib/answer.js")
	],
	compatibilityDate = "2026-10-21",
	compatibilityFlags = [],
	bindings = [
		(name = "MONOFLAKE_FOOTING", text = "https://footing.invalid")
	],
	globalOutbound = "outbound"
);
