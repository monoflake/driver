//! Secrets carried between deployments from the runner's sealed copy.

#![cfg(test)]

mod common;

use std::collections::BTreeMap;
use std::path::PathBuf;

use common::{ECHO_TWO, binding, cleared, deploy, driver, echo, hash, lines, of, shell, spec_of};
use driver_machine_container::{Deployments, Host};
use envelope::contracts::{DeploymentDeploy, DeploymentRuns};

struct Cleanup(PathBuf);

impl Drop for Cleanup {
	fn drop(&mut self) {
		cleared(&self.0);
		let removed = std::process::Command::new("node")
			.args(["-e", "require('node:fs').rmSync(process.argv[1], {recursive:true, force:true})"])
			.arg(&self.0)
			.status()
			.unwrap();
		assert!(removed.success());
	}
}

#[tokio::test]
async fn absent_or_empty_secrets_keep_the_previous_sealed_copy() {
	for secrets in [None, Some(BTreeMap::new())] {
		let name = if secrets.is_none() { "env-absent" } else { "env-empty" };
		let (driver, log) = driver(name, shell(), false);
		let _cleanup = Cleanup(driver.state.clone());
		assert!(driver.secret_names(&binding(), &of().runs).await.unwrap().is_empty());
		driver.deploy(&binding(), echo()).await.unwrap();
		let old = spec_of(&driver).id;
		let open = driver.secrets.join("b1").join(&old);
		cleared(&open);
		std::fs::remove_dir_all(open).unwrap();
		assert_eq!(driver.secret_names(&binding(), &of().runs).await.unwrap(), ["TOKEN"]);
		let next = DeploymentDeploy { secrets, ..deploy("file:///echo-two.tar", ECHO_TWO) };
		driver.deploy(&binding(), next).await.unwrap();
		let new = spec_of(&driver).id;
		assert!(
			std::fs::read(driver.secrets.join("b1").join(&new).join("TOKEN")).unwrap() == b"hidden"
		);
		assert!(driver.state.join("secrets/b1").join(&new).join("TOKEN").exists());
		assert!(!driver.state.join("secrets/b1").join(old).exists());
		assert!(lines(&log).iter().all(|line| !line.contains("hidden")));
	}
}

#[tokio::test]
async fn one_name_overlays_the_previous_secrets_and_leaves_the_rest() {
	let (driver, _) = driver("env-overlay", shell(), false);
	let _cleanup = Cleanup(driver.state.clone());
	let first = DeploymentDeploy {
		secrets: Some(BTreeMap::from([
			("TOKEN".into(), b"hidden".to_vec()),
			("KEEP".into(), b"retained".to_vec()),
		])),
		..echo()
	};
	driver.deploy(&binding(), first).await.unwrap();
	let next = DeploymentDeploy {
		secrets: Some(BTreeMap::from([("TOKEN".into(), b"changed".to_vec())])),
		..deploy("file:///echo-two.tar", ECHO_TWO)
	};
	driver.deploy(&binding(), next).await.unwrap();
	assert_eq!(driver.secret_names(&binding(), &of().runs).await.unwrap(), ["KEEP", "TOKEN"]);
	let open = driver.secrets.join("b1").join(spec_of(&driver).id);
	assert!(std::fs::read(open.join("TOKEN")).unwrap() == b"changed");
	assert!(std::fs::read(open.join("KEEP")).unwrap() == b"retained");
	driver.stop(&binding(), of()).await.unwrap();
	cleared(&open);
	std::fs::remove_dir_all(&open).unwrap();
	driver.resume(&binding(), of()).await.unwrap();
	assert!(std::fs::read(open.join("TOKEN")).unwrap() == b"changed");
	assert!(std::fs::read(open.join("KEEP")).unwrap() == b"retained");
}

#[tokio::test]
async fn no_previous_for_this_app_gives_only_the_names_supplied() {
	let (driver, _) = driver("env-new-app", shell(), false);
	let _cleanup = Cleanup(driver.state.clone());
	driver.deploy(&binding(), echo()).await.unwrap();
	let next = DeploymentDeploy { runs: DeploymentRuns::App { id: 2 }, secrets: None, ..echo() };
	assert!(driver.secret_names(&binding(), &next.runs).await.unwrap().is_empty());
	driver.deploy(&binding(), next).await.unwrap();
	let id = common::id_of(&driver, "00000002");
	assert!(!driver.state.join("secrets/b1").join(&id).exists());
	assert!(!driver.secrets.join("b1").join(&id).exists());
}

#[tokio::test]
async fn a_failed_start_keeps_the_old_sealed_copy_for_a_retry() {
	let (driver, log) = driver("env-failed-start", shell(), false);
	let _cleanup = Cleanup(driver.state.clone());
	driver.deploy(&binding(), echo()).await.unwrap();
	let old = spec_of(&driver).id;
	let path = driver.state.join("secrets/b1").join(&old).join("TOKEN");
	let sealed = std::fs::read(&path).unwrap();
	let short: String = hash(ECHO_TWO).iter().map(|b| format!("{b:02x}")).take(6).collect();
	let new = format!("00000001-{short}");
	driver.containerd.unstartable.lock().unwrap().push(new.clone());
	let next = DeploymentDeploy { secrets: None, ..deploy("file:///echo-two.tar", ECHO_TWO) };
	assert!(driver.deploy(&binding(), next.clone()).await.is_err());
	assert!(std::fs::read(&path).unwrap() == sealed);
	assert!(!driver.state.join("secrets/b1").join(&new).exists());
	assert_eq!(driver.describe(&binding(), of()).await.unwrap().version, hash(common::ECHO));
	driver.containerd.unstartable.lock().unwrap().clear();
	driver.deploy(&binding(), next).await.unwrap();
	assert!(std::fs::read(driver.secrets.join("b1").join(new).join("TOKEN")).unwrap() == b"hidden");
	assert!(!path.exists());
	assert!(lines(&log).iter().all(|line| !line.contains("hidden")));
}
