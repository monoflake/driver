//! A binding's database on its own Unix socket, reached with no token, and a deploy's `bindings`
//! held to what the binding holds, RFC rt6gi.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::io::{Read as _, Write as _};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};

use common::Started;
use envelope::Encoded as _;
use envelope::contracts::{
	AppBindings, DeploymentArtifact, DeploymentDeploy, DeploymentForm, DeploymentIsolation,
	DeploymentRuns,
};
use serde_json::{Value, json};

fn item(id: u32) -> Value {
	json!({ "id": id, "capacity": { "name": "database", "size": 1048576 },
		"credentials": ["00".repeat(32)] })
}

fn apply(driver: &Started, generation: u32, items: Vec<Value>) {
	let input = json!({ "generation": generation, "items": items });
	let (status, answer) = driver.call(1, "management", "apply", &input);
	assert_eq!(status, 200, "{answer}");
}

/// Binding 1's database socket, as the driver names it under its state.
fn socket(driver: &Started) -> PathBuf {
	driver.state().join("slots/b00000001/database.sock")
}

/// A call in JSON on a socket, carrying no token, and its status and answer.
fn called(socket: &Path, interface: &str, operation: &str, input: &Value) -> (u16, Value) {
	let body =
		serde_json::to_vec(&json!({ "interface": interface, "operation": operation, "input": input }))
			.unwrap();
	let mut stream = UnixStream::connect(socket).unwrap();
	let head = format!(
		"POST /{interface}/{operation} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\
		Content-Type: application/json\r\nContent-Length: {}\r\n\r\n",
		body.len()
	);
	stream.write_all(head.as_bytes()).unwrap();
	stream.write_all(&body).unwrap();
	let mut read = Vec::new();
	stream.read_to_end(&mut read).unwrap();
	let split = read.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
	let head = String::from_utf8(read[..split].to_vec()).unwrap();
	let status = head.split(' ').nth(1).unwrap().parse().unwrap();
	(status, serde_json::from_slice(&read[split + 4..]).unwrap())
}

fn execute(socket: &Path) -> (u16, Value) {
	called(socket, "database", "execute", &json!({ "statements": [{ "sql": "select 1 as one" }] }))
}

#[test]
fn an_execute_on_the_binding_s_socket_is_answered_with_no_token() {
	let driver = Started::short("slot-execute", 1);
	assert!(!socket(&driver).exists(), "no socket before the database");
	apply(&driver, 1, vec![item(1)]);
	let (status, answer) = execute(&socket(&driver));
	assert_eq!(status, 200, "{answer}");
	assert_eq!(answer["status"], "success");
	let line = driver.logged("database execute");
	assert!(line.starts_with("database execute success "), "{line}");
	// Made again at start, the socket the last run left replaced.
	let driver = driver.restarted();
	let (status, answer) = execute(&socket(&driver));
	assert_eq!(status, 200, "{answer}");
}

#[test]
fn a_binding_s_socket_serves_its_database_alone() {
	let driver = Started::short("slot-alone", 1);
	apply(&driver, 1, vec![item(1)]);
	for (interface, operation) in
		[("management", "describe"), ("deployments", "describe"), ("object", "list"), ("other", "x")]
	{
		let (status, answer) = called(&socket(&driver), interface, operation, &json!({}));
		assert_eq!(status, 400, "{answer}");
		assert_eq!(answer["reason"], "malformed");
		assert_eq!(answer["message"], format!("no interface {interface}, one of database"));
	}
}

#[test]
fn the_socket_goes_with_its_database_item() {
	let driver = Started::short("slot-gone", 1);
	apply(&driver, 1, vec![item(1)]);
	assert!(socket(&driver).exists());
	apply(&driver, 2, vec![]);
	assert!(socket(&driver).exists(), "an item unasked keeps its database within its grace");
	assert_eq!(driver.call(1, "management", "end", &json!({ "id": 1 })).0, 200);
	assert!(!socket(&driver).exists());
	// Gone at start as well, where the database is held no longer.
	let driver = driver.restarted();
	assert!(!socket(&driver).exists());
	apply(&driver, 3, vec![item(2)]);
	assert_eq!(execute(&socket(&driver)).0, 200);
}

/// A deploy of modules, its slots filled by `bindings`.
fn deploy(bindings: AppBindings) -> Value {
	DeploymentDeploy {
		runs: DeploymentRuns::App { id: 1 },
		version: [0; 32],
		form: DeploymentForm::Modules,
		runtime: None,
		isolation: vec![DeploymentIsolation::Isolate],
		artifact: DeploymentArtifact {
			address: "https://artifact.invalid/bundle".into(),
			hash: [0; 32],
			architecture: None,
		},
		footing: "https://footing.invalid".into(),
		secrets: None,
		network: Vec::new(),
		into: None,
		port: None,
		handed: None,
		reaching: None,
		ingress: None,
		bindings: Some(bindings),
	}
	.to_json()
}

fn slots(name: &str, id: u32) -> Option<std::collections::BTreeMap<String, u32>> {
	Some([(name.to_owned(), id)].into())
}

#[test]
fn a_deploy_naming_a_database_the_binding_does_not_hold_is_refused_invalid() {
	let driver = Started::short("slot-deploy", 1);
	apply(&driver, 1, vec![item(2)]);
	let unheld = AppBindings { app: None, database: slots("database", 5), bucket: None };
	let (status, answer) = driver.call(1, "deployments", "deploy", &deploy(unheld));
	assert_eq!(status, 400, "{answer}");
	assert_eq!(answer["reason"], "invalid");
	assert_eq!(
		answer["message"],
		"the slot database names the database 5, and the binding holds item 2's"
	);
	let bucket = AppBindings { app: None, database: None, bucket: slots("files", 1) };
	let (_, answer) = driver.call(1, "deployments", "deploy", &deploy(bucket));
	assert_eq!(answer["reason"], "invalid", "{answer}");
	let app = AppBindings { app: slots("peer", 1), database: None, bucket: None };
	let (_, answer) = driver.call(1, "deployments", "deploy", &deploy(app));
	assert_eq!(answer["reason"], "invalid", "{answer}");
	// The database held passes, and the deploy goes on to what it is refused today.
	let held = AppBindings { app: None, database: slots("database", 2), bucket: None };
	let (_, answer) = driver.call(1, "deployments", "deploy", &deploy(held));
	assert_eq!(answer["reason"], "beyond_host", "{answer}");
}
