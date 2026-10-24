//! The kinds' samples run against the program, each case on a binding of its own, RFC p8e8k, its
//! btrfs `volume/tests/btrfs.sh`. A case that needs a machine is told apart by its steps and held
//! to what it answers here.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use common::{Started, answered, sample};
use driver_machine_object::MOST;
use envelope::Encoded as _;
use envelope::contracts::ObjectWrite;
use serde_json::{Value, json};

const MANAGEMENT: [&str; 3] = [
	"../platform/tests/kinds/management/lists.json",
	"../platform/tests/kinds/management/graces.json",
	"../platform/tests/kinds/management/ends.json",
];
const DEPLOYMENTS: &str = "../platform/tests/kinds/deployments/lifecycle.json";
const OBJECTS: [&str; 3] = [
	"../platform/tests/kinds/objects/listing.json",
	"../platform/tests/kinds/objects/ranges.json",
	"../platform/tests/kinds/objects/writes.json",
];

/// The bucket a case of the object kind is given where it names no capacity, room for an object at
/// the contract's bound and more.
const BUCKET: u64 = 64 * 1024 * 1024;

/// `$bytes` of a length, each byte the step's index, since only how many is held to here.
fn filled(step: usize, length: usize) -> Vec<u8> {
	vec![u8::try_from(step % 256).unwrap(); length]
}

/// A `$bytes` length, a number or the content's bound and how far past it.
fn length(spec: &Value) -> usize {
	if let Some(n) = spec.as_u64() {
		return usize::try_from(n).unwrap();
	}
	assert_eq!(spec["bound"], "content", "a $bytes length is a number or the bound content");
	MOST + usize::try_from(spec["plus"].as_u64().unwrap()).unwrap()
}

/// An input with each `$use` given what was captured, and a `content` of `$bytes` filled and
/// written as the contract writes bytes.
fn resolved(step: usize, input: &Value, captured: &BTreeMap<String, Value>) -> Value {
	let mut input = input.clone();
	let mut bytes = None;
	if let Some(fields) = input.as_object_mut() {
		for value in fields.values_mut() {
			if let Some(name) = value.get("$use").and_then(Value::as_str) {
				*value = captured[name].clone();
			} else if let Some(spec) = value.get("$bytes") {
				bytes = Some(filled(step, length(&spec["length"])));
			}
		}
	}
	if let Some(content) = bytes {
		let name = input["name"].as_str().unwrap().to_owned();
		input["content"] = ObjectWrite { name, content }.to_json()["content"].clone();
	}
	input
}

/// Whether an answer is as a step expects, `$capture` keeping what it stands for.
fn captured(expect: &Value, answer: &Value, captures: &mut BTreeMap<String, Value>) -> bool {
	fn kept(expected: &Value, actual: &Value, captures: &mut BTreeMap<String, Value>) -> bool {
		match (expected, actual) {
			(Value::Object(e), _) if e.contains_key("$capture") => {
				captures.insert(e["$capture"].as_str().unwrap().to_owned(), actual.clone());
				true
			}
			(Value::Object(e), Value::Object(a)) if !e.contains_key("$any") => {
				e.iter().all(|(k, v)| match a.get(k) {
					Some(w) => kept(v, w, captures),
					None => common::absent(v),
				})
			}
			_ => common::matches(expected, actual),
		}
	}
	match expect.get("output") {
		Some(output) => answer["status"] == "success" && kept(output, &answer["data"], captures),
		None => answered(expect, answer),
	}
}

/// One case's steps on its own binding, each step called again until it matches or its `within`
/// has passed, and every one held to what it expects.
fn ran(driver: &Started, binding: u32, interface: &str, case: &Value) {
	let description = case["description"].as_str().unwrap();
	let mut captures = BTreeMap::new();
	for (index, step) in case["steps"].as_array().unwrap().iter().enumerate() {
		let operation = step["call"].as_str().unwrap();
		let input = resolved(index, &step["input"], &captures);
		let within = Duration::from_millis(step["within"].as_u64().unwrap_or(0));
		let until = Instant::now() + within;
		let answer = loop {
			let (_, answer) = driver.call(binding, interface, operation, &input);
			if captured(&step["expect"], &answer, &mut captures) || Instant::now() >= until {
				break answer;
			}
			std::thread::sleep(Duration::from_millis(100));
		};
		let shown = answer.to_string();
		let shown = shown.get(..400).unwrap_or(&shown);
		assert!(
			captured(&step["expect"], &answer, &mut captures),
			"{description}: step {index}, {operation}, answered {shown}"
		);
	}
}

