//! The connection and its statements, left to the block's implementer.

use std::path::Path;
use std::sync::Mutex;

use envelope::contracts::{DatabaseExecute, DatabaseExecuted};

use crate::{Database, FILE, Fault, Open, Statements, Unexecuted};

impl Open for Database {
	fn open(directory: &Path, _capacity: u64) -> Result<Self, Fault> {
		let connection =
			rusqlite::Connection::open(directory.join(FILE)).map_err(|e| Fault(e.to_string()))?;
		Ok(Self { connection: Mutex::new(connection) })
	}

	fn resize(&self, _capacity: u64) -> Result<(), Fault> {
		drop(self.connection.lock());
		todo!("4elqc")
	}
}

impl Statements for Database {
	fn execute(&self, _input: &DatabaseExecute) -> Result<DatabaseExecuted, Unexecuted> {
		todo!("4elqc")
	}
}
