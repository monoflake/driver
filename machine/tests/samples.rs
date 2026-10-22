//! The kinds' samples run against the program, each case on a binding of its own, RFC p8e8k. A
//! case that needs a machine is told apart by its steps and held to what it answers here.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::time::{Duration, Instant};

use common::{Started, answered, sample};
use serde_json::Value;

const MANAGEMENT: [&str; 3] = [
	"../platform/tests/kinds/management/lists.json",
	"../platform/tests/kinds/management/graces.json",
	"../platform/tests/kinds/management/ends.json",
];
const DEPLOYMENTS: &str = "../platform/tests/kinds/deployments/lifecycle.json";

/// The RFC an apply naming any item waits on, answered `fault` until it is decided.
const MAKING: &str = "4elqc";

/// How a case ended, every step as expected or stopped where it waits on the making of a list.
#[derive(Debug, PartialEq)]
enum Ran {
	Passed,
	Waiting,
}

/// One case's steps on its own binding, each step called again until it matches or its `within`
/// has passed.
fn ran(driver: &Started, binding: u32, interface: &str, case: &Value) -> Ran {
	for step in case["steps"].as_array().unwrap() {
		let operation = step["call"].as_str().unwrap();
		let within = Duration::from_millis(step["within"].as_u64().unwrap_or(0));
		let until = Instant::now() + within;
		let answer = loop {
			let (_, answer) = driver.call(binding, interface, operation, &step["input"]);
			if answered(&step["expect"], &answer) || Instant::now() >= until {
				break answer;
			}
			std::thread::sleep(Duration::from_millis(100));
		};
		if answered(&step["expect"], &answer) {
			continue;
		}
		let items = step["input"]["items"].as_array().is_some_and(|i| !i.is_empty());
		let waits = answer["reason"] == "fault" && answer["message"].as_str().unwrap().contains(MAKING);
		assert!(
			operation == "apply" && items && waits,
			"{}: {step} answered {answer}",
			case["description"]
		);
		return Ran::Waiting;
	}
	Ran::Passed
}

#[test]
fn the_management_samples_hold_but_what_waits_on_the_making_of_a_list() {
	let cases: Vec<Value> =
		MANAGEMENT.iter().flat_map(|file| sample(file)["cases"].as_array().unwrap().clone()).collect();
	let driver = Started::with("management", u32::try_from(cases.len()).unwrap());
	let mut passed = Vec::new();
	let mut waiting = Vec::new();
	for (binding, case) in (1..).zip(&cases) {
		let description = case["description"].as_str().unwrap().to_owned();
		match ran(&driver, binding, "management", case) {
			Ran::Passed => passed.push(description),
			Ran::Waiting => waiting.push(description),
		}
	}
	eprintln!("passed: {passed:#?}\nwaiting on RFC {MAKING}: {waiting:#?}");
	assert_eq!(passed.len(), 4, "{passed:#?}");
	assert_eq!(passed.len() + waiting.len(), cases.len());
}

#[test]
fn what_a_deployment_never_deployed_answers_holds() {
	let driver = Started::with("lifecycle", 1);
	let cases = sample(DEPLOYMENTS)["cases"].as_array().unwrap().clone();
	// A case deploying a fixture needs a machine's containerd and runtimes, which no test here has.
	let here: Vec<&Value> = cases
		.iter()
		.filter(|c| c["steps"].as_array().unwrap().iter().all(|s| s.get("fixture").is_none()))
		.collect();
	assert!(!here.is_empty());
	for case in here {
		assert_eq!(ran(&driver, 1, "deployments", case), Ran::Passed, "{}", case["description"]);
	}
}
