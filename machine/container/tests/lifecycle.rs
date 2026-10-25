//! `Containers` stopping, resuming, describing, emptying, deleting and restarting what it deployed,
//! and whether its address accepts a connection.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use common::{Driver, app, binding, driver, echo, id_of, lines, of, reason, running, shell};
use driver_machine_container::{
	Binding, Capacity, Containerd, Deployments, Reached, Restart, Task, Unmake, reached,
};
use envelope::contracts::{DeploymentDeploy, DeploymentOf, DeploymentRuns, DeploymentState};

#[tokio::test]
async fn what_was_never_deployed_is_not_found_and_deleting_it_succeeds() {
	let (driver, log) = driver("never", shell(), false);
	assert_eq!(reason(driver.describe(&binding(), of()).await.unwrap_err()), "not_found");
	assert_eq!(reason(driver.stop(&binding(), of()).await.unwrap_err()), "not_found");
	assert_eq!(reason(driver.resume(&binding(), of()).await.unwrap_err()), "not_found");
	driver.delete(&binding(), of()).await.unwrap();
	assert!(lines(&log).is_empty());
}

#[tokio::test]
async fn another_binding_sees_none_of_it() {
	let (driver, _) = driver("apart", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let other = Binding { namespace: "b2".into(), ..binding() };
	assert_eq!(reason(driver.describe(&other, of()).await.unwrap_err()), "not_found");
}

#[tokio::test]
async fn a_deployment_stopped_is_stopped_and_resumed_runs_again() {
	let (driver, log) = driver("lifecycle", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let stopped = driver.stop(&binding(), of()).await.unwrap();
	assert_eq!(stopped.state, DeploymentState::Stopped);
	assert_eq!(driver.describe(&binding(), of()).await.unwrap().state, DeploymentState::Stopped);
	let resumed = driver.resume(&binding(), of()).await.unwrap();
	assert_eq!(resumed.state, running("10.88.0.2:8080"));
	let log = lines(&log);
	assert_eq!(
		log.iter().filter(|l| l.starts_with("attach ")).count(),
		2,
		"resuming makes its network where it is gone"
	);
	assert_eq!(log.iter().filter(|l| l.starts_with("start ")).count(), 2);
}

fn refusing(driver: &Driver, times: u32) {
	*driver.network.refusing.lock().unwrap() = times;
}

fn probes(driver: &Driver) -> usize {
	*driver.network.probed.lock().unwrap()
}

#[tokio::test]
async fn a_deployment_is_running_only_once_its_address_accepts_a_connection() {
	let (driver, _) = driver("waited", shell(), false);
	refusing(&driver, 4);
	let deployed = driver.deploy(&binding(), echo()).await.unwrap();
	assert_eq!(deployed.state, running("10.88.0.2:8080"));
	assert!(probes(&driver) >= 4, "the deploy waited for its address");
	// Refused again, as its server restarting, it is making until it answers.
	refusing(&driver, u32::MAX);
	assert_eq!(driver.describe(&binding(), of()).await.unwrap().state, DeploymentState::Making);
	refusing(&driver, 0);
	assert_eq!(driver.describe(&binding(), of()).await.unwrap().state, running("10.88.0.2:8080"));
}

#[tokio::test]
async fn a_deployment_resumed_is_running_only_once_its_address_accepts_a_connection() {
	let (driver, _) = driver("resumed-reached", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	driver.stop(&binding(), of()).await.unwrap();
	refusing(&driver, 3);
	let before = probes(&driver);
	assert_eq!(driver.resume(&binding(), of()).await.unwrap().state, running("10.88.0.2:8080"));
	assert!(probes(&driver) - before >= 3, "the resume waited for its address");
}

#[tokio::test]
async fn a_deployment_its_address_never_accepts_is_failed_once_its_start_is_long_past() {
	let (driver, _) = driver("unreachable", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let id = driver.containerd.held.lock().unwrap().keys().next().unwrap().1.clone();
	std::fs::write(driver.state.join("started/b1").join(&id), "0").unwrap();
	refusing(&driver, u32::MAX);
	let state = driver.describe(&binding(), of()).await.unwrap().state;
	let DeploymentState::Failed { reason, message } = state else { panic!("{state:?}") };
	assert_eq!(reason, "unreachable");
	assert!(message.unwrap().starts_with("10.88.0.2:8080 accepted no connection within 30 s"));
}

#[tokio::test]
async fn the_labels_alone_say_where_a_deployment_runs_as_the_entry_reads_them() {
	let (driver, _) = driver("reached", shell(), false);
	let listed = async || driver.containerd.list("b1").await.unwrap();
	assert_eq!(reached(&listed().await, &app()), Reached::Absent);
	driver.deploy(&binding(), echo()).await.unwrap();
	assert_eq!(reached(&listed().await, &app()), Reached::Running("10.88.0.2:8080".into()));
	assert_eq!(reached(&listed().await, &DeploymentRuns::App { id: 2 }), Reached::Absent);
	driver.stop(&binding(), of()).await.unwrap();
	assert_eq!(reached(&listed().await, &app()), Reached::Down);
}

#[tokio::test]
async fn a_container_item_emptied_takes_what_runs_in_it_and_nothing_else() {
	let (driver, log) = driver("emptied", shell(), false);
	let mut two = binding();
	two.capacities.insert(4, Capacity { millicores: 250, memory: 268_435_456 });
	driver.deploy(&two, echo()).await.unwrap();
	let other = DeploymentDeploy { runs: DeploymentRuns::App { id: 2 }, into: Some(4), ..echo() };
	driver.deploy(&two, other).await.unwrap();
	let into: Vec<String> = {
		let held = driver.containerd.held.lock().unwrap();
		held.values().map(|h| h.labels["driver.into"].clone()).collect()
	};
	assert_eq!(into, ["3", "4"], "each container is labelled with the capacity it runs in");
	assert_eq!(driver.emptied(&two, 5).await.unwrap(), Vec::<String>::new());
	let removed = driver.emptied(&two, 3).await.unwrap();
	assert!(matches!(&removed[..], [id] if id.starts_with("00000001-")), "{removed:?}");
	assert_eq!(reason(driver.describe(&two, of()).await.unwrap_err()), "not_found");
	let still = DeploymentOf { runs: DeploymentRuns::App { id: 2 } };
	assert_eq!(driver.describe(&two, still).await.unwrap().state, running("10.88.0.3:8080"));
	let log = lines(&log);
	assert!(log.iter().any(|l| l.starts_with("stop 00000001-")), "{log:#?}");
	assert!(log.iter().any(|l| l.starts_with("detach b1-00000001-")), "{log:#?}");
	assert!(!log.iter().any(|l| l.starts_with("detach b1-00000002-")), "{log:#?}");
}

#[tokio::test]
async fn a_deployment_is_deleted_only_once_stopped_and_is_then_not_found() {
	let (driver, log) = driver("deleted", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	assert_eq!(reason(driver.delete(&binding(), of()).await.unwrap_err()), "still_running");
	driver.stop(&binding(), of()).await.unwrap();
	driver.delete(&binding(), of()).await.unwrap();
	assert_eq!(reason(driver.describe(&binding(), of()).await.unwrap_err()), "not_found");
	assert!(lines(&log).iter().any(|l| l.starts_with("detach b1-00000001-")));
	// Its secrets, both copies, and its stop's mark go with it.
	assert_eq!(std::fs::read_dir(driver.secrets.join("b1")).unwrap().count(), 0);
	assert_eq!(std::fs::read_dir(driver.state.join("secrets/b1")).unwrap().count(), 0);
	assert_eq!(std::fs::read_dir(driver.state.join("stopped/b1")).unwrap().count(), 0);
}

#[tokio::test]
async fn a_container_ended_unasked_has_failed_and_one_made_is_making() {
	let (driver, _) = driver("exited", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let exited = |message: &str| DeploymentState::Failed {
		reason: "exited".into(),
		message: Some(message.into()),
	};
	for (task, state) in [
		(Some(Task::Stopped(1)), exited("exit status 1")),
		(None, exited("its task is gone")),
		(Some(Task::Created), DeploymentState::Making),
		(Some(Task::Other), DeploymentState::Making),
	] {
		driver.containerd.held.lock().unwrap().values_mut().for_each(|h| h.task = task);
		assert_eq!(driver.describe(&binding(), of()).await.unwrap().state, state);
	}
}

#[tokio::test]
async fn a_restart_goes_on_past_a_failure_and_names_each() {
	let (driver, _) = driver("restarted", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let other = DeploymentDeploy { runs: DeploymentRuns::App { id: 2 }, ..echo() };
	driver.deploy(&binding(), other).await.unwrap();
	let (one, two) = (id_of(&driver, "00000001"), id_of(&driver, "00000002"));
	// As a reboot ends every task.
	for held in driver.containerd.held.lock().unwrap().values_mut() {
		held.task = None;
	}
	driver.containerd.unstartable.lock().unwrap().push(one.clone());
	let refused = driver.restarted(&binding()).await.unwrap_err();
	assert_eq!(refused.reason, "fault");
	let message = refused.message.unwrap();
	assert!(message.contains(&format!("{two} started")), "{message}");
	assert!(message.contains(&format!("{one} not started, {one} does not start")), "{message}");
	let held = driver.containerd.held.lock().unwrap();
	assert_eq!(held[&("b1".to_owned(), two)].task, Some(Task::Running));
}
