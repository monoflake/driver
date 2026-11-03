//! `Containers` holding what fills a deployment's slots as part of what makes it the same one,
//! its bindings and the sockets it is given, RFC 49qyg.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::collections::BTreeMap;
use std::path::PathBuf;

use common::{Driver, Log, binding, driver, echo, lines, of, running, shell};
use driver_machine_container::{Deployments, Host, Hosted};
use envelope::contracts::{
	AppBindings, DeploymentDeploy, DeploymentForm, DeploymentIsolation, DeploymentRuntime,
};

/// The echo image with its `database` slot filled by database 7.
fn filled() -> DeploymentDeploy {
	let bindings = AppBindings {
		app: None,
		database: Some(BTreeMap::from([("database".into(), 7)])),
		bucket: None,
	};
	DeploymentDeploy { bindings: Some(bindings), ..echo() }
}

fn ids(driver: &Driver) -> Vec<String> {
	driver.containerd.held.lock().unwrap().keys().map(|k| k.1.clone()).collect()
}

/// Whether the one container held is labeled with what fills its slots.
fn labeled(driver: &Driver) -> bool {
	let held = driver.containerd.held.lock().unwrap();
	held.values().next().unwrap().labels.contains_key("driver.fill")
}

fn created(log: &Log) -> usize {
	lines(log).iter().filter(|l| l.starts_with("create ")).count()
}

#[tokio::test]
async fn a_version_deployed_again_with_its_slot_filled_is_made_anew_in_place_of_the_first() {
	let (driver, log) = driver("filling-replaced", shell(), false);
	let first = driver.deploy(&binding(), echo()).await.unwrap();
	let unfilled = ids(&driver);
	let second = driver.deploy(&binding(), filled()).await.unwrap();
	assert_eq!(created(&log), 2, "{:#?}", lines(&log));
	assert_eq!(second.version, first.version);
	assert_eq!(second.state, running("10.88.0.3:8080"));
	let now = ids(&driver);
	assert_eq!(now.len(), 1, "{now:?}");
	assert_ne!(now, unfilled);
	assert!(lines(&log).contains(&format!("remove {}", unfilled[0])), "{:#?}", lines(&log));
	assert!(labeled(&driver));
	assert_eq!(driver.describe(&binding(), of()).await.unwrap(), second);
}

#[tokio::test]
async fn the_same_version_and_fill_deployed_twice_is_answered_as_one() {
	let (driver, log) = driver("filling-same", shell(), false);
	let first = driver.deploy(&binding(), filled()).await.unwrap();
	let made = ids(&driver);
	assert_eq!(driver.deploy(&binding(), filled()).await.unwrap(), first);
	assert_eq!(ids(&driver), made);
	assert_eq!(created(&log), 1, "{:#?}", lines(&log));
	// Filled by another id, it is made anew.
	let other = AppBindings {
		app: None,
		database: Some(BTreeMap::from([("database".into(), 8)])),
		bucket: None,
	};
	driver.deploy(&binding(), DeploymentDeploy { bindings: Some(other), ..echo() }).await.unwrap();
	assert_eq!(created(&log), 2, "{:#?}", lines(&log));
	assert_eq!(ids(&driver).len(), 1);
}

#[tokio::test]
async fn bindings_filling_nothing_are_the_same_as_none_and_write_no_label() {
	let (driver, log) = driver("filling-empty", shell(), false);
	let first = driver.deploy(&binding(), echo()).await.unwrap();
	let made = ids(&driver);
	let empty = AppBindings { app: Some(BTreeMap::new()), database: None, bucket: None };
	let again =
		driver.deploy(&binding(), DeploymentDeploy { bindings: Some(empty), ..echo() }).await.unwrap();
	assert_eq!(again, first);
	assert_eq!(ids(&driver), made);
	assert_eq!(created(&log), 1, "{:#?}", lines(&log));
	assert!(!labeled(&driver));
}

/// A runtime of the machine's own, as the function kind hosts workerd, given sockets or none.
fn hosted(driver: &Driver, sockets: Option<(PathBuf, String)>) -> Hosted {
	let image = driver.state.join("workerd.tar");
	std::fs::write(&image, b"workerd image").unwrap();
	Hosted {
		image,
		cmd: vec!["serve".into()],
		port: 8080,
		files: BTreeMap::from([("config.capnp".into(), b"config".to_vec())]),
		at: "/worker".into(),
		runtime: DeploymentRuntime::Workerd,
		isolation: vec![DeploymentIsolation::Isolate, DeploymentIsolation::Kernel],
		sockets,
	}
}

#[tokio::test]
async fn a_hosted_runtime_given_sockets_it_was_not_given_before_is_made_anew() {
	let (driver, log) = driver("filling-sockets", shell(), false);
	let input = DeploymentDeploy { form: DeploymentForm::Modules, port: None, ..filled() };
	driver.host(&binding(), input.clone(), hosted(&driver, None)).await.unwrap();
	let sockets = Some((driver.state.join("slots/b1"), "/slots".to_owned()));
	driver.host(&binding(), input.clone(), hosted(&driver, sockets.clone())).await.unwrap();
	assert_eq!(created(&log), 2, "{:#?}", lines(&log));
	driver.host(&binding(), input, hosted(&driver, sockets)).await.unwrap();
	assert_eq!(created(&log), 2, "{:#?}", lines(&log));
	assert_eq!(ids(&driver).len(), 1);
}
