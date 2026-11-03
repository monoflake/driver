//! Capacity, connection recovery and commits surviving an unclosed process.

#![cfg(test)]

mod common;

use common::{Directory, database, input, output};
use driver_machine_database::{Database, FILE, Open, Statements, Unexecuted};
use serde_json::json;

#[test]
fn capacity_can_grow_and_shrink_and_a_full_batch_changes_nothing() {
	let (directory, database) = database(65536);
	output(&database, &["CREATE TABLE t (b BLOB)"]);
	let too_large =
		input(&["INSERT INTO t VALUES (x'01')", "INSERT INTO t VALUES (zeroblob(131072))"]);
	assert_eq!(database.execute(&too_large), Err(Unexecuted::StorageFull));
	assert_eq!(
		output(&database, &["SELECT count(*) FROM t"])["results"][0]["rows"][0][0]["value"],
		0
	);
	database.resize(1024 * 1024).unwrap();
	output(&database, &["INSERT INTO t VALUES (zeroblob(131072))"]);
	database.resize(65536).unwrap();
	assert_eq!(
		output(&database, &["SELECT length(b) FROM t"])["results"][0]["rows"][0][0]["value"],
		131072
	);
	assert_eq!(
		database.execute(&input(&["INSERT INTO t VALUES (zeroblob(131072))"])),
		Err(Unexecuted::StorageFull)
	);
	drop(database);
	let database = Database::open(directory.path(), 65536).unwrap();
	assert_eq!(
		database.execute(&input(&["INSERT INTO t VALUES (zeroblob(131072))"])),
		Err(Unexecuted::StorageFull)
	);
	database.resize(1024 * 1024).unwrap();
	output(&database, &["INSERT INTO t VALUES (zeroblob(131072))"]);
}

#[test]
fn capacity_rounds_down_to_whole_pages() {
	let (_directory, database) = database(65536 + 4095);
	output(&database, &["CREATE TABLE t (b BLOB)"]);
	assert_eq!(
		database.execute(&input(&["INSERT INTO t VALUES (zeroblob(64000))"])),
		Err(Unexecuted::StorageFull)
	);
	database.resize(65536 + 4096).unwrap();
	output(&database, &["INSERT INTO t VALUES (zeroblob(64000))"]);
	assert!(database.resize(0).is_err());
}

#[test]
fn changed_is_not_stale_and_excludes_trigger_writes() {
	let (_directory, database) = database(1024 * 1024);
	let result = output(
		&database,
		&[
			"CREATE TABLE t (n)",
			"CREATE TABLE log (n)",
			"CREATE TRIGGER logged AFTER INSERT ON t BEGIN INSERT INTO log VALUES (new.n); INSERT INTO log VALUES (new.n); END",
			"INSERT INTO t VALUES (1), (2)",
			"CREATE TABLE other (n)",
			"UPDATE t SET n = 3 WHERE 0",
			"INSERT INTO t VALUES (4) RETURNING n",
			"SELECT * FROM log",
		],
	);
	let changed: Vec<_> =
		result["results"].as_array().unwrap().iter().map(|r| r["changed"].clone()).collect();
	assert_eq!(changed, json!([0, 0, 0, 2, 0, 0, 1, 0]).as_array().unwrap().clone());
}

#[test]
fn sqlite_rollback_and_fail_conflicts_leave_no_partial_write() {
	let (_directory, database) = database(1024 * 1024);
	output(&database, &["CREATE TABLE t (n INTEGER UNIQUE)"]);
	for sql in ["INSERT OR FAIL INTO t VALUES (1), (1)", "INSERT OR ROLLBACK INTO t VALUES (1), (1)"]
	{
		assert!(matches!(database.execute(&input(&[sql])), Err(Unexecuted::Constraint(_))));
		assert_eq!(
			output(&database, &["SELECT count(*) FROM t"])["results"][0]["rows"][0][0]["value"],
			0
		);
	}
	assert_eq!(output(&database, &[]), json!({"results": []}));
}

#[test]
fn answered_write_exit() {
	let Some(path) = std::env::var_os("DATABASE_EXIT_DIRECTORY") else { return };
	let database = Database::open(std::path::Path::new(&path), 1024 * 1024).unwrap();
	output(&database, &["CREATE TABLE t (n)", "INSERT INTO t VALUES (42)"]);
	std::process::exit(0);
}

#[test]
fn answered_commit_recovers_from_wal_after_process_exit() {
	let directory = Directory::new();
	let status = std::process::Command::new(std::env::current_exe().unwrap())
		.args(["--exact", "answered_write_exit"])
		.env("DATABASE_EXIT_DIRECTORY", directory.path())
		.status()
		.unwrap();
	assert!(status.success());
	assert!(directory.path().join(format!("{FILE}-wal")).metadata().unwrap().len() > 0);
	let database = Database::open(directory.path(), 1024 * 1024).unwrap();
	assert_eq!(output(&database, &["SELECT n FROM t"])["results"][0]["rows"][0][0]["value"], 42);
	drop(database);
	let connection = rusqlite::Connection::open(directory.path().join(FILE)).unwrap();
	let journal: String =
		connection.pragma_query_value(None, "journal_mode", |row| row.get(0)).unwrap();
	assert_eq!(journal, "wal");
}
