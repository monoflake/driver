//! The single writer and its atomic batches.

use std::path::Path;
use std::sync::Mutex;

use envelope::contracts::{DatabaseExecute, DatabaseExecuted};

use rusqlite::{Connection, config::DbConfig, hooks::AuthContext};

use crate::{Database, FILE, Fault, Open, STATEMENT, Statements, Unexecuted};

mod policy;
mod statement;

fn fault(error: impl std::fmt::Display) -> Fault {
	Fault(error.to_string())
}

fn capacity(connection: &Connection, bytes: u64) -> Result<(), Fault> {
	let size: u32 =
		connection.pragma_query_value(None, "page_size", |row| row.get(0)).map_err(fault)?;
	let pages = bytes / u64::from(size);
	if pages == 0 {
		return Err(Fault("capacity is smaller than one SQLite page".into()));
	}
	connection.query_row(&format!("PRAGMA max_page_count = {pages}"), [], |_| Ok(())).map_err(fault)
}

impl Open for Database {
	fn open(directory: &Path, bytes: u64) -> Result<Self, Fault> {
		let connection = Connection::open(directory.join(FILE)).map_err(fault)?;
		connection
			.set_db_config(DbConfig::SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER, false)
			.map_err(fault)?;
		connection.pragma_update(None, "journal_mode", "WAL").map_err(fault)?;
		connection.pragma_update(None, "synchronous", "FULL").map_err(fault)?;
		connection.pragma_update(None, "temp_store", "MEMORY").map_err(fault)?;
		capacity(&connection, bytes)?;
		Ok(Self { connection: Mutex::new(connection) })
	}

	fn resize(&self, bytes: u64) -> Result<(), Fault> {
		let connection = self.connection.lock().map_err(fault)?;
		capacity(&connection, bytes)
	}
}

impl Statements for Database {
	fn execute(&self, input: &DatabaseExecute) -> Result<DatabaseExecuted, Unexecuted> {
		if input.statements.iter().any(|statement| statement.sql.len() > STATEMENT) {
			return Err(Unexecuted::BeyondLimit("statement exceeds 100000 UTF-8 bytes".into()));
		}
		let mut connection = self.connection.lock().map_err(|e| Unexecuted::Fault(fault(e)))?;
		connection.execute_batch("BEGIN").map_err(policy::error)?;
		let answer: Result<Vec<_>, Unexecuted> = (|| {
			connection.authorizer(Some(policy::authorize)).map_err(policy::error)?;
			input.statements.iter().map(|s| statement::run(&connection, s)).collect()
		})();
		let removed = connection.authorizer(None::<fn(AuthContext<'_>) -> _>).map_err(policy::error);
		let answer = answer.and_then(|results| removed.map(|()| results));
		match answer {
			Ok(results) => match connection.execute_batch("COMMIT") {
				Ok(()) => Ok(DatabaseExecuted { results, behind: None }),
				Err(error) => {
					rollback(&connection)?;
					// A commit that failed may have reached the file, so busy at it is not certain.
					let refused = policy::error(error);
					Err(if let Unexecuted::Overloaded(words) = refused {
						Unexecuted::Fault(Fault(words))
					} else {
						refused
					})
				}
			},
			Err(error) => {
				rollback(&connection)?;
				Err(error)
			}
		}
	}
}

fn rollback(connection: &Connection) -> Result<(), Unexecuted> {
	if !connection.is_autocommit() {
		connection.execute_batch("ROLLBACK").map_err(|e| Unexecuted::Fault(fault(e)))?;
	}
	Ok(())
}
