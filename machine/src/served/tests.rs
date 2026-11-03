//! The router's own logic, its turns, its refusals and its arguments.

use std::pin::pin;
use std::task::{Context, Poll, Waker};

use envelope::contracts::interface::deployments;
use envelope::contracts::{DeploymentOf, DeploymentRuns};

use super::{TURNS, deployed, deployment, started};
use crate::Arguments;
use crate::answer::Form;

/// A driver of nothing, reaching no containerd.
fn driver() -> super::Driver {
	let nowhere = std::path::PathBuf::from("/nonexistent");
	started(Arguments {
		listen: crate::LISTEN,
		bindings: Vec::new(),
		state: nowhere.clone(),
		containerd: nowhere.clone(),
		runc: nowhere.clone(),
		crun: nowhere.clone(),
		youki: nowhere.clone(),
		roots: nowhere.clone(),
		nix_store: None,
		plugins: nowhere.clone(),
		bridge: "bridge".into(),
		subnet: "10.88.0.0/16".into(),
		entry: 4321,
		mount: nowhere.clone(),
		btrfs: nowhere.clone(),
		local: None,
		plain: None,
		secrets: nowhere.clone(),
		largest: 1,
		workerd: nowhere,
	})
}

#[tokio::test]
async fn a_call_on_a_deployment_waits_for_the_one_before_on_it_to_be_answered() {
	let driver = std::sync::Arc::new(driver());
	let runs = DeploymentRuns::App { id: 7 };
	let held = TURNS.taken(deployment(7, &runs)).await;
	let stop = deployments::Call::Stop(DeploymentOf { runs: runs.clone() });
	let mut waiting = pin!(deployed(driver.clone(), 7, stop, Form::Json));
	let mut context = Context::from_waker(Waker::noop());
	assert!(waiting.as_mut().poll(&mut context).is_pending(), "it ran while the turn was held");
	// Another deployment of the binding, or the same of another binding, is not held back.
	let other = deployments::Call::Stop(DeploymentOf { runs: DeploymentRuns::App { id: 8 } });
	let apart = pin!(deployed(driver.clone(), 7, other, Form::Json)).poll(&mut context);
	assert!(matches!(apart, Poll::Ready(_)));
	let elsewhere = deployments::Call::Stop(DeploymentOf { runs });
	let apart = pin!(deployed(driver.clone(), 9, elsewhere, Form::Json)).poll(&mut context);
	assert!(matches!(apart, Poll::Ready(_)));
	drop(held);
	assert_eq!(waiting.await.outcome, "error rejected not_found");
}

#[test]
fn a_database_refusal_keeps_its_reason_and_words() {
	use driver_machine_database::{Fault, Unexecuted};
	let cases = [
		(Unexecuted::Invalid("syntax".into()), "invalid", Some("syntax")),
		(Unexecuted::Constraint("unique".into()), "constraint", Some("unique")),
		(Unexecuted::BeyondLimit("statement".into()), "beyond_limit", Some("statement")),
		(Unexecuted::BeyondRange("integer".into()), "beyond_range", Some("integer")),
		(Unexecuted::StorageFull, "storage_full", None),
		(Unexecuted::Fault(Fault("disk".into())), "fault", Some("disk")),
	];
	for (refusal, reason, words) in cases {
		let refused = super::unexecuted(refusal);
		assert_eq!((refused.reason, refused.message.as_deref()), (reason, words));
	}
}

#[test]
fn the_bridge_names_the_entry_at_the_port_the_driver_is_given() {
	use clap::Parser as _;
	let given = |entry: Option<&str>| {
		let mut args =
			vec!["driver-machine", "--state", "/nonexistent", "--containerd", "/nonexistent"];
		args.extend(["--runc", "/r", "--crun", "/c", "--youki", "/y", "--plugins", "/p"]);
		args.extend(["--bridge", "bridge", "--subnet", "192.0.2.0/24", "--mount", "/nonexistent"]);
		args.extend(["--btrfs", "/b", "--secrets", "/nonexistent", "--largest", "1"]);
		args.extend(["--workerd", "/nonexistent"]);
		args.extend(entry.map(|e| ["--entry", e]).into_iter().flatten());
		crate::Program::try_parse_from(args)
	};
	// The flag reaches the bridge, whatever port it names, and none is assumed without it.
	for port in [4321u16, 4999] {
		let program = given(Some(&port.to_string())).unwrap();
		let arguments = program.driver.unwrap();
		assert_eq!(started(arguments).functions.containers.network.entry, port);
	}
	assert!(given(None).is_err());
}

#[test]
fn a_component_takes_its_turn_by_its_id() {
	let component = |name: &str, id| DeploymentRuns::Component { component: name.into(), id };
	assert_eq!(deployment(7, &component("issuer", 3)), deployment(7, &component("renamed", 3)));
	assert_ne!(deployment(7, &component("issuer", 3)), deployment(7, &component("issuer", 4)));
}
