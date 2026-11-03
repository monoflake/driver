//! The call a request came in with, held for that request so each store call carries its step,
//! RFC 49qyg, run by node and by workerd itself.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use common::{bundle, from_root, hash, json, node};
use driver_machine_function::{Bundle, Configure, MODULES, Unpack, Worker};
use envelope::contracts::{
	AppBindings, DeploymentArtifact, DeploymentDeploy, DeploymentForm, DeploymentIsolation,
	DeploymentNetwork, DeploymentRuns,
};
use serde_json::{Value, json};

/// A call's id whose high 48 bits are its milliseconds, `0x0123456789ab`.
const FIRST: &str = "0123456789abcdef";
const SECOND: &str = "0123456789ac0001";

/// A deploy of `call-modules` run as `runs`, filling `records` with database 1 and `images` with
/// bucket 7 where `stores`.
fn deploying(runs: DeploymentRuns, stores: bool) -> DeploymentDeploy {
	let built = hash(&bundle("call-modules"));
	let bindings = AppBindings {
		app: None,
		database: Some(BTreeMap::from([("records".to_owned(), 1)])),
		bucket: Some(BTreeMap::from([("images".to_owned(), 7)])),
	};
	DeploymentDeploy {
		runs,
		version: built,
		form: DeploymentForm::Modules,
		runtime: None,
		isolation: vec![DeploymentIsolation::Isolate],
		artifact: DeploymentArtifact {
			address: "call-modules".into(),
			hash: built,
			architecture: None,
		},
		footing: "https://footing.invalid".into(),
		secrets: None,
		network: vec![DeploymentNetwork::Http],
		into: None,
		port: None,
		ingress: None,
		bindings: stores.then_some(bindings),
		handed: None,
		reaching: None,
	}
}

fn app() -> DeploymentRuns {
	DeploymentRuns::App { id: 0x2a }
}

fn fixture() -> Bundle {
	Bundle::unpack(&bundle("call-modules")).unwrap()
}

/// The protocol's call timing, as the driver reads it.
fn calls() -> Value {
	json(&from_root("../platform/model/protocol/calls.json"))
}

/// The step a store call carries, its expiry the id's milliseconds and the protocol's `idLife`.
fn step(id: &str, sequence: u32, last: bool) -> Value {
	let milliseconds = u64::from_str_radix(&id[..12], 16).unwrap();
	let expires = milliseconds + calls()["idLife"].as_u64().unwrap();
	json!({ "id": id, "sequence": sequence, "expires": expires, "last": last })
}

/// What node prints awaiting `asked`, `ask(call, wait)` fetching the fixture's entry wrapped as
/// workerd's is, each store call answered by what it posted.
fn ran(asked: &str) -> Value {
	let config = Worker::of(&deploying(app(), true), &fixture()).capnp();
	let entry = String::from_utf8(fixture().modules[0].bytes.clone()).unwrap();
	let script = format!(
		"const {{ AsyncLocalStorage }} = await import('node:async_hooks');
const {{ entered }} = await imported('slots:entry');
const database = (await imported('slots:database')).default;
const bucket = (await imported('slots:bucket')).default;
const fixture = (await import('data:text/javascript,' + encodeURIComponent({entry:?}))).default;
const socket = {{ fetch: async (url, init) => {{
	const body = JSON.parse(init.body);
	return Response.json({{ status: 'success', data: body.input ?? body }});
}} }};
const env = {{ records: database({{ socket }}), images: bucket({{ socket }}) }};
const storage = new AsyncLocalStorage();
const calls = {calls};
const app = entered(fixture, storage, calls);
const ask = async (call, wait = 0) => {{
	const headers = call === null ? {{}} : {{ call }};
	return (await app.fetch(new Request(`http://app/?wait=${{wait}}`, {{ headers }}), env)).json();
}};
console.log(JSON.stringify(await {asked}));",
		calls = calls()
	);
	serde_json::from_str(node(&config, &script).trim()).unwrap()
}

