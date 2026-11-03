//! Tenant SQL cannot escape the database or the driver's transaction.

#![cfg(test)]

mod common;

use common::{database, input, output};
use driver_machine_database::{STATEMENT, Statements, Unexecuted};
use envelope::{Encoded, contracts::DatabaseExecute};
use serde_json::json;

#[test]
fn tenant_cannot_control_files_transactions_or_connection() {
	let (directory, database) = database(1024 * 1024);
	output(&database, &["CREATE TABLE t (n INTEGER)"]);
	let escaped = directory.path().join("escaped.sqlite");
	let attach = format!("ATTACH '{}' AS other", escaped.display());
	let vacuum = format!("VACUUM INTO '{}'", escaped.display());
	for sql in [
		attach.as_str(),
		vacuum.as_str(),
		"SELECT load_extension('anything')",
		"SELECT readfile('/etc/passwd')",
		"SELECT writefile('/tmp/forbidden', 'x')",
		"SELECT edit('anything')",
		"BEGIN",
		"COMMIT",
		"END",
		"ROLLBACK",
		"SAVEPOINT s",
		"RELEASE s",
		"ROLLBACK TO s",
		"PRAGMA max_page_count = 100000",
		"PRAGMA journal_mode = OFF",
		"PRAGMA synchronous = OFF",
		"PRAGMA writable_schema = ON",
		"PRAGMA temp_store_directory = '/tmp'",
		"PRAGMA page_size",
		"PRAGMA optimize",
		"SELECT * FROM pragma_table_info('t')",
		"CREATE VIRTUAL TABLE v USING fts5(x)",
	] {
		let answer = database.execute(&input(&["INSERT INTO t VALUES (1)", sql]));
		assert!(matches!(answer, Err(Unexecuted::Invalid(_))), "{sql} answered {answer:?}");
		assert_eq!(
			output(&database, &["SELECT count(*) FROM t"])["results"][0]["rows"][0][0]["value"],
			0
		);
		assert!(!escaped.exists());
	}
}

#[test]
fn tails_parameters_and_integer_failures_roll_back() {
	let (_directory, database) = database(1024 * 1024);
	output(&database, &["CREATE TABLE t (n INTEGER)"]);
	for sql in [
		"",
		"-- comment only",
		";",
		"SELECT 1; SELECT 2",
		"SELECT 1; invalid",
		"SELECT ?",
		"SELECT ?1, ?2",
		"SELECT 1\0; INSERT INTO t VALUES (2)",
	] {
		let answer = database.execute(&input(&["INSERT INTO t VALUES (1)", sql]));
		assert!(matches!(answer, Err(Unexecuted::Invalid(_))), "{sql:?} answered {answer:?}");
	}
	let extra = DatabaseExecute::from_json(
		&json!({"statements": [{"sql": "SELECT 1", "parameters": [{"kind": "null"}]}]}),
	)
	.unwrap();
	assert!(matches!(database.execute(&extra), Err(Unexecuted::Invalid(_))));
	for sql in [
		"SELECT 9007199254740992",
		"SELECT -9007199254740992",
		"INSERT INTO t VALUES (9007199254740992) RETURNING n",
	] {
		assert!(matches!(
			database.execute(&input(&["INSERT INTO t VALUES (1)", sql])),
			Err(Unexecuted::BeyondRange(_))
		));
	}
	assert_eq!(
		output(&database, &["SELECT count(*) FROM t"])["results"][0]["rows"][0][0]["value"],
		0
	);
}

#[test]
fn statement_bound_is_bytes_and_precedes_the_whole_batch() {
	let (_directory, database) = database(1024 * 1024);
	let mut bound = "SELECT 1".to_owned();
	bound.extend(std::iter::repeat_n(' ', STATEMENT - bound.len()));
	output(&database, &[&bound]);
	bound.push(' ');
	assert!(matches!(
		database.execute(&input(&["invalid", &bound])),
		Err(Unexecuted::BeyondLimit(_))
	));
	let unicode = format!("SELECT '{}'", "é".repeat(STATEMENT / 2));
	assert!(unicode.chars().count() < STATEMENT);
	assert!(matches!(database.execute(&input(&[&unicode])), Err(Unexecuted::BeyondLimit(_))));
	assert!(matches!(
		database.execute(&input(&["CREATE TABLE absent (n)", &bound])),
		Err(Unexecuted::BeyondLimit(_))
	));
	assert!(matches!(
		database.execute(&input(&["SELECT * FROM absent"])),
		Err(Unexecuted::Invalid(_))
	));
}
