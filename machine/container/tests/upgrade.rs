//! `Containers` over a container an earlier driver made, named `app-<id>-<hash>` and labeled
//! `app/<id>`, found by its app's id and never renamed, a scaffold retired with platform RFC 8yl4b.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use common::{
	Driver, ECHO, ECHO_TWO, binding, deploy, driver, echo, hash, id_of, lines, of, running, shell,
};
use driver_machine_container::{Containerd, Deployments, Reached, Restart, Task, reached};
use envelope::contracts::{DeploymentDeploy, DeploymentOf, DeploymentRuns, DeploymentState};

/// The name an earlier driver gave app 1's container of the echo image.
fn old_name() -> String {
	"app-1-".to_owned() + &hash(ECHO).iter().map(|b| format!("{b:02x}")).collect::<String>()[..12]
}

/// App 1 deployed, then its container, labels and state put back as an earlier driver left them,
/// as a machine holds them when the new driver first starts there.
async fn aged(driver: &Driver) -> String {
	driver.deploy(&binding(), echo()).await.unwrap();
	let new = id_of(driver, "00000001");
	let old = old_name();
	{
		let mut held = driver.containerd.held.lock().unwrap();
		let mut container = held.remove(&("b1".to_owned(), new.clone())).unwrap();
		container.labels.insert("driver.runs".into(), "app/1".into());
		container.labels.remove("driver.kind");
		container.spec.id.clone_from(&old);
		held.insert(("b1".to_owned(), old.clone()), container);
	}
	let renamed = |directory: &std::path::Path, from: &str, to: &str| {
		let from = directory.join(from);
		if from.exists() {
			std::fs::rename(&from, directory.join(to)).unwrap();
		}
	};
	for kept in ["started", "stopped", "secrets", "files", "hosts"] {
		renamed(&driver.state.join(kept).join("b1"), &new, &old);
	}
	renamed(&driver.state.join("output/b1"), &format!("{new}.log"), &format!("{old}.log"));
	renamed(&driver.secrets.join("b1"), &new, &old);
	let mut networks = driver.network.held.lock().unwrap();
	let address = networks.remove(&format!("b1-{new}")).unwrap();
	networks.insert(format!("b1-{old}"), address);
	old
}

fn ids(driver: &Driver) -> Vec<String> {
	driver.containerd.held.lock().unwrap().keys().map(|k| k.1.clone()).collect()
}

/// Whether anything of a container is left in the driver's state, its marks, secrets or output.
fn kept(driver: &Driver, id: &str) -> Vec<String> {
	let places = [
		driver.state.join("started/b1").join(id),
		driver.state.join("stopped/b1").join(id),
		driver.state.join("secrets/b1").join(id),
		driver.secrets.join("b1").join(id),
	];
	let mut left: Vec<String> =
		places.iter().filter(|p| p.exists()).map(|p| p.display().to_string()).collect();
	if driver.network.held.lock().unwrap().contains_key(&format!("b1-{id}")) {
		left.push(format!("network b1-{id}"));
	}
	left
}

#[tokio::test]
async fn an_old_container_is_found_by_its_apps_id_and_a_restart_leaves_it_running() {
	let (driver, log) = driver("upgrade-found", shell(), false);
	let old = aged(&driver).await;
	assert!(!kept(&driver, &old).is_empty(), "its state is under its old name");
	log.lock().unwrap().clear();
	// The new driver's start finds its task running and touches nothing.
	assert_eq!(driver.restarted(&binding()).await.unwrap(), Vec::<String>::new());
	assert!(lines(&log).is_empty(), "{:#?}", lines(&log));
	let described = driver.describe(&binding(), of()).await.unwrap();
	assert_eq!(described.version, hash(ECHO));
	assert_eq!(described.state, running("10.88.0.2:8080"));
	let listed = driver.containerd.list("b1").await.unwrap();
	assert_eq!(
		reached(&listed, &DeploymentRuns::App { id: 1 }),
		Reached::Running("10.88.0.2:8080".into())
	);
	// The same version deployed again is the old container's answer, nothing made.
	assert_eq!(driver.deploy(&binding(), echo()).await.unwrap(), described);
	assert_eq!(ids(&driver), std::slice::from_ref(&old));
	assert!(!lines(&log).iter().any(|l| l.starts_with("create ")), "{:#?}", lines(&log));
}

#[tokio::test]
async fn an_old_container_lost_to_a_reboot_starts_again_under_its_old_name() {
	let (driver, log) = driver("upgrade-rebooted", shell(), false);
	let old = aged(&driver).await;
	driver.containerd.held.lock().unwrap().values_mut().for_each(|h| h.task = None);
	log.lock().unwrap().clear();
	assert_eq!(driver.restarted(&binding()).await.unwrap(), std::slice::from_ref(&old));
	let log = lines(&log);
	assert!(log.contains(&format!("attach b1-{old} 8080")), "{log:#?}");
	assert!(log.contains(&format!("start {old}")), "{log:#?}");
	// Its secrets were found sealed under its old name and written open again.
	assert!(driver.secrets.join("b1").join(&old).join("TOKEN").exists());
	assert_eq!(driver.describe(&binding(), of()).await.unwrap().state, running("10.88.0.2:8080"));
}

#[tokio::test]
async fn an_old_container_is_replaced_by_one_named_anew_and_its_state_goes_with_it() {
	let (driver, log) = driver("upgrade-replaced", shell(), false);
	let old = aged(&driver).await;
	let two = DeploymentDeploy { runs: DeploymentRuns::App { id: 2 }, ..echo() };
	driver.deploy(&binding(), two).await.unwrap();
	let short =
		|bytes| hash(bytes).iter().map(|b| format!("{b:02x}")).collect::<String>()[..12].to_owned();
	assert_eq!(ids(&driver), [format!("00000002-{}", short(ECHO)), old.clone()]);
	let replaced = driver.deploy(&binding(), deploy("file:///echo-two.tar", ECHO_TWO)).await.unwrap();
	assert_eq!(replaced.version, hash(ECHO_TWO));
	let new = format!("00000001-{}", short(ECHO_TWO));
	assert_eq!(ids(&driver), [new, format!("00000002-{}", short(ECHO))]);
	let log = lines(&log);
	assert!(log.contains(&format!("remove {old}")), "{log:#?}");
	assert!(log.contains(&format!("detach b1-{old}")), "{log:#?}");
	assert_eq!(kept(&driver, &old), Vec::<String>::new());
}

#[tokio::test]
async fn an_old_container_is_stopped_and_deleted_by_its_apps_id_and_the_new_one_beside_it_stays() {
	let (driver, _) = driver("upgrade-deleted", shell(), false);
	let old = aged(&driver).await;
	let two = DeploymentRuns::App { id: 2 };
	driver.deploy(&binding(), DeploymentDeploy { runs: two.clone(), ..echo() }).await.unwrap();
	assert_eq!(driver.stop(&binding(), of()).await.unwrap().state, DeploymentState::Stopped);
	assert!(driver.state.join("stopped/b1").join(&old).exists());
	driver.delete(&binding(), of()).await.unwrap();
	assert_eq!(kept(&driver, &old), Vec::<String>::new());
	let left = ids(&driver);
	assert!(matches!(&left[..], [id] if id.starts_with("00000002-")), "{left:?}");
	let described = driver.describe(&binding(), DeploymentOf { runs: two }).await.unwrap();
	assert_eq!(described.state, running("10.88.0.3:8080"));
	assert_eq!(
		driver.containerd.held.lock().unwrap().values().next().unwrap().task,
		Some(Task::Running)
	);
}
