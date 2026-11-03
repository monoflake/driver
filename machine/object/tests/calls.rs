//! Call steps share the object name's commit and expire independently of the content.

#![cfg(test)]

mod common;

use std::time::{SystemTime, UNIX_EPOCH};

use common::bucket;
use driver_machine_object::{
	CONTENTS, INDEX, MOST, ObjectStatusAnswer, Objects as _, Unwritten, WRITING,
};
use envelope::Bounded as _;
use envelope::contracts::{CallStep, ObjectName, ObjectWrite};

fn now() -> u64 {
	u64::try_from(SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()).unwrap()
}

fn step(time: u64, sequence: u32, last: bool) -> CallStep {
	CallStep {
		id: format!("{:016x}", time << 16),
		sequence,
		expires: envelope::Uint53::new(now() + 60_000).unwrap(),
		last,
	}
}

fn write(call: CallStep) -> ObjectWrite {
	ObjectWrite { name: "a".into(), content: b"content".to_vec(), call: Some(call) }
}

#[test]
fn committed_steps_include_the_last_even_when_the_content_is_unchanged() {
	let (directory, held) = bucket("calls", None);
	let first = step(now(), 2, false);
	held.write(&write(first.clone())).unwrap();
	let ObjectStatusAnswer::Found(status) = held.status(&first.id).unwrap() else { panic!() };
	assert_eq!(status.committed, [2]);
	assert_eq!(status.expires, first.expires);
	assert!(!status.finished);
	let last = CallStep { sequence: 4, last: true, ..first.clone() };
	held.write(&write(last.clone())).unwrap();
	held.write(&write(last)).unwrap();
	drop(held);
	let held =
		<driver_machine_object::Bucket as driver_machine_object::Open>::open(directory.path(), None)
			.unwrap();
	let ObjectStatusAnswer::Found(status) = held.status(&first.id).unwrap() else { panic!() };
	assert_eq!(status.committed, [2, 4]);
	assert!(status.finished);
}

#[test]
fn a_refused_name_leaves_no_step() {
	let (_directory, held) = bucket("call-refused", Some(0));
	let call = step(now(), 0, true);
	let mut input = write(call.clone());
	input.content = vec![0; MOST + 1];
	assert_eq!(held.write(&input), Err(Unwritten::TooLarge));
	assert_eq!(held.status(&call.id).unwrap(), ObjectStatusAnswer::NotFound);
	input.content = b"content".to_vec();
	assert_eq!(held.write(&input), Err(Unwritten::StorageFull));
	assert_eq!(held.status(&call.id).unwrap(), ObjectStatusAnswer::NotFound);
}

#[test]
fn expired_and_malformed_calls_place_nothing() {
	let (directory, held) = bucket("call-invalid", None);
	let mut call = step(now(), 0, true);
	call.expires = envelope::Uint53::new(now() - 1).unwrap();
	assert_eq!(held.write(&write(call.clone())), Err(Unwritten::Expired));
	assert_eq!(held.status(&call.id).unwrap(), ObjectStatusAnswer::NotFound);
	for id in ["", "0123456789abcde", "0123456789abcdef0", "0123456789abcdeF", "0123456789abcdeg"] {
		let call = CallStep { id: id.into(), ..step(now(), 0, true) };
		assert!(matches!(held.write(&write(call)), Err(Unwritten::Malformed(_))));
	}
	assert_eq!(held.describe(&ObjectName { name: "a".into() }).unwrap().size, None);
	for path in [CONTENTS, WRITING] {
		assert_eq!(std::fs::read_dir(directory.path().join(path)).unwrap().count(), 0);
	}
}

#[test]
fn old_ids_are_forgotten_and_a_write_sweeps_their_rows() {
	let (directory, held) = bucket("call-sweep", None);
	let old = step(now() - 25 * 60 * 60 * 1000, 0, true);
	assert_eq!(held.status(&old.id).unwrap(), ObjectStatusAnswer::Forgotten);
	let fresh = step(now(), 0, true);
	assert_eq!(held.status(&fresh.id).unwrap(), ObjectStatusAnswer::NotFound);
	let index = rusqlite::Connection::open(directory.path().join(INDEX)).unwrap();
	index
		.execute("INSERT INTO calls VALUES (?1, 0, 0, 1)", [i64::from_str_radix(&old.id, 16).unwrap()])
		.unwrap();
	held.write(&write(fresh.clone())).unwrap();
	let count: i64 = index.query_row("SELECT count(*) FROM calls", [], |row| row.get(0)).unwrap();
	assert_eq!(count, 1);
	assert!(matches!(held.status(&fresh.id).unwrap(), ObjectStatusAnswer::Found(_)));
	assert_eq!(held.status(&old.id).unwrap(), ObjectStatusAnswer::Forgotten);
}

#[test]
fn a_failed_name_transaction_rolls_back_the_step() {
	let (directory, held) = bucket("call-rollback", None);
	let index = rusqlite::Connection::open(directory.path().join(INDEX)).unwrap();
	index
		.execute_batch(
			"CREATE TRIGGER refused BEFORE INSERT ON objects BEGIN SELECT RAISE(ABORT, 'refused'); END;",
		)
		.unwrap();
	let call = step(now(), 0, true);
	assert!(matches!(held.write(&write(call.clone())), Err(Unwritten::Fault(_))));
	assert_eq!(held.status(&call.id).unwrap(), ObjectStatusAnswer::NotFound);
	assert_eq!(std::fs::read_dir(directory.path().join(CONTENTS)).unwrap().count(), 0);
}
