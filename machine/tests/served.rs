//! The router, the authentication and the envelope as a call meets them, RFCs vr5lw, 3d3nt and
//! ge55b, each body built from the samples where one covers it.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use codec::Cbor as _;
use common::{Started, matches, sample, token};
use envelope::contracts::interface::management;
use envelope::contracts::{ManagementDescribe, ManagementDescribed};
use envelope::{Answer, Bounded, Encoded, Envelope};
use serde_json::{Value, json};

const LISTS: &str = "../platform/tests/kinds/management/lists.json";
const LIFECYCLE: &str = "../platform/tests/kinds/deployments/lifecycle.json";

/// The first step of the lists' first case, a new binding described, and what it answers.
fn described() -> (Value, Value) {
	let step = &sample(LISTS)["cases"][0]["steps"][0];
	assert_eq!(step["call"], "describe");
	(step["input"].clone(), step["expect"]["output"].clone())
}

fn json_body(interface: &str, operation: &str, input: &Value) -> Vec<u8> {
	serde_json::to_vec(&json!({ "interface": interface, "operation": operation, "input": input }))
		.unwrap()
}

#[test]
fn a_call_with_its_token_is_served_and_logged() {
	let driver = Started::with("served", 1);
	let (input, output) = described();
	let (status, answer) = driver.call(1, "management", "describe", &input);
	assert_eq!(status, 200);
	assert_eq!(answer["status"], "success");
	assert!(matches(&output, &answer["data"]), "{answer}");
	let line = driver.logged("management describe");
	assert!(line.starts_with("management describe success "), "{line}");
	assert!(line.ends_with("ms"), "{line}");
}

#[test]
fn a_bad_token_a_stranger_s_and_none_are_denied_alike() {
	let driver = Started::with("denied", 1);
	let (input, _) = described();
	let body = json_body("management", "describe", &input);
	let json = ("Content-Type", "application/json");
	let other = token(1).replace("1.", "2.");
	let wrong = format!("1.{}", "C".repeat(42) + "A");
	let headers: Vec<Vec<(&str, String)>> = vec![
		vec![],
		vec![("Authorization", format!("Bearer {wrong}"))],
		vec![("Authorization", format!("Bearer {other}"))],
		vec![("Authorization", format!("Basic {}", token(1)))],
		vec![("Authorization", "Bearer 1.short".to_owned())],
	];
	let replies: Vec<_> = headers
		.iter()
		.map(|h| {
			let mut all: Vec<(&str, &str)> = h.iter().map(|(n, v)| (*n, v.as_str())).collect();
			all.push(json);
			all.push(("Accept", "application/json"));
			driver.request("POST", "/management/describe", &all, &body)
		})
		.collect();
	for reply in &replies {
		assert_eq!(reply.status, 403);
		assert_eq!(reply.body, replies[0].body);
	}
	let denied = replies[0].json();
	assert_eq!((&denied["status"], &denied["failure"]), (&json!("error"), &json!("rejected")));
	assert_eq!(denied["reason"], "denied");
	assert!(denied["message"].is_string());
	// Nothing of what it named is told before its token is checked.
	let unknown = driver.request("POST", "/nothing", &[("Accept", "application/json")], b"");
	assert_eq!((unknown.status, unknown.body), (403, replies[0].body.clone()));
	driver.logged("- error rejected denied");
}

#[test]
fn an_unknown_interface_or_operation_is_malformed() {
	let driver = Started::with("unknown", 1);
	let (status, answer) = driver.call(1, "storage", "write", &json!({}));
	assert_eq!((status, &answer["reason"]), (400, &json!("malformed")));
	assert!(answer["message"].as_str().unwrap().contains("management, deployments"));
	let (status, answer) = driver.call(1, "management", "fly", &json!({}));
	assert_eq!((status, &answer["reason"]), (400, &json!("malformed")));
	assert!(answer["message"].as_str().unwrap().contains("operation"), "{answer}");
	let bearer = format!("Bearer {}", token(1));
	let headers = [("Authorization", bearer.as_str()), ("Accept", "application/json")];
	for (method, path) in [("GET", "/management/describe"), ("POST", "/management"), ("POST", "/")] {
		let reply = driver.request(method, path, &headers, b"");
		assert_eq!(
			(reply.status, &reply.json()["reason"]),
			(400, &json!("malformed")),
			"{method} {path}"
		);
	}
}

