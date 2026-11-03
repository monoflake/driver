//! `Containers` holding what fills a deployment's slots as part of what makes it the same one,
//! its bindings and the sockets it is given, RFC 49qyg.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::collections::BTreeMap;

use common::{Driver, Log, binding, driver, echo, lines, of, running, shell};
use driver_machine_container::{Deployments, Host, Hosted, Restart, Sockets};
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
fn hosted(driver: &Driver, sockets: Vec<Sockets>) -> Hosted {
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
	driver.host(&binding(), input.clone(), hosted(&driver, Vec::new())).await.unwrap();
	let sockets = vec![Sockets {
		directory: driver.state.join("slots/b1"),
		at: "/slots".into(),
		writable: false,
	}];
	driver.host(&binding(), input.clone(), hosted(&driver, sockets.clone())).await.unwrap();
	assert_eq!(created(&log), 2, "{:#?}", lines(&log));
	driver.host(&binding(), input, hosted(&driver, sockets)).await.unwrap();
	assert_eq!(created(&log), 2, "{:#?}", lines(&log));
	assert_eq!(ids(&driver).len(), 1);
}

#[tokio::test]
async fn writable_sockets_are_prepared_before_deploy_and_restart_and_read_only_ones_are_untouched()
{
	use std::os::unix::fs::{MetadataExt, PermissionsExt};
	let (mut driver, _) = driver("filling-writable-sockets", shell(), false);
	let owner = std::fs::metadata(&driver.state).unwrap();
	driver.containerd.config.user = Some(format!("{}:{}", owner.uid(), owner.gid()));
	let writable = driver.state.join("writable");
	let readonly = driver.state.join("readonly");
	for directory in [&writable, &readonly] {
		std::fs::create_dir_all(directory).unwrap();
		std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o755)).unwrap();
		std::fs::write(directory.join("stale.sock"), b"stale").unwrap();
		std::fs::write(directory.join("keep"), b"kept").unwrap();
	}
	let sockets = vec![
		Sockets { directory: writable.clone(), at: "/write".into(), writable: true },
		Sockets { directory: readonly.clone(), at: "/read".into(), writable: false },
	];
	let input = DeploymentDeploy { form: DeploymentForm::Modules, port: None, ..filled() };
	driver.host(&binding(), input, hosted(&driver, sockets)).await.unwrap();
	assert!(!writable.join("stale.sock").exists());
	std::fs::write(writable.join("again.sock"), b"stale").unwrap();
	std::fs::set_permissions(&writable, std::fs::Permissions::from_mode(0o777)).unwrap();
	for held in driver.containerd.held.lock().unwrap().values_mut() {
		held.task = None;
	}
	assert_eq!(driver.restarted(&binding()).await.unwrap().len(), 1);
	assert!(!writable.join("again.sock").exists());
	assert_eq!(std::fs::read(writable.join("keep")).unwrap(), b"kept");
	assert_eq!(std::fs::read(readonly.join("stale.sock")).unwrap(), b"stale");
	assert_eq!(std::fs::read(readonly.join("keep")).unwrap(), b"kept");
	let untouched = std::fs::metadata(&readonly).unwrap();
	assert_eq!((untouched.uid(), untouched.gid()), (owner.uid(), owner.gid()));
	assert_eq!(untouched.mode() & 0o7777, 0o755);
	common::cleared(&driver.state);
	assert!(
		std::process::Command::new("node")
			.args(["-e", "require('node:fs').rmSync(process.argv[1], {recursive:true, force:true})"])
			.arg(&driver.state)
			.status()
			.unwrap()
			.success()
	);
}
