//! The database samples run directly against one connection in a directory for each case.

#![cfg(test)]

mod common;

use std::path::PathBuf;

use driver_machine_database::STATEMENT;
use envelope::{
	Encoded,
	contracts::{DatabaseExecute, DatabaseValue},
};
use serde_json::Value;

const SAMPLES: [&str; 3] = [
	"../platform/tests/kinds/databases/statements.json",
	"../platform/tests/kinds/databases/batches.json",
	"../platform/tests/kinds/databases/limits.json",
];

fn resolved(input: &Value, description: &str, step: usize) -> DatabaseExecute {
	let mut json = input.clone();
	for statement in json["statements"].as_array_mut().unwrap() {
		if let Some(spec) = statement["sql"].get("$text") {
			assert_eq!(spec["length"]["bound"], "statement");
			let length = STATEMENT + usize::try_from(spec["length"]["plus"].as_u64().unwrap()).unwrap();
			let mut text = spec["start"].as_str().unwrap().to_owned();
			text.extend(std::iter::repeat_n(' ', length - text.len()));
			statement["sql"] = Value::String(text);
		}
		if let Some(parameters) = statement.get_mut("parameters").and_then(Value::as_array_mut) {
			for parameter in parameters {
				if parameter["value"].get("$bytes").is_some() {
					parameter["value"] = Value::String(String::new());
				}
			}
		}
	}
	let mut result = DatabaseExecute::from_json(&json).unwrap();
	for (i, statement) in result.statements.iter_mut().enumerate() {
		for (j, parameter) in statement.parameters.iter_mut().flatten().enumerate() {
			if let Some(spec) = input["statements"][i]["parameters"][j]["value"].get("$bytes") {
				let length = usize::try_from(spec["length"].as_u64().unwrap()).unwrap();
				let mut hasher = blake3::Hasher::new();
				hasher
					.update(format!("{description}/{step}/statements/{i}/parameters/{j}/value").as_bytes());
				let mut value = vec![0; length];
				hasher.finalize_xof().fill(&mut value);
				*parameter = DatabaseValue::Bytes { value };
			}
		}
	}
	result
}

#[test]
fn every_database_sample_holds() {
	let mut count = 0;
	for path in SAMPLES {
		let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..").join(path);
		let sample: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
		assert_eq!(sample["interface"], "database");
		for case in sample["cases"].as_array().unwrap() {
			let description = case["description"].as_str().unwrap();
			let (_directory, database) =
				common::database(case["given"]["size"].as_u64().unwrap_or(8 * 1024 * 1024));
			for (index, step) in case["steps"].as_array().unwrap().iter().enumerate() {
				assert_eq!(step["call"], "execute");
				let answer = common::answer(&database, &resolved(&step["input"], description, index));
				assert_eq!(answer, step["expect"], "{description}, step {index}");
			}
			count += 1;
		}
	}
	assert_eq!(count, 9);
}
