//! `Containers` letting a deployment reach another on its binding, by its name at the entry, the
//! fence holding the reacher alone.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::net::SocketAddr;

use common::{Driver, ECHO_TWO, binding, deploy, driver, echo, id_of, lines, of, reason, shell};
use driver_machine_container::{Binding, Deployments, Task};
use envelope::contracts::{DeploymentDeploy, DeploymentOf, DeploymentRuns};
use serde_json::Value;

#[tokio::test]
async fn a_deployment_reaches_only_what_is_deployed_on_its_binding() {
	let (driver, _) = driver("reaching", shell(), false);
	let target = DeploymentRuns::Component { component: "stand-in".into(), id: 9 };
	let reaching = |runs: DeploymentRuns| DeploymentDeploy { reaching: Some(vec![runs]), ..echo() };
	// Not deployed yet, so not reached.
	let refused = driver.deploy(&binding(), reaching(target.clone())).await;
	assert_eq!(refused.map_err(reason), Err("invalid"));
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	// Deployed on another binding is not on this one.
	let other = Binding { namespace: "b2".into(), ..binding() };
	assert_eq!(driver.deploy(&other, reaching(target.clone())).await.map_err(reason), Err("invalid"));
	driver.deploy(&binding(), reaching(target)).await.unwrap();
}

/// The networks whose reacher's element is written, each by its name.
fn fenced(driver: &Driver) -> Vec<String> {
	driver.network.fences.lock().unwrap().keys().cloned().collect()
}

/// The environment of the container running a deployment of the label given.
fn env_of(driver: &Driver, runs: &str) -> Vec<Value> {
	let held = driver.containerd.held.lock().unwrap();
	let mine =
		held.values().find(|h| h.labels["driver.runs"] == runs && h.task == Some(Task::Running));
	mine.unwrap().spec.runtime_spec["process"]["env"].as_array().unwrap().clone()
}

fn reaching(runs: DeploymentRuns) -> DeploymentDeploy {
	DeploymentDeploy { reaching: Some(vec![runs]), ..echo() }
}

#[tokio::test]
async fn a_reacher_is_told_each_target_by_its_name_at_the_entry() {
	let (driver, _) = driver("reacher-told", shell(), false);
	let target = DeploymentRuns::Component { component: "stand-in".into(), id: 0x1a2b_3c4d };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.deploy(&binding(), reaching(target)).await.unwrap();
	let origins = r#"MONOFLAKE_REACHING={"1a2b3c4d":"http://component-1a2b3c4d.b1:4321"}"#;
	assert!(env_of(&driver, "app/1").contains(&origins.into()));
}

/// The spec of the container running a deployment of the label given.
fn spec_running(driver: &Driver, runs: &str) -> Value {
	let held = driver.containerd.held.lock().unwrap();
	let mine =
		held.values().find(|h| h.labels["driver.runs"] == runs && h.task == Some(Task::Running));
	mine.unwrap().spec.runtime_spec.clone()
}

/// What a container's spec binds at `/etc/hosts`, read, none where it binds nothing there.
fn hosts_of(spec: &Value) -> Option<String> {
	let mounts = spec["mounts"].as_array().unwrap();
	let bound = mounts.iter().find(|m| m["destination"] == "/etc/hosts")?;
	assert_eq!(bound["options"], serde_json::json!(["rbind", "ro", "nosuid", "nodev", "noexec"]));
	Some(std::fs::read_to_string(bound["source"].as_str().unwrap()).unwrap())
}

#[tokio::test]
async fn a_reacher_resolves_the_names_it_reaches_alone_to_the_host() {
	let (driver, _) = driver("hosts", shell(), false);
	// The image's own is never read, so what it holds is not carried.
	std::fs::write(driver.containerd.rootfs.join("etc/hosts"), "192.0.2.200\timage.example\n")
		.unwrap();
	let target = DeploymentRuns::Component { component: "stand-in".into(), id: 0x1a2b_3c4d };
	let other = DeploymentRuns::App { id: 2 };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.deploy(&binding(), DeploymentDeploy { runs: other, ..echo() }).await.unwrap();
	driver.deploy(&binding(), reaching(target)).await.unwrap();
	let hosts = hosts_of(&spec_running(&driver, "app/1")).unwrap();
	assert_eq!(hosts, "127.0.0.1\tlocalhost\n::1\tlocalhost\n10.88.0.1\tcomponent-1a2b3c4d.b1\n");
	// Reaching nothing, it is given nothing, and keeps the image's own.
	assert_eq!(hosts_of(&spec_running(&driver, "app/2")), None);
	assert_eq!(hosts_of(&spec_running(&driver, "component/1a2b3c4d")), None);
}

