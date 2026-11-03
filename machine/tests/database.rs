//! Database item lifecycle and HTTP refusals without executing or resizing the database block.

#![cfg(test)]

mod common;

use common::Started;
use driver_machine_database::{FILE, ROOM};
use serde_json::{Value, json};

fn item(id: u32) -> Value {
	json!({ "id": id, "capacity": { "name": "database", "size": 1048576 },
		"credentials": ["00".repeat(32)] })
}

fn apply(driver: &Started, generation: u32, items: Vec<Value>) {
	let input = json!({ "generation": generation, "items": items });
	let (status, answer) = driver.call(1, "management", "apply", &input);
	assert_eq!(status, 200, "{answer}");
}

fn describe(driver: &Started) -> Value {
	let (status, answer) = driver.call(1, "management", "describe", &json!({}));
	assert_eq!(status, 200, "{answer}");
	answer["data"].clone()
}

#[test]
fn a_database_is_made_reopened_unmade_and_a_second_item_is_refused() {
	let driver = Started::with("database", 1);
	apply(&driver, 1, vec![item(1), item(2)]);
	let held = describe(&driver);
	assert_eq!(held["items"][0]["state"]["name"], "made");
	assert!(held["items"][0]["state"]["address"].is_string());
	assert_eq!(held["items"][1]["state"]["name"], "failed");
	assert_eq!(held["items"][1]["state"]["reason"], "beyond_host");
	assert!(held["kinds"].as_array().unwrap().contains(&json!("database")));
	let at = driver.mount().join("databases/1/1");
	assert!(at.join(FILE).is_file());
	assert!(!driver.mount().join("databases/1/2").exists());
	let asked = std::fs::read_to_string(driver.mount().parent().unwrap().join("asked")).unwrap();
	assert!(asked.contains(&format!("qgroup limit {} ", 1048576 + ROOM)), "{asked}");
	// An unchanged item takes no resize path, including after the process starts again.
	apply(&driver, 2, vec![item(1)]);
	let driver = driver.restarted();
	assert_eq!(describe(&driver)["items"][0]["state"]["name"], "made");
	apply(&driver, 3, vec![item(1)]);
	let (status, answer) = driver.call(1, "database", "rewind", &json!({ "to": 0 }));
	assert_eq!(status, 500, "{answer}");
	assert_eq!(answer["reason"], "fault");
	assert_eq!(
		answer["message"],
		"a machine serves execute alone until plan item machine-rewind-by-wal"
	);
	apply(&driver, 4, vec![]);
	assert_eq!(driver.call(1, "management", "end", &json!({ "id": 2 })).0, 200);
	assert!(at.join(FILE).is_file(), "ending the refused item keeps the held database");
	assert_eq!(driver.call(1, "management", "end", &json!({ "id": 1 })).0, 200);
	assert!(!at.exists());
	assert!(describe(&driver)["items"].as_array().unwrap().is_empty());
	let (status, answer) = driver.call(1, "database", "execute", &json!({ "statements": [] }));
	assert_eq!(status, 503, "{answer}");
	assert_eq!(answer["reason"], "storage_full");
	assert_eq!(answer["message"], "the binding holds no database");
	apply(&driver, 5, vec![item(2)]);
	assert_eq!(describe(&driver)["items"][0]["state"]["name"], "made");
}

#[test]
fn a_database_volume_missing_at_start_is_failed_then_made_again() {
	let driver = Started::with("database-missing", 1);
	apply(&driver, 1, vec![item(1)]);
	let at = driver.mount().join("databases/1/1");
	std::fs::remove_dir_all(&at).unwrap();
	let driver = driver.restarted();
	let held = describe(&driver);
	assert_eq!(held["items"][0]["state"]["name"], "failed");
	assert_eq!(held["items"][0]["state"]["reason"], "fault");
	assert!(!at.exists(), "start must not replace the missing volume");
	apply(&driver, 2, vec![item(1)]);
	assert_eq!(describe(&driver)["items"][0]["state"]["name"], "made");
	assert!(at.join(FILE).is_file());
}

#[test]
fn database_calls_without_an_item_refuse_execute_and_rewind_and_bound_the_body() {
	let driver = Started::with("database-refused", 1);
	let (status, answer) = driver.call(1, "database", "execute", &json!({ "statements": [] }));
	assert_eq!(status, 503, "{answer}");
	assert_eq!(answer["reason"], "storage_full");
	assert_eq!(answer["message"], "the binding holds no database");
	let (status, answer) = driver.call(1, "database", "rewind", &json!({ "to": 0 }));
	assert_eq!(status, 500, "{answer}");
	assert_eq!(answer["reason"], "fault");
	assert_eq!(
		answer["message"],
		"a machine serves execute alone until plan item machine-rewind-by-wal"
	);
	let text = " ".repeat(2 * 1024 * 1024);
	let input = json!({ "statements": [{ "sql": text }] });
	let (status, answer) = driver.call(1, "database", "execute", &input);
	assert_eq!(status, 400, "{answer}");
	assert_eq!(answer["reason"], "malformed");
	assert_eq!(answer["message"], "a call's body is at most 2097152 bytes");
}
