//! A database in its own directory, and the contract's JSON at its boundary.

#![cfg(test)]
#![allow(dead_code, reason = "each test uses its own part of these helpers")]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

use driver_machine_database::{Database, Open, Statements, Unexecuted};
use envelope::{Encoded, contracts::DatabaseExecute};
use serde_json::{Value, json};

static MADE: AtomicU32 = AtomicU32::new(0);

pub struct Directory(PathBuf);

impl Directory {
	pub fn new() -> Self {
		let n = MADE.fetch_add(1, Ordering::Relaxed);
		let path = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
			.join(format!("driver-machine-database-{}-{n}", std::process::id()));
		std::fs::create_dir_all(&path).unwrap();
		Self(path)
	}

	pub fn path(&self) -> &Path {
		&self.0
	}
}

impl Drop for Directory {
	fn drop(&mut self) {
		std::fs::remove_dir_all(&self.0).unwrap();
	}
}

pub fn database(capacity: u64) -> (Directory, Database) {
	let directory = Directory::new();
	let database = Database::open(directory.path(), capacity).unwrap();
	(directory, database)
}

pub fn input(sql: &[&str]) -> DatabaseExecute {
	DatabaseExecute::from_json(
		&json!({"statements": sql.iter().map(|sql| json!({"sql": sql})).collect::<Vec<_>>()}),
	)
	.unwrap()
}

pub fn output(database: &Database, sql: &[&str]) -> Value {
	database.execute(&input(sql)).unwrap().to_json()
}

pub fn answer(database: &Database, input: &DatabaseExecute) -> Value {
	match database.execute(input) {
		Ok(output) => json!({"output": output.to_json()}),
		Err(error) => {
			let (failure, reason) = match error {
				Unexecuted::Invalid(_) => ("rejected", "invalid"),
				Unexecuted::Constraint(_) => ("rejected", "constraint"),
				Unexecuted::BeyondLimit(_) => ("rejected", "beyond_limit"),
				Unexecuted::BeyondRange(_) => ("rejected", "beyond_range"),
				Unexecuted::StorageFull => ("unavailable", "storage_full"),
				Unexecuted::Overloaded(_) => ("unavailable", "overloaded"),
				Unexecuted::Fault(f) => panic!("unexpected fault {f:?}"),
			};
			json!({"failure": failure, "reason": reason})
		}
	}
}
