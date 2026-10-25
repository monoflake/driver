//! `Containers` deploying an image, what its spec holds, the image, runtime and handed values it
//! runs with, and what it refuses before anything is made.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use common::{
	ECHO, ECHO_TWO, LARGEST, app, binding, cleared, deploy, driver, echo, hash, lines, of, reason,
	running, shell, spec_of,
};
use driver_machine_container::{Binding, Capacity, Chosen, Deployments, ImageConfig, Runtimes};
use envelope::contracts::{
	Architecture, DeploymentDeploy, DeploymentDescribed, DeploymentForm, DeploymentHanded,
	DeploymentIsolation, DeploymentOf, DeploymentRuns, DeploymentRuntime, DeploymentState,
};
use serde_json::Value;

#[tokio::test]
async fn an_image_deployed_runs_and_is_described_at_its_port() {
	let (driver, _) = driver("deployed", shell(), false);
	let deployed = driver.deploy(&binding(), echo()).await.unwrap();
	let expected =
		DeploymentDescribed { runs: app(), version: hash(ECHO), state: running("10.88.0.2:8080") };
	assert_eq!(deployed, expected);
	assert_eq!(driver.describe(&binding(), of()).await.unwrap(), expected);
}

#[tokio::test]
async fn its_layer_joins_the_qgroup_before_its_task_starts() {
	let (driver, log) = driver("ordered", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let id =
		"app-1-".to_owned() + &hash(ECHO).iter().map(|b| format!("{b:02x}")).collect::<String>()[..12];
	let rootfs = driver.containerd.rootfs.display().to_string();
	let output = driver.state.join("output/b1").join(format!("{id}.log"));
	assert_eq!(
		lines(&log),
		[
			format!("fetch file:///echo.tar at most {LARGEST}"),
			"import b1 echo image".to_owned(),
			format!("prepare b1 {id} on sha256:top"),
			format!("snapshot_path {id}"),
			format!("assign {rootfs} 1/7"),
			format!("attach b1-{id} 8080"),
			format!("create b1 {id} with 1 mounts to {}", output.display()),
			format!("start {id}"),
		]
	);
	// The archive is not kept once containerd holds the image.
	assert_eq!(std::fs::read_dir(driver.state.join("artifacts")).unwrap().count(), 0);
}

#[tokio::test]
async fn its_spec_holds_its_capacity_its_network_and_what_it_is_given() {
	let (driver, _) = driver("spec", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let spec = spec_of(&driver);
	assert_eq!(spec.binary, PathBuf::from("/bin/runc"));
	assert_eq!(spec.snapshot, spec.id);
	assert_eq!(spec.image, "artifact/x");
	let s = &spec.runtime_spec;
	assert_eq!(s["process"]["args"], serde_json::json!(["/bin/sh"]));
	assert_eq!(
		s["process"]["env"],
		serde_json::json!(["PATH=/usr/bin:/bin", "MONOFLAKE_FOOTING=https://footing.invalid"])
	);
	assert_eq!(s["process"]["cwd"], "/");
	// No container holds a raw socket, RFC p95sv.
	for set in ["bounding", "effective", "permitted"] {
		let held = s["process"]["capabilities"][set].as_array().unwrap();
		assert!(held.contains(&"CAP_CHOWN".into()), "{set}");
		assert!(!held.contains(&"CAP_NET_RAW".into()), "{set}");
	}
	assert_eq!(s["process"]["user"], serde_json::json!({ "uid": 0, "gid": 0 }));
	assert_eq!(s["root"]["path"], "rootfs");
	assert_eq!(
		s["linux"]["resources"]["cpu"],
		serde_json::json!({ "period": 100_000, "quota": 50_000 })
	);
	assert_eq!(s["linux"]["resources"]["memory"]["limit"], 268_435_456);
	assert_eq!(s["linux"]["cgroupsPath"], format!("/b1/{}", spec.id));
	let network =
		s["linux"]["namespaces"].as_array().unwrap().iter().find(|n| n["type"] == "network").unwrap();
	assert_eq!(network["path"], format!("/run/netns/b1-{}", spec.id), "reaching nothing, its own");
	// A secret is a file bound into the container, never in its spec, labels or sealed copy.
	let open = driver.secrets.join("b1").join(&spec.id);
	let bound = s["mounts"].as_array().unwrap().iter().find(|m| m["destination"] == "/run/secrets");
	assert_eq!(
		bound.unwrap(),
		&serde_json::json!({
			"destination": "/run/secrets",
			"type": "bind",
			"source": open,
			"options": ["rbind", "ro", "nosuid", "nodev", "noexec"],
		})
	);
	assert_eq!(std::fs::read(open.join("TOKEN")).unwrap(), b"hidden");
	// The machine's resolver is bound read only, as an image may hold none.
	let resolver =
		s["mounts"].as_array().unwrap().iter().find(|m| m["destination"] == "/etc/resolv.conf");
	assert_eq!(resolver.unwrap()["source"], "/etc/resolv.conf");
	assert!(resolver.unwrap()["options"].as_array().unwrap().iter().any(|o| o == "ro"));
	let sealed = std::fs::read(driver.state.join("secrets/b1").join(&spec.id).join("TOKEN")).unwrap();
	assert!(!sealed.windows(6).any(|w| w == b"hidden"));
	assert!(!s.to_string().contains("hidden"));
	assert!(spec.labels.values().all(|v| !v.contains("hidden")));
}

#[tokio::test]
async fn a_deployment_without_secrets_binds_none() {
	let (driver, _) = driver("secretless", shell(), false);
	driver.deploy(&binding(), DeploymentDeploy { secrets: BTreeMap::new(), ..echo() }).await.unwrap();
	let s = spec_of(&driver).runtime_spec;
	assert!(s["mounts"].as_array().unwrap().iter().all(|m| m["destination"] != "/run/secrets"));
	assert!(!driver.state.join("secrets.key").exists());
}

#[tokio::test]
async fn secrets_lost_to_a_reboot_are_put_back_on_resuming() {
	let (driver, _) = driver("rebooted", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	driver.stop(&binding(), of()).await.unwrap();
	let tmpfs = driver.secrets.clone();
	cleared(&tmpfs);
	std::fs::remove_dir_all(&tmpfs).unwrap();
	driver.resume(&binding(), of()).await.unwrap();
	let id = spec_of(&driver).id;
	assert_eq!(std::fs::read(tmpfs.join("b1").join(id).join("TOKEN")).unwrap(), b"hidden");
}

#[tokio::test]
async fn a_real_image_configuration_runs_as_its_user_in_its_directory() {
	let config: Value = serde_json::from_str(include_str!("images/prometheus.json")).unwrap();
	let strings =
		|v: &Value| v.as_array().unwrap().iter().map(|s| s.as_str().unwrap().to_owned()).collect();
	let runs = &config["config"];
	let image = ImageConfig {
		entrypoint: strings(&runs["Entrypoint"]),
		cmd: strings(&runs["Cmd"]),
		env: strings(&runs["Env"]),
		working_dir: runs["WorkingDir"].as_str().map(str::to_owned),
		user: runs["User"].as_str().map(str::to_owned),
	};
	let (driver, _) = driver("prometheus", image, false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let s = spec_of(&driver).runtime_spec;
	assert_eq!(
		s["process"]["args"],
		serde_json::json!([
			"/bin/prometheus",
			"--config.file=/etc/prometheus/prometheus.yml",
			"--storage.tsdb.path=/prometheus"
		])
	);
	assert_eq!(s["process"]["cwd"], "/prometheus");
	assert_eq!(s["process"]["user"], serde_json::json!({ "uid": 65534, "gid": 65534 }));
	assert_eq!(
		s["process"]["env"][0],
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	);
}

#[tokio::test]
async fn a_user_and_group_named_are_read_from_the_image() {
	let config = ImageConfig { user: Some("nobody:nogroup".into()), ..shell() };
	let (named, _) = driver("named", config, false);
	named.deploy(&binding(), echo()).await.unwrap();
	assert_eq!(
		spec_of(&named).runtime_spec["process"]["user"],
		serde_json::json!({ "uid": 65534, "gid": 65533 })
	);
	let config = ImageConfig { user: Some("nobody-at-all".into()), ..shell() };
	let (unnamed, _) = driver("unnamed", config, false);
	assert_eq!(reason(unnamed.deploy(&binding(), echo()).await.unwrap_err()), "malformed");
}

#[tokio::test]
async fn an_image_naming_nothing_to_run_is_refused_and_leaves_nothing() {
	let (driver, log) = driver("empty", ImageConfig::default(), false);
	assert_eq!(reason(driver.deploy(&binding(), echo()).await.unwrap_err()), "malformed");
	assert!(driver.containerd.held.lock().unwrap().is_empty());
	assert!(lines(&log).iter().any(|l| l.starts_with("remove ")));
	assert!(lines(&log).iter().any(|l| l.starts_with("detach ")));
}

#[tokio::test]
async fn deploying_the_same_again_is_the_one_deployment() {
	let (driver, log) = driver("again", shell(), false);
	let first = driver.deploy(&binding(), echo()).await.unwrap();
	let before = lines(&log).len();
	let second = driver.deploy(&binding(), echo()).await.unwrap();
	assert_eq!(first, second);
	assert_eq!(lines(&log).len(), before);
	assert_eq!(driver.containerd.held.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn a_new_version_replaces_the_one_before() {
	let (driver, log) = driver("replaced", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	let two = driver.deploy(&binding(), deploy("file:///echo-two.tar", ECHO_TWO)).await.unwrap();
	assert_eq!(two.version, hash(ECHO_TWO));
	assert_eq!(two.state, running("10.88.0.3:8080"), "the new serves beside the old");
	let held = driver.containerd.held.lock().unwrap();
	assert_eq!(held.len(), 1);
	let old =
		"app-1-".to_owned() + &hash(ECHO).iter().map(|b| format!("{b:02x}")).collect::<String>()[..12];
	let log = lines(&log);
	let start_two = log.iter().position(|l| l.starts_with("start ") && !l.ends_with(&old)).unwrap();
	let stop_one = log.iter().position(|l| *l == format!("stop {old} within 10000")).unwrap();
	assert!(start_two < stop_one, "reaching nothing, the new runs before the old is stopped");
	assert!(log.contains(&format!("remove {old}")));
	assert!(log.contains(&format!("detach b1-{old}")));
}

#[tokio::test]
async fn what_the_host_cannot_give_is_beyond_it_and_nothing_is_fetched() {
	let (driver, log) = driver("beyond", shell(), false);
	let modules = DeploymentDeploy { form: DeploymentForm::Modules, ..echo() };
	let vm = DeploymentDeploy { isolation: vec![DeploymentIsolation::Vm], ..echo() };
	let isolate = DeploymentDeploy {
		isolation: vec![DeploymentIsolation::Kernel, DeploymentIsolation::Isolate],
		..echo()
	};
	let workerd = DeploymentDeploy { runtime: Some(DeploymentRuntime::Workerd), ..echo() };
	let elsewhere = DeploymentDeploy { into: Some(9), ..echo() };
	for input in [modules, vm, isolate, workerd, elsewhere] {
		assert_eq!(reason(driver.deploy(&binding(), input).await.unwrap_err()), "beyond_host");
	}
	assert!(lines(&log).is_empty());
}

/// The architecture these tests run on, and the other, as OCI names them.
fn architectures() -> (Architecture, Architecture) {
	match std::env::consts::ARCH {
		"aarch64" => (Architecture::Arm64, Architecture::Amd64),
		_ => (Architecture::Amd64, Architecture::Arm64),
	}
}

fn built_for(architecture: Architecture) -> DeploymentDeploy {
	let mut input = echo();
	input.artifact.architecture = Some(architecture);
	input
}

#[tokio::test]
async fn an_image_of_the_machines_architecture_deploys() {
	let (driver, log) = driver("native", shell(), false);
	let deployed = driver.deploy(&binding(), built_for(architectures().0)).await.unwrap();
	assert_eq!(deployed.state, running("10.88.0.2:8080"));
	assert_eq!(lines(&log).first().unwrap(), &format!("fetch file:///echo.tar at most {LARGEST}"));
}

#[tokio::test]
async fn an_image_of_another_architecture_is_beyond_the_host_and_nothing_is_fetched() {
	let (driver, log) = driver("foreign", shell(), false);
	let refused = driver.deploy(&binding(), built_for(architectures().1)).await.unwrap_err();
	assert_eq!(reason(refused), "beyond_host");
	assert!(lines(&log).is_empty());
}

#[tokio::test]
async fn an_image_without_its_port_or_with_a_secret_misnamed_is_malformed() {
	let (driver, log) = driver("unplaced", shell(), false);
	let portless = DeploymentDeploy { port: None, ..echo() };
	let wide = DeploymentDeploy { port: Some(70_000), ..echo() };
	let secret = |name: &str| DeploymentDeploy {
		secrets: BTreeMap::from([(name.to_owned(), b"x".to_vec())]),
		..echo()
	};
	let platform = secret("MONOFLAKE_FOOTING");
	let escaping = secret("../TOKEN");
	let hidden = secret(".TOKEN");
	for input in [portless, wide, platform, escaping, hidden] {
		assert_eq!(reason(driver.deploy(&binding(), input).await.unwrap_err()), "malformed");
	}
	assert!(lines(&log).is_empty());
}

#[tokio::test]
async fn an_image_naming_no_container_runs_in_the_binding_s_first_and_none_held_is_beyond_it() {
	let (driver, _) = driver("first", shell(), false);
	let mut two = binding();
	two.capacities.insert(9, Capacity { millicores: 250, memory: 268_435_456 });
	driver.deploy(&two, DeploymentDeploy { into: None, ..echo() }).await.unwrap();
	assert_eq!(spec_of(&driver).labels["driver.into"], "3");
	// One named is the one it runs in.
	let named = DeploymentDeploy { runs: DeploymentRuns::App { id: 2 }, into: Some(9), ..echo() };
	driver.deploy(&two, named).await.unwrap();
	let into: Vec<String> = {
		let held = driver.containerd.held.lock().unwrap();
		held.values().map(|h| h.labels["driver.into"].clone()).collect()
	};
	assert_eq!(into, ["3", "9"]);
	let none = Binding { capacities: BTreeMap::new(), ..binding() };
	let refused = driver.deploy(&none, DeploymentDeploy { into: None, ..echo() }).await.unwrap_err();
	assert_eq!(reason(refused), "beyond_host");
}

#[tokio::test]
async fn a_failure_of_the_machine_is_a_fault_and_undoes_what_was_made() {
	let (driver, log) = driver("refused", shell(), true);
	let refused = driver.deploy(&binding(), echo()).await.unwrap_err();
	assert_eq!(refused.reason, "fault");
	assert_eq!(refused.message.as_deref(), Some("ERROR: quotas not enabled"));
	let log = lines(&log);
	assert!(!log.iter().any(|l| l.starts_with("start ")));
	assert!(log.iter().any(|l| l.starts_with("remove ")));
}

#[tokio::test]
async fn the_runtime_named_runs_it_and_runc_otherwise() {
	for (named, binary) in
		[(DeploymentRuntime::Crun, "/bin/crun"), (DeploymentRuntime::Youki, "/bin/youki")]
	{
		let (driver, _) = driver(&format!("runtime-{binary}").replace('/', "-"), shell(), false);
		let deployed =
			driver.deploy(&binding(), DeploymentDeploy { runtime: Some(named), ..echo() }).await.unwrap();
		assert_eq!(spec_of(&driver).binary, PathBuf::from(binary));
		let DeploymentState::Running { runtime, .. } = deployed.state else {
			panic!("not running: {deployed:?}")
		};
		assert_eq!(runtime, named);
	}
	let runtimes = Runtimes { runc: "/r".into(), crun: "/c".into(), youki: "/y".into() };
	assert_eq!(runtimes.binary(None), Path::new("/r"));
	assert_eq!(runtimes.binary(Some(&DeploymentRuntime::Runc)), Path::new("/r"));
	assert_eq!(runtimes.binary(Some(&DeploymentRuntime::Crun)), Path::new("/c"));
	assert_eq!(runtimes.binary(Some(&DeploymentRuntime::Youki)), Path::new("/y"));
}

#[tokio::test]
async fn a_component_is_known_by_its_id_and_not_its_name() {
	let (driver, _) = driver("components", shell(), false);
	let component = |name: &str, id: u32| DeploymentDeploy {
		runs: DeploymentRuns::Component { component: name.into(), id },
		..echo()
	};
	driver.deploy(&binding(), component("issuer", 0x1a2b_3c4d)).await.unwrap();
	driver.deploy(&binding(), component("issuer", 0x0000_0007)).await.unwrap();
	let ids: Vec<String> =
		driver.containerd.held.lock().unwrap().keys().map(|k| k.1.clone()).collect();
	let short = &hash(ECHO).iter().map(|b| format!("{b:02x}")).collect::<String>()[..12];
	assert_eq!(ids, [format!("component-00000007-{short}"), format!("component-1a2b3c4d-{short}")]);
	// The same id under another name is the one deployment, described as it is asked.
	let renamed = DeploymentOf { runs: DeploymentRuns::Component { component: "x".into(), id: 7 } };
	assert_eq!(driver.describe(&binding(), renamed.clone()).await.unwrap().runs, renamed.runs);
}

#[tokio::test]
async fn what_is_handed_is_bound_under_its_reserved_name() {
	let (driver, _) = driver("handed", shell(), false);
	let handed = vec![
		DeploymentHanded::Root { value: vec![0xc0, 0x01] },
		DeploymentHanded::Key { value: b"made-up key".to_vec() },
		DeploymentHanded::Certificate { value: vec![0x0e] },
		DeploymentHanded::SigningKey { value: b"made-up signing key".to_vec() },
	];
	driver.deploy(&binding(), DeploymentDeploy { handed: Some(handed), ..echo() }).await.unwrap();
	let spec = spec_of(&driver);
	assert_eq!(
		spec.runtime_spec["process"]["env"],
		serde_json::json!([
			"PATH=/usr/bin:/bin",
			"MONOFLAKE_FOOTING=https://footing.invalid",
			"MONOFLAKE_ROOT=c001",
			"MONOFLAKE_CERTIFICATE=0e",
		])
	);
	// A secret handed is a file among its secrets, beside its own.
	let open = driver.secrets.join("b1").join(&spec.id);
	// Every value handed is hex text, a secret's too.
	let hex = |b: &[u8]| b.iter().map(|b| format!("{b:02x}")).collect::<String>().into_bytes();
	assert_eq!(std::fs::read(open.join("MONOFLAKE_KEY")).unwrap(), hex(b"made-up key"));
	let signing = std::fs::read(open.join("MONOFLAKE_SIGNING_KEY")).unwrap();
	assert_eq!(signing, hex(b"made-up signing key"));
	assert_eq!(std::fs::read(open.join("TOKEN")).unwrap(), b"hidden");
	let labels = serde_json::to_string(&spec.labels).unwrap();
	assert!(!labels.contains(&String::from_utf8(hex(b"made-up")).unwrap()), "{labels}");
}

#[tokio::test]
async fn a_value_handed_twice_is_invalid_and_nothing_is_made() {
	let (driver, log) = driver("handed-twice", shell(), false);
	let twice =
		vec![DeploymentHanded::Root { value: vec![1] }, DeploymentHanded::Root { value: vec![2] }];
	let refused = driver.deploy(&binding(), DeploymentDeploy { handed: Some(twice), ..echo() }).await;
	assert_eq!(refused.map_err(reason), Err("invalid"));
	assert!(lines(&log).is_empty());
}

#[tokio::test]
async fn a_new_version_reaching_nothing_failing_leaves_the_one_before_running() {
	let (mut driver, _) = driver("failed-overlapped", shell(), false);
	driver.deploy(&binding(), echo()).await.unwrap();
	driver.containerd.config = ImageConfig::default();
	let two = deploy("file:///echo-two.tar", ECHO_TWO);
	assert_eq!(driver.deploy(&binding(), two).await.map_err(reason), Err("malformed"));
	let described = driver.describe(&binding(), of()).await.unwrap();
	assert_eq!((described.version, described.state), (hash(ECHO), running("10.88.0.2:8080")));
}