#[test]
fn a_malformed_body_is_refused_as_malformed() {
	let driver = Started::with("malformed", 1);
	let bearer = format!("Bearer {}", token(1));
	let (input, _) = described();
	let send = |content: &str, body: &[u8]| {
		let headers = [
			("Authorization", bearer.as_str()),
			("Content-Type", content),
			("Accept", "application/json"),
		];
		let reply = driver.request("POST", "/management/describe", &headers, body);
		assert_eq!(reply.status, 400);
		let answer = reply.json();
		assert_eq!((&answer["failure"], &answer["reason"]), (&json!("rejected"), &json!("malformed")));
		answer["message"].as_str().unwrap().to_owned()
	};
	assert!(send("application/json", b"{").contains("not JSON"));
	assert!(send("application/cbor", b"\xff").contains("CBOR"));
	assert!(
		send("text/plain", &json_body("management", "describe", &input)).contains("application/json")
	);
	let without =
		serde_json::to_vec(&json!({ "interface": "management", "operation": "describe" })).unwrap();
	assert!(send("application/json", &without).contains("input"));
	let elsewhere = json_body("management", "end", &json!({ "id": 1 }));
	assert!(
		send("application/json", &elsewhere).contains("the path names describe and the call end")
	);
	let applied = json_body("management", "apply", &json!({ "generation": "1", "items": [] }));
	let headers = [("Authorization", bearer.as_str()), ("Content-Type", "application/json")];
	let reply = driver.request("POST", "/management/apply", &headers, &applied);
	assert_eq!(reply.status, 400);
	assert!(reply.json()["message"].as_str().unwrap().ends_with("at input.generation"));
}

#[test]
fn cbor_is_answered_where_nothing_else_is_asked_and_json_where_accept_asks() {
	let driver = Started::with("forms", 1);
	let (_, output) = described();
	let call =
		Envelope { call: management::Call::Describe(ManagementDescribe {}), capabilities: vec![] };
	let body = call.to_cbor().encode().unwrap();
	let bearer = format!("Bearer {}", token(1));
	let headers = [("Authorization", bearer.as_str()), ("Content-Type", "application/cbor")];
	let reply = driver.request("POST", "/management/describe", &headers, &body);
	assert_eq!(reply.status, 200);
	assert!(reply.typed("application/cbor"), "{}", reply.head);
	let read =
		Answer::<ManagementDescribed>::from_cbor(&codec::Value::decode(&reply.body).unwrap()).unwrap();
	let Answer::Success(described) = read else { panic!("{read:?}") };
	assert_eq!(described.generation.get(), 0);
	assert!(matches(&output, &described.to_json()));
	let asked = [headers[0], headers[1], ("Accept", "application/json")];
	let reply = driver.request("POST", "/management/describe", &asked, &body);
	assert!(reply.typed("application/json"), "{}", reply.head);
	assert!(matches(&output, &reply.json()["data"]));
}

#[test]
fn a_deployment_is_reached_through_the_container_kind() {
	let driver = Started::with("deployments", 1);
	let cases = sample(LIFECYCLE)["cases"].as_array().unwrap().clone();
	let never = cases
		.iter()
		.find(|c| c["steps"].as_array().unwrap().iter().all(|s| s.get("fixture").is_none()));
	let steps = never.unwrap()["steps"].as_array().unwrap();
	let step = steps.iter().find(|s| s["call"] == "describe").unwrap();
	let (status, answer) = driver.call(1, "deployments", "describe", &step["input"]);
	assert_eq!((status, &answer["reason"]), (404, &json!("not_found")));
	driver.logged("deployments describe error rejected not_found");
}

#[test]
fn a_list_and_the_tokens_an_apply_forgot_are_kept_across_a_restart() {
	let driver = Started::with("restart", 2);
	let policy = json!({ "generation": 1, "grace": 3600 });
	assert_eq!(driver.call(1, "management", "set_policy", &policy).0, 200);
	let list = json!({ "generation": 2, "items": [] });
	assert_eq!(driver.call(1, "management", "apply", &list).0, 200);
	// Binding 2 keeps none of its tokens in force, so its one is forgotten though its file stands.
	let none = json!({ "generation": 1, "items": [], "tokens": [] });
	assert_eq!(driver.call(2, "management", "apply", &none).0, 200);
	assert_eq!(driver.call(2, "management", "describe", &json!({})).0, 403);
	let driver = driver.restarted();
	let (status, answer) = driver.call(1, "management", "describe", &json!({}));
	assert_eq!(status, 200);
	let held = json!({ "generation": 2, "policy": 1, "grace": 3600, "items": [] });
	assert!(matches(&held, &answer["data"]), "{}", answer["data"]);
	assert_eq!(driver.call(2, "management", "describe", &json!({})).0, 403);
}

#[test]
fn a_caller_denied_with_a_large_body_reads_its_denial_whole() {
	let driver = Started::with("denied-large", 1);
	// Far past what a socket holds unread, so it is read whole or the connection is reset.
	let body = vec![b' '; 1024 * 1024];
	let headers = [("Content-Type", "application/json"), ("Accept", "application/json")];
	for _ in 0..3 {
		let reply = driver.request("POST", "/management/describe", &headers, &body);
		assert_eq!(reply.status, 403);
		assert_eq!(reply.json()["reason"], "denied");
	}
}
