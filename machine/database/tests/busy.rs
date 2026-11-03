//! A batch meeting another writer's lock waits for it within lockWait, and past it changes nothing
//! and says so, RFC 49qyg.

#![cfg(test)]

mod common;

use std::time::{Duration, Instant};

use common::{database, input, output};
use driver_machine_database::{FILE, LOCK_HOLD, LOCK_WAIT, Statements, Unexecuted};

#[test]
fn a_batch_meeting_another_writer_past_the_wait_is_overloaded_and_changes_nothing() {
	let (directory, database) = database(1024 * 1024);
	output(&database, &["CREATE TABLE t (n INTEGER)", "INSERT INTO t VALUES (1)"]);
	let before = output(&database, &["SELECT n FROM t"]);
	let other = rusqlite::Connection::open(directory.path().join(FILE)).unwrap();
	other.execute_batch("BEGIN IMMEDIATE").unwrap();
	let started = Instant::now();
	let refused = database.execute(&input(&["INSERT INTO t VALUES (2)", "INSERT INTO t VALUES (3)"]));
	let waited = started.elapsed();
	assert!(matches!(refused, Err(Unexecuted::Overloaded(_))), "{refused:?}");
	assert!(waited >= Duration::from_millis(LOCK_WAIT * 9 / 10), "{waited:?}");
	assert!(waited < Duration::from_millis(LOCK_HOLD), "{waited:?}");
	other.execute_batch("ROLLBACK").unwrap();
	assert_eq!(output(&database, &["SELECT n FROM t"]), before);
}

#[test]
fn a_batch_meeting_another_writer_freed_within_the_wait_waits_and_commits() {
	let (directory, database) = database(1024 * 1024);
	output(&database, &["CREATE TABLE t (n INTEGER)"]);
	let path = directory.path().join(FILE);
	let (locked, waiting) = std::sync::mpsc::channel();
	let other = std::thread::spawn(move || {
		let other = rusqlite::Connection::open(path).unwrap();
		other.execute_batch("BEGIN IMMEDIATE").unwrap();
		locked.send(()).unwrap();
		std::thread::sleep(Duration::from_millis(LOCK_WAIT / 4));
		other.execute_batch("INSERT INTO t VALUES (1); COMMIT").unwrap();
	});
	waiting.recv().unwrap();
	output(&database, &["INSERT INTO t VALUES (2)"]);
	other.join().unwrap();
	let rows = output(&database, &["SELECT n FROM t ORDER BY n"]);
	assert_eq!(rows["results"][0]["rows"].as_array().map(Vec::len), Some(2), "{rows}");
}
