//! `Containers` over a binding named before hex ids, `b1`, beside one named in hex, `b0a1b2c3d`,
//! each container, network, state and handed name kept under the namespace it is given.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::collections::BTreeMap;

use common::{Driver, ECHO, ECHO_TWO, deploy, driver, echo, hash, lines, of, running, shell};
use driver_machine_container::{Binding, Capacity, Deployments, Restart, Task};
use envelope::contracts::{DeploymentDeploy, DeploymentRuns, DeploymentState};

/// A binding by its namespace and qgroup, its container of capacity 3 as `deploy` asks.
fn bound(namespace: &str, qgroup: &str) -> Binding {
	Binding {
		namespace: namespace.into(),
		qgroup: qgroup.into(),
		capacities: BTreeMap::from([(3, Capacity { millicores: 500, memory: 268_435_456 })]),
	}
}

/// Binding 1, made before hex ids, as the driver names it from its kept list.
fn old() -> Binding {
	bound("b1", "1/1")
}

/// Binding 0a1b2c3d, made now.
fn new() -> Binding {
	bound("b0a1b2c3d", "1/169552957")
}

/// The ids of the containers of a namespace.
fn ids(driver: &Driver, namespace: &str) -> Vec<String> {
	let held = driver.containerd.held.lock().unwrap();
	held.keys().filter(|(n, _)| n == namespace).map(|(_, id)| id.clone()).collect()
}

/// Each network attached, by its name.
fn networks(driver: &Driver) -> Vec<String> {
	driver.network.held.lock().unwrap().keys().cloned().collect()
}

/// What is kept of a container in the driver's state, under its namespace.
fn kept(driver: &Driver, namespace: &str, id: &str) -> Vec<String> {
	let places = [
		driver.state.join("started").join(namespace).join(id),
		driver.state.join("stopped").join(namespace).join(id),
		driver.state.join("secrets").join(namespace).join(id),
		driver.secrets.join(namespace).join(id),
	];
	places.iter().filter(|p| p.exists()).map(|p| p.display().to_string()).collect()
}

/// The version's first 12 hex digits, as a container's id holds them.
fn short(bytes: &[u8]) -> String {
	hash(bytes).iter().map(|b| format!("{b:02x}")).collect::<String>()[..12].to_owned()
}

#[tokio::test]
async fn each_binding_keeps_its_containers_networks_state_and_qgroup_under_its_own_name() {
	let (driver, log) = driver("bindings-apart", shell(), false);
	driver.deploy(&old(), echo()).await.unwrap();
	driver.deploy(&new(), echo()).await.unwrap();
	let id = format!("00000001-{}", short(ECHO));
	assert_eq!(ids(&driver, "b1"), std::slice::from_ref(&id));
	assert_eq!(ids(&driver, "b0a1b2c3d"), std::slice::from_ref(&id));
	assert_eq!(networks(&driver), [format!("b0a1b2c3d-{id}"), format!("b1-{id}")]);
	assert_eq!(kept(&driver, "b1", &id).len(), 3, "{:?}", kept(&driver, "b1", &id));
	assert_eq!(kept(&driver, "b0a1b2c3d", &id).len(), 3);
	let log = lines(&log);
	for qgroup in ["1/1", "1/169552957"] {
		assert!(log.iter().any(|l| l.starts_with("assign ") && l.ends_with(qgroup)), "{log:#?}");
	}
}

#[tokio::test]
async fn a_binding_named_before_restarts_redeploys_and_deletes_by_id_beside_one_in_hex() {
	let (driver, log) = driver("bindings-upgraded", shell(), false);
	driver.deploy(&old(), echo()).await.unwrap();
	driver.deploy(&new(), echo()).await.unwrap();
	let id = format!("00000001-{}", short(ECHO));
	// A reboot ends every task, and the driver's start finds each under its own namespace.
	driver.containerd.held.lock().unwrap().values_mut().for_each(|h| h.task = None);
	log.lock().unwrap().clear();
	assert_eq!(driver.restarted(&old()).await.unwrap(), std::slice::from_ref(&id));
	assert!(lines(&log).contains(&format!("attach b1-{id} 8080")), "{:#?}", lines(&log));
	assert_eq!(driver.describe(&old(), of()).await.unwrap().state, running("10.88.0.2:8080"));
	assert_eq!(driver.restarted(&new()).await.unwrap(), std::slice::from_ref(&id));
	assert_eq!(driver.describe(&new(), of()).await.unwrap().state, running("10.88.0.3:8080"));
	// A new version replaces binding 1's alone, still under its decimal name.
	let replaced = driver.deploy(&old(), deploy("file:///echo-two.tar", ECHO_TWO)).await.unwrap();
	assert_eq!(replaced.version, hash(ECHO_TWO));
	let two = format!("00000001-{}", short(ECHO_TWO));
	assert_eq!(ids(&driver, "b1"), std::slice::from_ref(&two));
	assert_eq!(networks(&driver), [format!("b0a1b2c3d-{id}"), format!("b1-{two}")]);
	assert_eq!(kept(&driver, "b1", &id), Vec::<String>::new());
	// Stopped and deleted by its id, binding 1 holds nothing and the other is still running.
	assert_eq!(driver.stop(&old(), of()).await.unwrap().state, DeploymentState::Stopped);
	driver.delete(&old(), of()).await.unwrap();
	assert_eq!(ids(&driver, "b1"), Vec::<String>::new());
	assert_eq!(kept(&driver, "b1", &two), Vec::<String>::new());
	assert_eq!(networks(&driver), [format!("b0a1b2c3d-{id}")]);
	let held = driver.containerd.held.lock().unwrap();
	assert_eq!(held[&("b0a1b2c3d".to_owned(), id.clone())].task, Some(Task::Running));
}

#[tokio::test]
async fn a_deployment_is_handed_what_it_reaches_by_its_bindings_own_name() {
	let (driver, _) = driver("bindings-handed", shell(), false);
	let target = DeploymentRuns::App { id: 2 };
	let reacher = DeploymentDeploy { reaching: Some(vec![target.clone()]), ..echo() };
	for binding in [old(), new()] {
		driver.deploy(&binding, DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
		driver.deploy(&binding, reacher.clone()).await.unwrap();
	}
	let held = driver.containerd.held.lock().unwrap();
	let handed = |namespace: &str| -> Vec<String> {
		let mine =
			held.iter().find(|((n, _), h)| n == namespace && h.labels["driver.runs"] == "00000001");
		let env = mine.unwrap().1.spec.runtime_spec["process"]["env"].as_array().unwrap().clone();
		env
			.iter()
			.filter_map(|e| e.as_str()?.strip_prefix("MONOFLAKE_REACHING=").map(str::to_owned))
			.collect()
	};
	assert_eq!(handed("b1"), [r#"{"00000002":"http://00000002.b1:4321"}"#]);
	assert_eq!(handed("b0a1b2c3d"), [r#"{"00000002":"http://00000002.b0a1b2c3d:4321"}"#]);
}
