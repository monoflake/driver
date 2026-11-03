//! An `object_bucket` slot's socket made only once a deploy is answered, and served again at each
//! start from the fill kept beside it, RFC ahcrp; a deploy answered needs containerd, so the
//! lifecycle's own tests are the crate's, `served/bucket.rs`.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use common::Started;
use envelope::Encoded as _;
use envelope::contracts::{
	AppBindings, DeploymentArtifact, DeploymentDeploy, DeploymentForm, DeploymentIsolation,
	DeploymentOf, DeploymentRuns,
};
use serde_json::json;

/// A deploy of app 1's modules, its two `object_bucket` slots filled.
fn deploy() -> serde_json::Value {
	let bucket = Some([("a".to_owned(), 4), ("b".to_owned(), 5)].into());
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
		bindings: Some(AppBindings { app: None, database: None, bucket }),
	}
	.to_json()
}

#[test]
fn a_deploy_refused_makes_no_socket_and_a_delete_leaves_none() {
	let driver = Started::short("bucket-refused", 1);
	let object = json!({ "id": 2, "capacity": { "name": "object", "size": 1024 },
		"credentials": ["00".repeat(32)] });
	let (status, answer) =
		driver.call(1, "management", "apply", &json!({ "generation": 1, "items": [object] }));
	assert_eq!(status, 200, "{answer}");
	let (_, answer) = driver.call(1, "deployments", "deploy", &deploy());
	assert_eq!(answer["reason"], "beyond_host", "{answer}");
	let apps = driver.state().join("slots/apps");
	assert!(!apps.join("b00000001/00000001").exists());
	let delete = DeploymentOf { runs: DeploymentRuns::App { id: 1 } }.to_json();
	let (status, answer) = driver.call(1, "deployments", "delete", &delete);
	assert_eq!((status, &answer["status"]), (200, &json!("success")), "{answer}");
	assert!(!apps.join("b00000001/00000001").exists());
}

/// The status line a request on a socket is answered with.
fn answered(socket: &std::path::Path) -> String {
	use std::io::{Read as _, Write as _};
	let mut stream = std::os::unix::net::UnixStream::connect(socket).unwrap();
	let head = "POST /storage/object_list HTTP/1.1\r\nHost: localhost\r\n\
		Connection: close\r\nContent-Length: 0\r\n\r\n";
	stream.write_all(head.as_bytes()).unwrap();
	let mut read = String::new();
	stream.read_to_string(&mut read).unwrap();
	read.lines().next().unwrap_or_default().to_owned()
}

#[test]
fn a_restart_serves_again_each_deployment_s_sockets_its_fill_keeps() {
	let driver = Started::short("bucket-restart", 1);
	let object = json!({ "id": 2, "capacity": { "name": "object", "size": 1024 },
		"credentials": ["00".repeat(32)] });
	let (status, answer) =
		driver.call(1, "management", "apply", &json!({ "generation": 1, "items": [object] }));
	assert_eq!(status, 200, "{answer}");
	// A fill as a deploy answered keeps it, and one that does not parse beside it.
	let apps = driver.state().join("slots/apps/b00000001");
	let runs = DeploymentRuns::App { id: 1 }.to_json();
	std::fs::create_dir_all(apps.join("00000001")).unwrap();
	let fill = json!({ "runs": runs, "bucket": { "a": 4, "b": 5 } });
	std::fs::write(apps.join("00000001/fill.json"), fill.to_string()).unwrap();
	std::fs::create_dir_all(apps.join("00000002")).unwrap();
	std::fs::write(apps.join("00000002/fill.json"), b"{").unwrap();
	let driver = driver.restarted();
	for socket in ["a.sock", "b.sock"] {
		assert!(answered(&apps.join("00000001").join(socket)).starts_with("HTTP/1.1 "));
	}
	assert!(!apps.join("00000002/a.sock").exists());
	// Served again by every start, the sockets the last run left replaced.
	let driver = driver.restarted();
	assert!(answered(&apps.join("00000001/a.sock")).starts_with("HTTP/1.1 "));
	let delete = DeploymentOf { runs: DeploymentRuns::App { id: 1 } }.to_json();
	assert_eq!(driver.call(1, "deployments", "delete", &delete).0, 200);
	assert!(!apps.join("00000001").exists());
}
