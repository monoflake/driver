//! The deployments samples deploying modules, run against the function kind on a fake of the
//! container kind. A `send` reaches workerd running, which no test here has, so it is counted.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::collections::BTreeMap;

use common::{LARGEST, binding, bundle, from_root, functions, hash, hex, json};
use driver_machine_container::{Deployments, Refused};
use envelope::contracts::interface::deployments::{self, Call};
use envelope::contracts::{Failure, REASONS};
use envelope::{Called, Encoded, Operation};
use serde_json::{Value, json};

const SAMPLES: [&str; 3] = [
	"../platform/tests/kinds/deployments/deploys.json",
	"../platform/tests/kinds/deployments/instances.json",
	"../platform/tests/kinds/deployments/lifecycle.json",
];

/// Where each fixture's description is, by its name.
const FIXTURES: &str = "../platform/tests/fixtures";

/// A fixture as the runner gives it, the address it is deployed from, the hash it is deployed
/// under, its form, and what the address serves.
struct Fixture {
	address: String,
	hash: [u8; 32],
	form: String,
	served: Option<Vec<u8>>,
}

/// A fixture built from its description, one `of` another served from nowhere, under a hash not
/// its own, or padded past the artifact the driver takes.
fn fixture(name: &str) -> Fixture {
	let described = json(&from_root(&format!("{FIXTURES}/{name}/fixture.json")));
	let Some(of) = described["of"].as_str() else {
		let bytes = bundle(name);
		let form = described["form"].as_str().unwrap().to_owned();
		return Fixture { address: name.into(), hash: hash(&bytes), form, served: Some(bytes) };
	};
	let base = fixture(of);
	let bytes = base.served.unwrap();
	let address = name.to_owned();
	match (described["served"].as_str(), described.get("padded")) {
		(Some("hash_mismatched"), None) => {
			let hash = hash(&[b"not ".as_slice(), &bytes].concat());
			Fixture { address, hash, form: base.form, served: Some(bytes) }
		}
		(Some("unfetchable"), None) => {
			Fixture { address, hash: base.hash, form: base.form, served: None }
		}
		(None, Some(padded)) => {
			assert_eq!(padded["bound"], "artifact");
			let past = usize::try_from(LARGEST + padded["plus"].as_u64().unwrap()).unwrap();
			let mut bytes = bytes;
			bytes.resize(past, 0);
			Fixture { address, hash: hash(&bytes), form: base.form, served: Some(bytes) }
		}
		other => panic!("{name}: a fixture of another this test does not build, {other:?}"),
	}
}

/// What an operation answered, as a step's `expect` writes it.
fn answered<P: Operation>(result: Result<P::Output, Refused>) -> Value {
	match result {
		Ok(output) => json!({ "output": output.to_json() }),
		Err(refused) => {
			let known = P::REASONS.iter().chain(REASONS).find(|r| r.name == refused.reason);
			let failure = match known.map(|r| r.failure) {
				Some(Failure::Rejected) => "rejected",
				Some(Failure::Unavailable) => "unavailable",
				Some(Failure::Unknown) | None => "unknown",
			};
			json!({ "failure": failure, "reason": refused.reason })
		}
	}
}

/// Whether a value is as a sample expects it, `$any` and `$capture` standing for any value.
fn matches(expected: &Value, actual: &Value) -> bool {
	match (expected, actual) {
		(Value::Object(e), _) if e.contains_key("$any") || e.contains_key("$capture") => true,
		(Value::Object(e), Value::Object(a)) => {
			e.len() == a.len() && e.iter().all(|(k, v)| a.get(k).is_some_and(|w| matches(v, w)))
		}
		(Value::Array(e), Value::Array(a)) => {
			e.len() == a.len() && e.iter().zip(a).all(|(v, w)| matches(v, w))
		}
		_ => expected == actual,
	}
}

/// One case's steps, each call answered as it expects; the sends it passes over, counted.
async fn ran(case: &Value) -> usize {
	let steps = case["steps"].as_array().unwrap();
	let fixtures: BTreeMap<String, Fixture> = steps
		.iter()
		.filter_map(|s| s["fixture"].as_str())
		.map(|name| (name.to_owned(), fixture(name)))
		.collect();
	let served = fixtures
		.values()
		.filter_map(|f| f.served.clone().map(|bytes| (f.address.clone(), bytes)))
		.collect();
	let functions = functions(served);
	let binding = binding();
	let mut sent = 0;
	for (at, step) in steps.iter().enumerate() {
		if step.get("send").is_some() {
			sent += 1;
			continue;
		}
		let mut input = step["input"].clone();
		if let Some(f) = step["fixture"].as_str().map(|name| &fixtures[name]) {
			input["version"] = json!(hex(&f.hash));
			input["form"] = json!(f.form);
			input["artifact"] = json!({ "address": f.address, "hash": hex(&f.hash) });
		}
		let call = Call::from_json(step["call"].as_str().unwrap(), &input).unwrap();
		let answer = match call {
			Call::Deploy(i) => answered::<deployments::Deploy>(functions.deploy(&binding, i).await),
			Call::Stop(i) => answered::<deployments::Stop>(functions.stop(&binding, i).await),
			Call::Resume(i) => answered::<deployments::Resume>(functions.resume(&binding, i).await),
			Call::Describe(i) => answered::<deployments::Describe>(functions.describe(&binding, i).await),
			Call::Delete(i) => answered::<deployments::Delete>(functions.delete(&binding, i).await),
		};
		assert!(
			matches(&step["expect"], &answer),
			"{}, step {at}: expected {}, answered {answer}",
			case["description"],
			step["expect"]
		);
	}
	sent
}

#[tokio::test]
async fn the_deployments_samples_of_modules_hold_but_what_they_send() {
	let mut cases = 0;
	let mut sent = 0;
	for sample in SAMPLES {
		for case in json(&from_root(sample))["cases"].as_array().unwrap() {
			cases += 1;
			sent += ran(case).await;
		}
	}
	assert_eq!((cases, sent), (11, 7));
}
