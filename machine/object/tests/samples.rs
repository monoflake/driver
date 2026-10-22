//! The `object` samples run against a bucket, each case on a bucket of its own given the capacity
//! the case names, its placeholders filled as RFC p8e8k has the runner fill them.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::collections::BTreeMap;
use std::path::PathBuf;

use common::{bucket, call};
use driver_machine_object::MOST;
use serde_json::Value;

/// The samples, by their paths from this repository's root.
const SAMPLES: [&str; 3] = [
	"../platform/tests/kinds/objects/listing.json",
	"../platform/tests/kinds/objects/ranges.json",
	"../platform/tests/kinds/objects/writes.json",
];

/// A sample read as it stands.
fn sample(path: &str) -> Value {
	let file = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..").join(path);
	serde_json::from_slice(&std::fs::read(file).unwrap()).unwrap()
}

/// `$bytes` of a length, the BLAKE3 of the case's description, the step's index and the value's
/// path joined by `/`, read out to the length.
fn filled(description: &str, step: usize, path: &str, length: usize) -> Vec<u8> {
	let mut hasher = blake3::Hasher::new();
	hasher.update(format!("{description}/{step}/{path}").as_bytes());
	let mut bytes = vec![0; length];
	hasher.finalize_xof().fill(&mut bytes);
	bytes
}

/// A `$bytes` length, a number or a bound the contract fixes and how far past it.
fn length(spec: &Value) -> usize {
	if let Some(n) = spec.as_u64() {
		return usize::try_from(n).unwrap();
	}
	assert_eq!(spec["bound"], "content", "a $bytes length is a number or the bound content");
	MOST + usize::try_from(spec["plus"].as_u64().unwrap()).unwrap()
}

/// An input with each `$use` given what was captured, and its `content` of `$bytes` taken out.
fn resolved(
	description: &str,
	step: usize,
	input: &Value,
	captured: &BTreeMap<String, Value>,
) -> (Value, Option<Vec<u8>>) {
	let mut input = input.clone();
	let mut bytes = None;
	if let Some(fields) = input.as_object_mut() {
		for (key, value) in fields.iter_mut() {
			if let Some(name) = value.get("$use").and_then(Value::as_str) {
				*value = captured[name].clone();
			} else if let Some(spec) = value.get("$bytes") {
				bytes = Some(filled(description, step, key, length(&spec["length"])));
				*value = Value::String(String::new());
			}
		}
	}
	(input, bytes)
}

/// Whether a value is as expected, every field it writes and no other, `$capture` keeping one.
fn matches(expected: &Value, actual: &Value, captured: &mut BTreeMap<String, Value>) -> bool {
	match (expected, actual) {
		(Value::Object(e), _) if e.contains_key("$any") => true,
		(Value::Object(e), _) if e.contains_key("$capture") => {
			captured.insert(e["$capture"].as_str().unwrap().to_owned(), actual.clone());
			true
		}
		(Value::Object(e), Value::Object(a)) => {
			e.len() == a.len() && e.iter().all(|(k, v)| a.get(k).is_some_and(|w| matches(v, w, captured)))
		}
		(Value::Array(e), Value::Array(a)) => {
			e.len() == a.len() && e.iter().zip(a).all(|(v, w)| matches(v, w, captured))
		}
		_ => expected == actual,
	}
}

/// One case on a bucket of its own.
fn ran(case: &Value) {
	let description = case["description"].as_str().unwrap();
	let capacity = case["given"]["size"].as_u64();
	let (_directory, bucket) = bucket("sample", capacity);
	let mut captured = BTreeMap::new();
	for (index, step) in case["steps"].as_array().unwrap().iter().enumerate() {
		let operation = step["call"].as_str().unwrap();
		let (input, bytes) = resolved(description, index, &step["input"], &captured);
		let answer = call(&bucket, operation, &input, bytes);
		let expect = &step["expect"];
		let held = match expect.get("output") {
			Some(output) => {
				answer["status"] == "success" && matches(output, &answer["data"], &mut captured)
			}
			None => {
				answer["status"] == "error"
					&& answer["failure"] == expect["failure"]
					&& answer["reason"] == expect["reason"]
			}
		};
		let shown = answer.to_string();
		let shown = shown.get(..400).unwrap_or(&shown);
		assert!(held, "{description}: step {index}, {operation}, answered {shown}");
	}
}

#[test]
fn every_object_sample_holds() {
	let mut count = 0;
	for path in SAMPLES {
		let sample = sample(path);
		assert_eq!(sample["interface"], "object");
		for case in sample["cases"].as_array().unwrap() {
			ran(case);
			count += 1;
		}
	}
	assert_eq!(count, 12);
}
