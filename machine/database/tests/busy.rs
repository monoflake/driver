//! A batch meeting another writer's lock changes nothing and says so, RFC 49qyg.

#![cfg(test)]

mod common;

use common::{database, input, output};
use driver_machine_database::{FILE, Statements, Unexecuted};

#[test]
fn a_batch_meeting_another_writer_is_overloaded_and_changes_nothing() {
	let (directory, database) = database(1024 * 1024);
	output(&database, &["CREATE TABLE t (n INTEGER)", "INSERT INTO t VALUES (1)"]);
	let before = output(&database, &["SELECT n FROM t"]);
	let other = rusqlite::Connection::open(directory.path().join(FILE)).unwrap();
	other.execute_batch("BEGIN IMMEDIATE").unwrap();
	let refused = database.execute(&input(&["INSERT INTO t VALUES (2)", "INSERT INTO t VALUES (3)"]));
	assert!(matches!(refused, Err(Unexecuted::Overloaded(_))), "{refused:?}");
	other.execute_batch("ROLLBACK").unwrap();
	assert_eq!(output(&database, &["SELECT n FROM t"]), before);
}