#[test]
fn every_management_sample_holds() {
	let cases: Vec<Value> =
		MANAGEMENT.iter().flat_map(|file| sample(file)["cases"].as_array().unwrap().clone()).collect();
	assert_eq!(cases.len(), 12);
	let driver = Started::with("management", u32::try_from(cases.len()).unwrap());
	for (binding, case) in (1..).zip(&cases) {
		ran(&driver, binding, "management", case);
	}
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
		ran(&driver, 1, "deployments", case);
	}
}

#[test]
fn every_object_sample_holds_on_a_bucket_its_list_makes() {
	let cases: Vec<Value> =
		OBJECTS.iter().flat_map(|file| sample(file)["cases"].as_array().unwrap().clone()).collect();
	assert_eq!(cases.len(), 12);
	let driver = Started::with("objects", u32::try_from(cases.len()).unwrap());
	for (binding, case) in (1..).zip(&cases) {
		let size = case["given"]["size"].as_u64().unwrap_or(BUCKET);
		let item = json!({
			"id": 1,
			"capacity": { "name": "object", "size": size },
			"credentials": ["af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"],
		});
		let (_, applied) =
			driver.call(binding, "management", "apply", &json!({ "generation": 1, "items": [item] }));
		assert_eq!(applied["data"], json!({ "generation": 1 }), "{applied}");
		ran(&driver, binding, "object", case);
	}
}

#[test]
fn a_binding_with_no_bucket_holds_no_object_and_has_room_for_none() {
	let driver = Started::with("bucketless", 1);
	let input = json!({ "name": "a", "content": "aGVsbG8" });
	let (status, answer) = driver.call(1, "object", "write", &input);
	assert_eq!((status, &answer["reason"]), (503, &json!("storage_full")));
	let (_, listed) = driver.call(1, "object", "list", &json!({ "prefix": "" }));
	assert_eq!(listed["data"], json!({ "objects": [] }));
	let (_, read) = driver.call(1, "object", "read", &json!({ "name": "a" }));
	assert_eq!(read["reason"], "not_found");
}

#[test]
fn a_bucket_unmade_takes_its_objects_and_a_bucket_made_again_holds_none() {
	let driver = Started::with("unmade", 1);
	let item = |size: u64| {
		json!({
			"id": 1,
			"capacity": { "name": "object", "size": size },
			"credentials": ["af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"],
		})
	};
	driver.call(1, "management", "set_policy", &json!({ "generation": 1, "grace": 0 }));
	driver.call(1, "management", "apply", &json!({ "generation": 1, "items": [item(1024)] }));
	let write = json!({ "name": "a", "content": "aGVsbG8" });
	assert_eq!(driver.call(1, "object", "write", &write).1["status"], "success");
	let bucket = driver.mount().join("buckets/1/1");
	assert!(bucket.is_dir());
	driver.call(1, "management", "apply", &json!({ "generation": 2, "items": [] }));
	assert!(!bucket.exists());
	assert_eq!(driver.call(1, "object", "write", &write).1["reason"], "storage_full");
	driver.call(1, "management", "apply", &json!({ "generation": 3, "items": [item(1024)] }));
	let (_, read) = driver.call(1, "object", "read", &json!({ "name": "a" }));
	assert_eq!(read["reason"], "not_found");
}

#[test]
fn a_bucket_and_a_volume_are_found_again_after_a_restart() {
	let driver = Started::with("restarted", 1);
	let items = json!([
		{
			"id": 1,
			"capacity": { "name": "object", "size": 1024 },
			"credentials": ["af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"],
		},
		{
			"id": 2,
			"capacity": { "name": "volume", "size": 4096 },
			"credentials": ["af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"],
		},
	]);
	driver.call(1, "management", "apply", &json!({ "generation": 1, "items": items }));
	let write = json!({ "name": "a", "content": "aGVsbG8" });
	assert_eq!(driver.call(1, "object", "write", &write).1["status"], "success");
	let (_, before) = driver.call(1, "management", "describe", &json!({}));
	let volume = driver.mount().join("volumes/1/2");
	assert_eq!(before["data"]["items"][1]["state"]["address"], json!(volume.display().to_string()));
	let driver = driver.restarted();
	let (_, after) = driver.call(1, "management", "describe", &json!({}));
	assert_eq!(after, before);
	let (_, read) = driver.call(1, "object", "read", &json!({ "name": "a" }));
	assert_eq!(read["data"]["content"], "aGVsbG8");
}