#[test]
fn two_store_calls_in_one_request_are_numbered_one_and_two_with_last_from_the_option() {
	let out = ran(&format!("ask('{FIRST}')"));
	assert_eq!(out, json!([step(FIRST, 1, false), step(FIRST, 2, true)]));
	// A class entry is wrapped as an object one is, the same call held for its fetch.
	let out = ran(&format!(
		"(async () => {{
	const Entry = entered(class {{ fetch(request) {{ return fixture.fetch(request, env); }} }});
	const request = new Request('http://app/?wait=0', {{ headers: {{ call: '{SECOND}' }} }});
	return (await new Entry().fetch(request)).json();
}})()"
	));
	assert_eq!(out, json!([step(SECOND, 1, false), step(SECOND, 2, true)]));
}

#[test]
fn a_request_without_a_call_adds_none_and_one_the_app_gives_is_dropped() {
	assert_eq!(ran("ask(null)"), json!([null, null]));
	assert_eq!(ran("ask('not-a-call-id')"), json!([null, null]));
	let given = "env.records.execute({ statements: [], call: { id: 'ffffffffffffffff' } })";
	assert_eq!(ran(given), json!({ "statements": [] }));
}

#[test]
fn two_concurrent_requests_keep_their_own_sequences() {
	let out = ran(&format!("Promise.all([ask('{FIRST}', 50), ask('{SECOND}', 0), ask(null, 10)])"));
	let first = json!([step(FIRST, 1, false), step(FIRST, 2, true)]);
	let second = json!([step(SECOND, 1, false), step(SECOND, 2, true)]);
	assert_eq!(out, json!([first, second, [null, null]]));
}

#[test]
fn an_app_filling_a_store_slot_has_its_entry_wrapped_and_nodejs_als_once() {
	let worker = Worker::of(&deploying(app(), true), &fixture());
	assert!(worker.entered);
	assert_eq!(worker.compatibility_flags, ["nodejs_als"]);
	let config = worker.capnp();
	let wrapping = "modules = [\n\t\t(name = \"driver:entry\", esModule = \"import { AsyncLocalStorage } \
	                from 'node:async_hooks';";
	assert!(config.contains(wrapping), "{config}");
	assert!(config.contains("import * as app from \\\"./index.js\\\";"), "{config}");
	assert!(config.contains("\\\"idLife\\\""), "{config}");
	assert!(config.contains("(name = \"slots:call\", internal = true, esModule = "), "{config}");
	// A bundle asking the flag itself is given it once.
	let asked = Bundle { compatibility_flags: vec!["nodejs_als".into()], ..fixture() };
	assert_eq!(Worker::of(&deploying(app(), true), &asked).compatibility_flags, ["nodejs_als"]);
	// An app filling no store slot, and a component, are run as they were.
	for input in [
		deploying(app(), false),
		deploying(DeploymentRuns::Component { component: "storage".into(), id: 5 }, true),
		deploying(DeploymentRuns::Component { component: "compute".into(), id: 5 }, true),
	] {
		let worker = Worker::of(&input, &fixture());
		assert!(!worker.entered && worker.compatibility_flags.is_empty(), "{input:?}");
		assert!(!worker.capnp().contains("driver:entry"), "{input:?}");
	}
}

/// workerd from the package wrangler installs, as the driver's packages are.
fn workerd() -> PathBuf {
	let script = "const { createRequire } = await import('node:module');
const wrangler = createRequire(process.argv[1]).resolve('wrangler');
const workerd = createRequire(wrangler)('workerd');
console.log(workerd.default);";
	let package = from_root("cloudflare/package.json");
	let out = Command::new("node")
		.args(["--input-type=module", "--eval", script, package.to_str().unwrap()])
		.output()
		.expect("node, as mise gives it");
	assert!(out.status.success(), "workerd is installed with the driver's packages");
	PathBuf::from(String::from_utf8(out.stdout).unwrap().trim())
}

/// workerd serving, stopped as the test ends however it ends.
struct Serving(Child, PathBuf);

