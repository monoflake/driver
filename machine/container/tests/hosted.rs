//! `Containers` hosting a runtime of the machine's own, from its own archive with its files
//! bound.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::collections::BTreeMap;
use std::path::PathBuf;

use common::{Driver, binding, driver, echo, lines, of, reason, shell, spec_of};
use driver_machine_container::{Deployments, Host, Hosted};
use envelope::contracts::{
	DeploymentDeploy, DeploymentForm, DeploymentIsolation, DeploymentRuntime, DeploymentState,
};

/// A runtime of the machine's own, as the function kind hosts workerd, its archive in the state.
fn hosted(driver: &Driver) -> Hosted {
	let image = driver.state.join("workerd.tar");
	std::fs::write(&image, b"workerd image").unwrap();
	Hosted {
		image,
		cmd: vec!["serve".into(), "/worker/config.capnp".into()],
		port: 8080,
		files: BTreeMap::from([
			("config.capnp".into(), b"config".to_vec()),
			("modules/index.js".into(), b"export default {}".to_vec()),
		]),
		at: "/worker".into(),
		runtime: DeploymentRuntime::Workerd,
		isolation: vec![DeploymentIsolation::Isolate, DeploymentIsolation::Kernel],
	}
}

#[tokio::test]
async fn a_hosted_runtime_runs_from_its_own_archive_with_its_files_bound() {
	let (driver, log) = driver("hosted", shell(), false);
	let hosted = hosted(&driver);
	let input = DeploymentDeploy { form: DeploymentForm::Modules, port: None, ..echo() };
	let deployed = driver.host(&binding(), input.clone(), hosted.clone()).await.unwrap();
	let isolation = vec![DeploymentIsolation::Isolate, DeploymentIsolation::Kernel];
	let running = DeploymentState::Running {
		address: "10.88.0.2:8080".into(),
		runtime: DeploymentRuntime::Workerd,
		isolation: isolation.clone(),
	};
	assert_eq!(deployed.state, running);
	assert_eq!(driver.describe(&binding(), of()).await.unwrap().state, running);
	// Its archive is the machine's, imported and kept, and nothing is fetched for it.
	assert!(hosted.image.exists());
	assert!(lines(&log).contains(&"import b1 workerd image".to_owned()));
	assert!(!lines(&log).iter().any(|l| l.starts_with("fetch")));
	let spec = spec_of(&driver);
	assert_eq!(spec.binary, PathBuf::from("/bin/runc"));
	let s = &spec.runtime_spec;
	assert_eq!(s["process"]["args"], serde_json::json!(["serve", "/worker/config.capnp"]));
	let files = driver.state.join("files/b1").join(&spec.id);
	let bound = s["mounts"].as_array().unwrap().iter().find(|m| m["destination"] == "/worker");
	assert_eq!(
		bound.unwrap(),
		&serde_json::json!({
			"destination": "/worker",
			"type": "bind",
			"source": files,
			"options": ["rbind", "ro", "nosuid", "nodev", "noexec"],
		})
	);
	assert_eq!(std::fs::read(files.join("modules/index.js")).unwrap(), b"export default {}");
	// Hosted again the same, it is the one deployment, and stopped and deleted, its files go.
	driver.host(&binding(), input, hosted).await.unwrap();
	assert_eq!(driver.containerd.held.lock().unwrap().len(), 1);
	driver.stop(&binding(), of()).await.unwrap();
	driver.delete(&binding(), of()).await.unwrap();
	assert!(!files.exists());
}

#[tokio::test]
async fn a_hosted_runtime_runs_in_a_container_of_the_binding_and_names_its_files_below_it() {
	let (driver, _) = driver("hosted-refused", shell(), false);
	let modules = DeploymentDeploy { form: DeploymentForm::Modules, port: None, ..echo() };
	let refused = driver
		.host(&binding(), DeploymentDeploy { into: Some(9), ..modules.clone() }, hosted(&driver))
		.await;
	assert_eq!(refused.map_err(reason), Err("beyond_host"));
	let escaping =
		Hosted { files: BTreeMap::from([("../escaped".into(), b"x".to_vec())]), ..hosted(&driver) };
	assert_eq!(driver.host(&binding(), modules, escaping).await.map_err(reason), Err("malformed"));
	assert!(!driver.state.join("files/b1/escaped").exists());
	assert!(driver.containerd.held.lock().unwrap().is_empty());
}
