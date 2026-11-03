//! workerd's configuration for a deploy filling a database slot, RFC rt6gi, and the module its
//! binding is made by, run by node against a fake fetch.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::collections::BTreeMap;
use std::io::Write;
use std::process::{Command, Stdio};

use common::{bundle, from_root, hash, hex, json};
use driver_machine_function::{Bound, Bundle, Configure, Unpack, Worker};
use envelope::Called;
use envelope::contracts::interface::deployments::Call;
use envelope::contracts::{AppBindings, DeploymentDeploy};

/// The first deploy of `deploys.json`, its bindings filling the slots given.
fn filling(slots: &[(&str, u32)]) -> DeploymentDeploy {
	let sample = json(&from_root("../platform/tests/kinds/deployments/deploys.json"));
	let mut input = sample["cases"][0]["steps"][0]["input"].clone();
	let built = hex(&hash(&bundle("echo-modules")));
	input["version"] = built.clone().into();
	input["form"] = "modules".into();
	input["artifact"] = serde_json::json!({ "address": "echo-modules", "hash": built });
	let Call::Deploy(input) = Call::from_json("deploy", &input).unwrap() else {
		panic!("not a deploy")
	};
	let database: BTreeMap<String, u32> =
		slots.iter().map(|(n, id)| ((*n).to_owned(), *id)).collect();
	let bindings = AppBindings { app: None, database: Some(database), bucket: None };
	DeploymentDeploy { bindings: Some(bindings), ..input }
}

/// A Cap'n Proto string read back from where it opens, its escapes undone.
fn unquoted(from: &str) -> String {
	let mut bytes = Vec::new();
	let mut chars = from.strip_prefix('"').unwrap().chars();
	while let Some(c) = chars.next() {
		match c {
			'"' => return String::from_utf8(bytes).unwrap(),
			'\\' => match chars.next().unwrap() {
				'x' => {
					let hex: String = chars.by_ref().take(2).collect();
					bytes.push(u8::from_str_radix(&hex, 16).unwrap());
				}
				escaped => bytes.extend(escaped.to_string().bytes()),
			},
			c => bytes.extend(c.to_string().bytes()),
		}
	}
	panic!("a string left open")
}

#[test]
fn a_database_slot_is_a_wrapped_binding_over_the_binding_s_database_socket() {
	let bundle = Bundle::unpack(&bundle("echo-modules")).unwrap();
	let worker = Worker::of(&filling(&[("records", 7), ("database", 7)]), &bundle);
	let slots: Vec<&Bound> =
		worker.bindings.iter().filter(|b| matches!(b, Bound::Database { .. })).collect();
	let named = |name: &str| Bound::Database { name: name.to_owned() };
	assert_eq!(slots, [&named("database"), &named("records")]);
	let config = worker.capnp();
	let service = "(name = \"database\", external = (address = \"unix:/run/slots/database.sock\", \
	               http = ()))";
	assert!(config.contains(service), "{config}");
	for slot in ["database", "records"] {
		let binding = format!(
			"(name = \"{slot}\", wrapped = (moduleName = \"slots:database\", innerBindings = \
			 [(name = \"socket\", service = \"database\")]))"
		);
		assert!(config.contains(&binding), "{config}");
	}
	let extension = "\textensions = [\n\t\t(modules = [(name = \"slots:database\", internal = \
	                 true, esModule = \"";
	assert!(config.contains(extension), "{config}");
	// No id of the database, token or credential is written for the worker to read.
	assert!(!config.contains("token") && !config.contains("credential"), "{config}");
	assert!(!config.contains("= 7") && !config.contains("\"7\""), "{config}");
}

#[test]
fn a_deploy_filling_no_database_slot_is_configured_as_before() {
	let bundle = Bundle::unpack(&bundle("echo-modules")).unwrap();
	let none = Worker::of(&filling(&[]), &bundle);
	let unfilled = DeploymentDeploy { bindings: None, ..filling(&[]) };
	assert_eq!(none.capnp(), Worker::of(&unfilled, &bundle).capnp());
	assert!(!none.capnp().contains("extensions"));
}

/// What node prints running the configuration's module against a fake fetch answering `answer`.
fn ran(answer: &str) -> String {
	let bundle = Bundle::unpack(&bundle("echo-modules")).unwrap();
	let config = Worker::of(&filling(&[("database", 1)]), &bundle).capnp();
	let at = config.find("esModule = ").unwrap() + "esModule = ".len();
	let source = unquoted(&config[at..]);
	let script = format!(
		"const source = await new Response(process.stdin).text();
const made = (await import('data:text/javascript,' + encodeURIComponent(source))).default;
const asked = [];
const socket = {{ fetch: async (url, init) => {{
	asked.push({{ url, method: init.method, type: init.headers['content-type'], body: JSON.parse(init.body) }});
	return new Response({answer:?});
}} }};
let result;
try {{ result = {{ data: await made({{ socket }}).execute({{ statements: [] }}) }}; }}
catch (error) {{ result = {{ thrown: error instanceof Error, message: error.message }}; }}
console.log(JSON.stringify({{ asked, result }}));"
	);
	let mut node = Command::new("node")
		.args(["--input-type=module", "--eval", &script])
		.stdin(Stdio::piped())
		.stdout(Stdio::piped())
		.spawn()
		.expect("node, as mise gives it");
	node.stdin.take().unwrap().write_all(source.as_bytes()).unwrap();
	let out = node.wait_with_output().unwrap();
	assert!(out.status.success(), "node failed");
	String::from_utf8(out.stdout).unwrap()
}

#[test]
fn execute_posts_the_call_and_answers_its_data() {
	let out = json_of(&ran("{\"status\":\"success\",\"data\":{\"results\":[]}}"));
	let asked = &out["asked"][0];
	assert_eq!(asked["url"], "http://database/database/execute");
	assert_eq!(asked["method"], "POST");
	assert_eq!(asked["type"], "application/json");
	let call = serde_json::json!({
		"interface": "database",
		"operation": "execute",
		"input": { "statements": [] },
	});
	assert_eq!(asked["body"], call);
	assert_eq!(out["result"], serde_json::json!({ "data": { "results": [] } }));
}

#[test]
fn a_refusal_is_thrown_with_its_reason_and_message() {
	let refused = "{\"status\":\"error\",\"reason\":\"invalid\",\"message\":\"no such table\"}";
	let out = json_of(&ran(refused));
	let thrown = serde_json::json!({ "thrown": true, "message": "invalid: no such table" });
	assert_eq!(out["result"], thrown);
}

fn json_of(text: &str) -> serde_json::Value {
	serde_json::from_str(text.trim()).unwrap()
}