#[tokio::test]
async fn a_reacher_alone_is_let_reach_the_entry_and_its_element_goes_with_it() {
	let (driver, log) = driver("elements", shell(), false);
	let target = DeploymentRuns::App { id: 9 };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	assert!(fenced(&driver).is_empty(), "nothing for a deployment reaching nothing");
	driver.deploy(&binding(), reaching(target)).await.unwrap();
	let reacher = format!("b1-{}", id_of(&driver, "app/1"));
	assert_eq!(fenced(&driver), std::slice::from_ref(&reacher));
	// The entry the attachment answered.
	let entry: SocketAddr = "10.88.0.1:4321".parse().unwrap();
	assert_eq!(driver.network.fences.lock().unwrap()[&reacher], [entry]);
	driver.stop(&binding(), of()).await.unwrap();
	driver.delete(&binding(), of()).await.unwrap();
	assert!(fenced(&driver).is_empty());
	let log = lines(&log);
	let unfenced = log.iter().position(|l| *l == format!("fence {reacher} []")).unwrap();
	let detached = log.iter().position(|l| *l == format!("detach {reacher}")).unwrap();
	assert!(unfenced < detached, "its element goes before its address is given back");
}

#[tokio::test]
async fn a_reacher_resumed_is_let_reach_the_entry_again() {
	let (driver, _) = driver("resumed-fence", shell(), false);
	let target = DeploymentRuns::App { id: 9 };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.deploy(&binding(), reaching(target)).await.unwrap();
	driver.stop(&binding(), of()).await.unwrap();
	// As a boot empties the set.
	driver.network.fences.lock().unwrap().clear();
	driver.resume(&binding(), of()).await.unwrap();
	assert_eq!(fenced(&driver), [format!("b1-{}", id_of(&driver, "app/1"))]);
}

#[tokio::test]
async fn a_target_stopped_is_still_reached_and_one_never_deployed_is_invalid() {
	let (driver, _) = driver("stopped-target", shell(), false);
	let target = DeploymentRuns::App { id: 9 };
	assert_eq!(
		driver.deploy(&binding(), reaching(target.clone())).await.map_err(reason),
		Err("invalid")
	);
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.stop(&binding(), DeploymentOf { runs: target.clone() }).await.unwrap();
	driver.deploy(&binding(), reaching(target)).await.unwrap();
}

#[tokio::test]
async fn a_reacher_is_replaced_with_no_gap_and_each_container_has_its_element() {
	let (driver, log) = driver("no-gap", shell(), false);
	let target = DeploymentRuns::App { id: 9 };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.deploy(&binding(), reaching(target.clone())).await.unwrap();
	let old = id_of(&driver, "app/1");
	let two =
		DeploymentDeploy { reaching: Some(vec![target]), ..deploy("file:///echo-two.tar", ECHO_TWO) };
	driver.deploy(&binding(), two).await.unwrap();
	let new = id_of(&driver, "app/1");
	let log = lines(&log);
	let start_two = log.iter().position(|l| *l == format!("start {new}")).unwrap();
	let stop_one = log.iter().position(|l| l.starts_with(&format!("stop {old} "))).unwrap();
	assert!(start_two < stop_one, "{log:#?}");
	assert_eq!(fenced(&driver), [format!("b1-{new}")]);
}

#[tokio::test]
async fn reaching_nothing_again_takes_effect_at_the_same_version() {
	let (driver, _) = driver("unreached", shell(), false);
	let target = DeploymentRuns::App { id: 9 };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.deploy(&binding(), reaching(target)).await.unwrap();
	driver.deploy(&binding(), echo()).await.unwrap();
	let env = env_of(&driver, "app/1");
	assert!(!env.iter().any(|e| e.as_str().unwrap().starts_with("MONOFLAKE_REACHING=")), "{env:?}");
	assert!(fenced(&driver).is_empty());
}

#[tokio::test]
async fn a_reacher_removed_while_nft_fails_still_gives_everything_back() {
	let (driver, log) = driver("unfenced", shell(), false);
	let target = DeploymentRuns::App { id: 9 };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.deploy(&binding(), reaching(target)).await.unwrap();
	let reacher = id_of(&driver, "app/1");
	driver.stop(&binding(), of()).await.unwrap();
	*driver.network.unfenceable.lock().unwrap() = true;
	let refused = driver.delete(&binding(), of()).await.unwrap_err();
	assert_eq!(refused.message.as_deref(), Some("nft delete element: refused"));
	// Its network, its decrypted secrets and its hosts go all the same.
	assert!(lines(&log).contains(&format!("detach b1-{reacher}")));
	assert!(!driver.secrets.join("b1").join(&reacher).exists());
	assert!(!driver.state.join("hosts/b1").join(&reacher).exists());
	assert!(driver.containerd.held.lock().unwrap().keys().all(|k| k.1 != reacher));
}

#[tokio::test]
async fn a_reacher_resumed_is_let_reach_the_entry_it_was_made_with() {
	let (driver, _) = driver("resumed-entry", shell(), false);
	let target = DeploymentRuns::App { id: 9 };
	driver.deploy(&binding(), DeploymentDeploy { runs: target.clone(), ..echo() }).await.unwrap();
	driver.deploy(&binding(), reaching(target)).await.unwrap();
	driver.stop(&binding(), of()).await.unwrap();
	driver.network.fences.lock().unwrap().clear();
	// The driver started again with another entry.
	*driver.network.entry.lock().unwrap() = 4999;
	driver.resume(&binding(), of()).await.unwrap();
	let reacher = format!("b1-{}", id_of(&driver, "app/1"));
	let made: SocketAddr = "10.88.0.1:4321".parse().unwrap();
	assert_eq!(driver.network.fences.lock().unwrap()[&reacher], [made]);
}
