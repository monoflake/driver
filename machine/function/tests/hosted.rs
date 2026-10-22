//! What the function kind asks of the container kind, workerd from its image, its configuration
//! and modules given as files, in a container of the binding's, and nothing it cannot give.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::collections::BTreeMap;
use std::path::PathBuf;

use common::{WORKERD, binding, bundle, functions, hash};
use driver_machine_container::{Binding, Deployments};
use envelope::contracts::{
	DeploymentArtifact, DeploymentDeploy, DeploymentForm, DeploymentIsolation, DeploymentNetwork,
	DeploymentRuns, DeploymentRuntime,
};

fn echo() -> DeploymentDeploy {
	let bytes = bundle("echo-modules");
	DeploymentDeploy {
		runs: DeploymentRuns::App { id: 1 },
		version: hash(&bytes),
		form: DeploymentForm::Modules,
		runtime: None,
		isolation: vec![DeploymentIsolation::Isolate],
		artifact: DeploymentArtifact {
			address: "echo-modules".into(),
			hash: hash(&bytes),
			architecture: None,
		},
		footing: "https://footing.invalid".into(),
		secrets: BTreeMap::new(),
		network: vec![DeploymentNetwork::Http],
		into: None,
		port: None,
	}
}

fn served() -> BTreeMap<String, Vec<u8>> {
	BTreeMap::from([("echo-modules".to_owned(), bundle("echo-modules"))])
}

#[tokio::test]
async fn workerd_is_hosted_from_its_image_with_its_configuration_and_modules() {
	let functions = functions(served());
	functions.deploy(&binding(), echo()).await.unwrap();
	let hosted = functions.containers.hosted.lock().unwrap();
	let [(input, hosted)] = hosted.as_slice() else { panic!("hosted {}", hosted.len()) };
	assert_eq!(input.into, Some(1), "the binding's container, none named");
	assert_eq!(hosted.image, PathBuf::from(WORKERD));
	assert_eq!(hosted.cmd, ["serve", "/worker/config.capnp", "config"]);
	assert_eq!((hosted.port, hosted.at.as_str()), (8080, "/worker"));
	assert_eq!(hosted.runtime, DeploymentRuntime::Workerd);
	assert_eq!(hosted.isolation, [DeploymentIsolation::Isolate, DeploymentIsolation::Kernel]);
	let names: Vec<&str> = hosted.files.keys().map(String::as_str).collect();
	assert_eq!(names, ["config.capnp", "modules/index.js", "modules/lib/answer.js"]);
	let index = std::fs::read(common::here().join("tests/bundles/echo-modules/index.js")).unwrap();
	assert_eq!(hosted.files["modules/index.js"], index);
}

#[tokio::test]
async fn secrets_are_imported_only_where_a_deployment_has_them() {
	let functions = functions(served());
	let secrets = BTreeMap::from([("TOKEN".to_owned(), b"hidden".to_vec())]);
	let secret = DeploymentDeploy { runs: DeploymentRuns::App { id: 2 }, secrets, ..echo() };
	functions.deploy(&binding(), echo()).await.unwrap();
	functions.deploy(&binding(), secret).await.unwrap();
	let hosted = functions.containers.hosted.lock().unwrap();
	let [(_, none), (_, one)] = hosted.as_slice() else { panic!("hosted {}", hosted.len()) };
	assert_eq!(none.cmd, ["serve", "/worker/config.capnp", "config"]);
	let config = String::from_utf8(none.files["config.capnp"].clone()).unwrap();
	assert!(!config.contains("embed \"/"), "no secret file named, {config}");
	let imported = ["serve", "/worker/config.capnp", "config", "--import-path", "/run/secrets"];
	assert_eq!(one.cmd, imported);
	let config = String::from_utf8(one.files["config.capnp"].clone()).unwrap();
	assert!(config.contains("(name = \"TOKEN\", text = embed \"/TOKEN\")"), "{config}");
}

#[tokio::test]
async fn deployed_again_the_same_nothing_is_fetched_and_a_new_version_is() {
	let functions = functions(served());
	functions.deploy(&binding(), echo()).await.unwrap();
	functions.deploy(&binding(), echo()).await.unwrap();
	assert_eq!(functions.containers.fetched.lock().unwrap().len(), 1);
	let named = DeploymentDeploy { into: Some(1), version: [7; 32], ..echo() };
	functions.deploy(&binding(), named).await.unwrap();
	assert_eq!(functions.containers.fetched.lock().unwrap().len(), 2);
	assert_eq!(functions.containers.hosted.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn what_workerd_cannot_give_is_beyond_the_host_and_nothing_is_fetched() {
	let functions = functions(served());
	let empty = Binding { capacities: BTreeMap::new(), ..binding() };
	let refused = [
		(binding(), DeploymentDeploy { form: DeploymentForm::Component, ..echo() }),
		(binding(), DeploymentDeploy { form: DeploymentForm::Image, ..echo() }),
		(binding(), DeploymentDeploy { runtime: Some(DeploymentRuntime::Wasmtime), ..echo() }),
		(binding(), DeploymentDeploy { runtime: Some(DeploymentRuntime::Runc), ..echo() }),
		(binding(), DeploymentDeploy { isolation: vec![DeploymentIsolation::Userspace], ..echo() }),
		(empty, echo()),
	];
	for (binding, input) in refused {
		let answered = functions.deploy(&binding, input.clone()).await.map_err(|r| r.reason);
		assert_eq!(answered, Err("beyond_host"), "{input:?}");
	}
	assert!(functions.containers.fetched.lock().unwrap().is_empty());
	let named = DeploymentDeploy { runtime: Some(DeploymentRuntime::Workerd), ..echo() };
	let kernel = vec![DeploymentIsolation::Kernel, DeploymentIsolation::Isolate];
	let standing = DeploymentDeploy { isolation: kernel, ..named };
	assert!(functions.deploy(&binding(), standing).await.is_ok());
}

#[tokio::test]
async fn an_artifact_that_is_no_bundle_is_malformed_and_nothing_is_hosted() {
	let served = BTreeMap::from([("broken".to_owned(), b"no archive".to_vec())]);
	let functions = functions(served);
	let artifact =
		DeploymentArtifact { address: "broken".into(), hash: hash(b"no archive"), architecture: None };
	let broken = DeploymentDeploy { artifact, ..echo() };
	assert_eq!(functions.deploy(&binding(), broken).await.map_err(|r| r.reason), Err("malformed"));
	assert!(functions.containers.hosted.lock().unwrap().is_empty());
}
