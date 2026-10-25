//! workerd's configuration as it is made for a deployment of the samples, and for what they do not
//! send, its secrets and a network it may not reach.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::collections::BTreeMap;

use common::{bundle, from_root, hash, here, hex, json};
use driver_machine_function::{Bound, Bundle, Configure, Kind, PORT, Unpack, Worker};
use envelope::Called;
use envelope::contracts::interface::deployments::Call;
use envelope::contracts::{DeploymentDeploy, DeploymentHanded, DeploymentNetwork};

/// The first deploy of `deploys.json`, of `echo-modules`, as the runner fills it.
fn deployed() -> DeploymentDeploy {
	let sample = json(&from_root("../platform/tests/kinds/deployments/deploys.json"));
	let mut input = sample["cases"][0]["steps"][0]["input"].clone();
	let built = hex(&hash(&bundle("echo-modules")));
	input["version"] = built.clone().into();
	input["form"] = "modules".into();
	input["artifact"] = serde_json::json!({ "address": "echo-modules", "hash": built });
	let Call::Deploy(input) = Call::from_json("deploy", &input).unwrap() else {
		panic!("not a deploy")
	};
	input
}

#[test]
fn the_configuration_made_for_a_sample_deployment_is_as_written() {
	let bundle = Bundle::unpack(&bundle("echo-modules")).unwrap();
	let worker = Worker::of(&deployed(), &bundle);
	let expected = std::fs::read_to_string(here().join("tests/workerd/echo.capnp")).unwrap();
	assert_eq!(worker.capnp(), expected);
}

#[test]
fn a_secret_is_named_and_never_written_and_a_network_not_given_is_not_reached() {
	let bundle = Bundle::unpack(&bundle("counter-modules")).unwrap();
	let input = DeploymentDeploy {
		secrets: BTreeMap::from([("TOKEN".into(), b"hidden".to_vec())]),
		network: vec![DeploymentNetwork::Udp],
		..deployed()
	};
	let worker = Worker::of(&input, &bundle);
	assert_eq!(worker.modules, vec![("counter.mjs".to_owned(), Kind::Es)]);
	assert_eq!(worker.compatibility_flags, vec!["nodejs_compat".to_owned()]);
	assert_eq!(worker.bindings[1], Bound::Secret { name: "TOKEN".into() });
	assert_eq!((worker.port, worker.outbound), (PORT, false));
	let config = worker.capnp();
	assert!(config.contains("(name = \"TOKEN\", text = embed \"/TOKEN\")"), "{config}");
	assert!(config.contains("(name = \"outbound\", network = (allow = []))"), "{config}");
	assert!(config.contains("compatibilityFlags = [\n\t\t\"nodejs_compat\"\n\t]"), "{config}");
	assert!(!config.contains("hidden"));
	// A tcp network reaches out as http does, since workerd connects through one service.
	let tcp = DeploymentDeploy { network: vec![DeploymentNetwork::Tcp], ..input };
	assert!(Worker::of(&tcp, &bundle).outbound);
}

#[test]
fn what_is_handed_follows_the_footing_by_its_reserved_name() {
	let bundle = Bundle::unpack(&bundle("echo-modules")).unwrap();
	let handed = vec![
		DeploymentHanded::Key { value: b"made-up key".to_vec() },
		DeploymentHanded::Certificate { value: vec![0x0e, 0xa0] },
	];
	let input = DeploymentDeploy {
		handed: Some(handed),
		secrets: BTreeMap::from([("TOKEN".into(), b"hidden".to_vec())]),
		..deployed()
	};
	let worker = Worker::of(&input, &bundle);
	let names: Vec<&str> = worker
		.bindings
		.iter()
		.map(|b| match b {
			Bound::Text { name, .. } | Bound::Secret { name } => name.as_str(),
		})
		.collect();
	assert_eq!(names, ["MONOFLAKE_FOOTING", "MONOFLAKE_KEY", "MONOFLAKE_CERTIFICATE", "TOKEN"]);
	assert_eq!(worker.bindings[1], Bound::Secret { name: "MONOFLAKE_KEY".into() });
	let certificate = Bound::Text { name: "MONOFLAKE_CERTIFICATE".into(), text: "0ea0".into() };
	assert_eq!(worker.bindings[2], certificate);
}

#[test]
fn a_worker_that_reaches_is_given_the_private_network_and_one_that_does_not_is_not() {
	use envelope::contracts::DeploymentRuns;
	let bundle = Bundle::unpack(&bundle("echo-modules")).unwrap();
	let target = DeploymentRuns::App { id: 9 };
	let reaching = DeploymentDeploy { reaching: Some(vec![target]), ..deployed() };
	let worker = Worker::of(&reaching, &bundle);
	assert!(worker.reaches);
	let config = worker.capnp();
	let opened = "(allow = [\"public\", \"private\"], tlsOptions = (trustBrowserCas = true))";
	assert!(config.contains(opened), "{config}");
	let from = "(name = \"MONOFLAKE_REACHING\", fromEnvironment = \"MONOFLAKE_REACHING\")";
	assert!(config.contains(from), "{config}");
	let closed = DeploymentDeploy { network: Vec::new(), ..reaching };
	assert!(Worker::of(&closed, &bundle).capnp().contains("network = (allow = [\"private\"])"));
	let none = DeploymentDeploy { reaching: Some(Vec::new()), ..deployed() };
	assert!(!Worker::of(&none, &bundle).reaches);
	assert!(!Worker::of(&none, &bundle).capnp().contains("private"));
}
