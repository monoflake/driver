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
use envelope::contracts::{DeploymentDeploy, DeploymentNetwork};

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
