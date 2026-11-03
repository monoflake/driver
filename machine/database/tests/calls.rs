//! Atomic call steps and the protocol's retained status.

#![cfg(test)]

mod common;

use std::time::{SystemTime, UNIX_EPOCH};

use common::{database, input, output};
use driver_machine_database::{
	Database, DatabaseStatusAnswer, FILE, ID_LIFE, STATUS_RETENTION, Statements, Unexecuted,
};
use envelope::{Encoded, contracts::DatabaseExecute};
use serde_json::json;

fn now() -> u64 {
	u64::try_from(SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()).unwrap()
}

fn call(id: &str, sequence: u32, expires: u64, last: bool, sql: &[&str]) -> DatabaseExecute {
	let mut value = input(sql).to_json();
	value["call"] = json!({"id": id, "sequence": sequence, "expires": expires, "last": last});
	DatabaseExecute::from_json(&value).unwrap()
}

fn found(database: &Database, id: &str) -> serde_json::Value {
	let DatabaseStatusAnswer::Found(steps) = database.status(id).unwrap() else {
		panic!("expected committed steps");
	};
	steps.to_json()
}

fn signed(id: u64) -> i64 {
	i64::from_ne_bytes(id.to_ne_bytes())
}

#[test]
fn batches_record_ordered_sequences_and_the_last_step() {
	let (_directory, database) = database(1024 * 1024);
	let id = format!("{:016x}", now() << 16);
	let expires = now() + ID_LIFE;
	database.execute(&call(&id, 2, expires, false, &["CREATE TABLE t (n INTEGER)"])).unwrap();
	assert_eq!(
		found(&database, &id),
		json!({"committed": [2], "expires": expires, "finished": false})
	);
	database.execute(&call(&id, 1, expires, true, &["INSERT INTO t VALUES (1)"])).unwrap();
	assert_eq!(
		found(&database, &id),
		json!({"committed": [1, 2], "expires": expires, "finished": true})
	);
}

#[test]
fn failed_batch_records_nothing_and_rolls_back_statements() {
	let (_directory, database) = database(1024 * 1024);
	output(&database, &["CREATE TABLE t (n INTEGER UNIQUE)"]);
	let id = format!("{:016x}", now() << 16);
	let result = database.execute(&call(
		&id,
		0,
		now() + ID_LIFE,
		true,
		&["INSERT INTO t VALUES (1)", "INSERT INTO t VALUES (1)"],
	));
	assert!(matches!(result, Err(Unexecuted::Constraint(_))));
	assert!(matches!(database.status(&id), Ok(DatabaseStatusAnswer::NotFound)));
	assert_eq!(output(&database, &["SELECT n FROM t"])["results"][0]["rows"], json!([]));
}

#[test]
fn expired_call_changes_nothing_before_begin() {
	let (directory, database) = database(1024 * 1024);
	output(&database, &["CREATE TABLE t (n INTEGER)"]);
	let before = output(&database, &["SELECT n FROM t"]);
	let other = rusqlite::Connection::open(directory.path().join(FILE)).unwrap();
	other.execute_batch("BEGIN IMMEDIATE").unwrap();
	let id = format!("{:016x}", now() << 16);
	assert!(matches!(
		database.execute(&call(&id, 0, now() - 1, true, &["INSERT INTO t VALUES (1)"])),
		Err(Unexecuted::Expired)
	));
	other.execute_batch("ROLLBACK").unwrap();
	assert_eq!(output(&database, &["SELECT n FROM t"]), before);
	assert!(matches!(database.status(&id), Ok(DatabaseStatusAnswer::NotFound)));
}

#[test]
fn malformed_ids_are_refused_on_execute_and_status() {
	let (directory, database) = database(1024 * 1024);
	let other = rusqlite::Connection::open(directory.path().join(FILE)).unwrap();
	other.execute_batch("BEGIN IMMEDIATE").unwrap();
	for id in ["0123456789abcde", "0123456789ABCDEf"] {
		assert!(matches!(
			database.execute(&call(id, 0, now() + ID_LIFE, false, &[])),
			Err(Unexecuted::Malformed(_))
		));
		assert!(matches!(database.status(id), Err(Unexecuted::Malformed(_))));
	}
	other.execute_batch("ROLLBACK").unwrap();
}

#[test]
fn tenant_cannot_name_the_call_table() {
	let (_directory, database) = database(1024 * 1024);
	for sql in [
		"SELECT * FROM driver_calls",
		"SELECT * FROM DRIVER_CALLS",
		"DELETE FROM driver_calls",
		"DROP TABLE driver_calls",
		"CREATE INDEX x ON driver_calls (expires)",
		"CREATE TEMP TABLE driver_calls (n INTEGER)",
	] {
		assert!(matches!(database.execute(&input(&[sql])), Err(Unexecuted::Invalid(_))), "{sql}");
	}
}

#[test]
fn old_ids_are_forgotten_with_or_without_rows_and_execute_sweeps_them() {
	let (directory, database) = database(1024 * 1024);
	let old = (now() - STATUS_RETENTION - 60 * 60 * 1000) << 16;
	let id = format!("{old:016x}");
	assert!(matches!(database.status(&id), Ok(DatabaseStatusAnswer::Forgotten)));
	let other = rusqlite::Connection::open(directory.path().join(FILE)).unwrap();
	other
		.execute(
			"INSERT INTO driver_calls VALUES (?1, 0, ?2, 1)",
			rusqlite::params![signed(old), signed(now() + ID_LIFE)],
		)
		.unwrap();
	assert!(matches!(database.status(&id), Ok(DatabaseStatusAnswer::Forgotten)));
	let fresh = format!("{:016x}", now() << 16);
	assert!(matches!(database.status(&fresh), Ok(DatabaseStatusAnswer::NotFound)));
	database.execute(&input(&[])).unwrap();
	assert_eq!(
		other.query_row("SELECT count(*) FROM driver_calls", [], |row| row.get::<_, u32>(0)).unwrap(),
		0
	);
}

#[test]
fn high_bit_id_round_trips_and_survives_the_sweep() {
	let (directory, database) = database(1024 * 1024);
	let number = (1_u64 << 63) | (now() << 16);
	let id = format!("{number:016x}");
	let expires = now() + ID_LIFE;
	database.execute(&call(&id, 0, expires, true, &[])).unwrap();
	database.execute(&input(&[])).unwrap();
	assert_eq!(
		found(&database, &id),
		json!({"committed": [0], "expires": expires, "finished": true})
	);
	let other = rusqlite::Connection::open(directory.path().join(FILE)).unwrap();
	assert_eq!(
		other.query_row("SELECT id FROM driver_calls", [], |row| row.get::<_, i64>(0)).unwrap(),
		signed(number)
	);
}
