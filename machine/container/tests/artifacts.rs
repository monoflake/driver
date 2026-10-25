//! `Containers` fetching an artifact, held to its bound and its hash, never kept once read, with
//! the fetch faked.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::sync::Arc;

use common::{
	ECHO, ECHO_TWO, Gate, Served, binding, deploy, driver, echo, hash, lines, reason, shell,
};
use driver_machine_container::{Deployments, Host};
use envelope::contracts::{DeploymentArtifact, DeploymentDeploy};

#[tokio::test]
async fn an_artifact_past_its_bound_is_too_large() {
	let (driver, log) = driver("large", shell(), false);
	let input = deploy("https://artifacts.invalid/large.tar", ECHO);
	assert_eq!(reason(driver.deploy(&binding(), input).await.unwrap_err()), "too_large");
	assert_eq!(lines(&log).len(), 1);
}

#[tokio::test]
async fn an_artifact_not_as_its_hash_says_is_refused_and_not_kept() {
	let (driver, log) = driver("mismatched", shell(), false);
	let input = DeploymentDeploy {
		artifact: DeploymentArtifact {
			address: "file:///echo.tar".into(),
			hash: hash(ECHO_TWO),
			architecture: None,
		},
		..echo()
	};
	assert_eq!(reason(driver.deploy(&binding(), input).await.unwrap_err()), "hash_mismatch");
	assert_eq!(lines(&log).len(), 1);
	assert_eq!(std::fs::read_dir(driver.state.join("artifacts")).unwrap().count(), 0);
}

#[tokio::test]
async fn an_artifact_nothing_serves_is_unfetchable() {
	let (driver, _) = driver("unfetchable", shell(), false);
	let refused =
		driver.deploy(&binding(), deploy("https://nothing.invalid/x.tar", ECHO)).await.unwrap_err();
	assert_eq!(refused.reason, "unfetchable");
	assert!(refused.message.unwrap().contains("nothing serves it"));
}

#[tokio::test]
async fn an_artifact_fetched_for_another_kind_is_held_to_its_hash_and_not_kept() {
	let (driver, _) = driver("fetched", shell(), false);
	let artifact = echo().artifact;
	assert_eq!(driver.fetch("b1", &artifact).await.unwrap(), ECHO);
	let mismatched = DeploymentArtifact { hash: hash(ECHO_TWO), ..artifact };
	assert_eq!(driver.fetch("b1", &mismatched).await.map_err(reason), Err("hash_mismatch"));
	assert_eq!(std::fs::read_dir(driver.state.join("artifacts")).unwrap().count(), 0);
}

#[tokio::test]
async fn two_fetches_of_one_artifact_at_once_each_read_what_they_checked() {
	let (mut driver, _) = driver("fetched-twice", shell(), false);
	let gate = Arc::new(Gate::default());
	driver.fetch.served.insert("file:///held.tar", Served::Held(ECHO, gate.clone()));
	let held = DeploymentArtifact { address: "file:///held.tar".into(), ..echo().artifact };
	// The second serves other bytes under the same hash, so it is refused and its file removed.
	let other = DeploymentArtifact { address: "file:///echo-two.tar".into(), ..echo().artifact };
	let second = async {
		gate.written.notified().await;
		let refused = driver.fetch("b1", &other).await.map_err(reason);
		gate.go.notify_one();
		refused
	};
	let (first, second) = tokio::join!(driver.fetch("b1", &held), second);
	assert_eq!(second, Err("hash_mismatch"));
	assert_eq!(first.unwrap(), ECHO);
	assert_eq!(std::fs::read_dir(driver.state.join("artifacts")).unwrap().count(), 0);
}