impl Drop for Serving {
	fn drop(&mut self) {
		let _ = self.0.kill();
		let _ = self.0.wait();
		let _ = std::fs::remove_dir_all(&self.1);
	}
}

/// A free port of the loopback, as the system hands one out.
fn free() -> u16 {
	std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

/// The configuration made for the fixture, listening on `port` and its store slots answered by a
/// worker posting back what each was posted, as the sockets would be.
fn served(port: u16) -> String {
	let config = Worker::of(&deploying(app(), true), &fixture()).capnp();
	let config = config.replace("\"*:8080\"", &format!("\"127.0.0.1:{port}\""));
	let mut lines: Vec<String> = config
		.lines()
		.map(|line| match line.trim_start().strip_prefix("(name = \"") {
			Some(rest) if rest.starts_with("database-") || rest.starts_with("bucket-") => {
				let name = &rest[..rest.find('"').unwrap()];
				let end = if line.ends_with(',') { "," } else { "" };
				format!("\t\t(name = \"{name}\", worker = .posted){end}")
			}
			_ => line.to_owned(),
		})
		.collect();
	lines.push(
		"const posted :Workerd.Worker = (
	modules = [(name = \"posted.js\", esModule = \"export default { async fetch(request) { \
		 const body = await request.json(); return Response.json({ status: 'success', data: \
		 body.input ?? body }); } };\")],
	compatibilityDate = \"2024-01-01\"
);"
			.to_owned(),
	);
	lines.join("\n")
}

/// The fixture's answer to a request carrying `call`, which waits `wait` milliseconds between its
/// store calls.
fn asked(port: u16, call: Option<&str>, wait: u32) -> Value {
	let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
	let header = call.map(|c| format!("Call: {c}\r\n")).unwrap_or_default();
	let request =
		format!("GET /?wait={wait} HTTP/1.1\r\nHost: app\r\n{header}Connection: close\r\n\r\n");
	stream.write_all(request.as_bytes()).unwrap();
	let mut answer = String::new();
	stream.read_to_string(&mut answer).unwrap();
	let (head, body) = answer.split_once("\r\n\r\n").unwrap();
	assert!(head.starts_with("HTTP/1.1 200"), "{answer}");
	serde_json::from_str(body).unwrap()
}

#[test]
fn workerd_gives_async_local_storage_by_nodejs_als_and_holds_each_request_s_call() {
	let directory = std::env::temp_dir().join(format!("function-calls-{}", std::process::id()));
	let _ = std::fs::remove_dir_all(&directory);
	std::fs::create_dir_all(directory.join(MODULES)).unwrap();
	for module in fixture().modules {
		std::fs::write(directory.join(MODULES).join(&module.name), &module.bytes).unwrap();
	}
	let port = free();
	std::fs::write(directory.join("config.capnp"), served(port)).unwrap();
	let child = Command::new(workerd())
		.args(["serve", "config.capnp"])
		.current_dir(&directory)
		.stdout(Stdio::null())
		.stderr(Stdio::piped())
		.spawn()
		.unwrap();
	let mut serving = Serving(child, directory);
	let started = Instant::now();
	while TcpStream::connect(("127.0.0.1", port)).is_err() {
		if let Some(status) = serving.0.try_wait().unwrap() {
			let mut stderr = String::new();
			serving.0.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();
			panic!("workerd ended {status} {stderr}");
		}
		assert!(started.elapsed() < Duration::from_secs(20), "workerd never listened");
		std::thread::sleep(Duration::from_millis(50));
	}
	// The fixture's date predates nodejs_compat, so `node:async_hooks` is the flag's alone.
	let slow = std::thread::spawn(move || asked(port, Some(FIRST), 300));
	std::thread::sleep(Duration::from_millis(100));
	let fast = asked(port, Some(SECOND), 0);
	assert_eq!(fast, json!([step(SECOND, 1, false), step(SECOND, 2, true)]));
	assert_eq!(slow.join().unwrap(), json!([step(FIRST, 1, false), step(FIRST, 2, true)]));
	assert_eq!(asked(port, None, 0), json!([null, null]));
	drop(serving);
}
