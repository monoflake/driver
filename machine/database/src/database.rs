//! The single writer and its atomic batches.

use std::ffi::c_int;
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use envelope::{
	Bounded, Uint53,
	contracts::{CallSteps, DatabaseExecute, DatabaseExecuted, DatabaseResult},
};

use rusqlite::{Connection, config::DbConfig, hooks::AuthContext};

use crate::{
	Database, DatabaseStatusAnswer, FILE, Fault, Open, STATEMENT, Statements, Unexecuted,
	calls::{LOCK_HOLD, LOCK_WAIT, STATUS_RETENTION},
	lock::{Held, Lock},
};

mod policy;
mod statement;

/// The virtual machine's steps between two looks at how long a batch has held the lock.
const STEPS: c_int = 1000;

fn fault(error: impl std::fmt::Display) -> Fault {
	Fault(error.to_string())
}

fn overloaded(wait: Duration) -> String {
	format!("the database's lock was not free within lockWait, {} ms", wait.as_millis())
}

fn aborted(hold: Duration) -> Unexecuted {
	Unexecuted::Aborted(format!("the batch held the lock past lockHold, {} ms", hold.as_millis()))
}

impl Database {
	/// The connection within the wait, SQLite's own busy wait given what is left of it.
	fn connection(&self) -> Result<Held<'_, Connection>, Unexecuted> {
		let started = Instant::now();
		let connection = self
			.connection
			.take(self.wait)
			.map_err(Unexecuted::Fault)?
			.ok_or_else(|| Unexecuted::Overloaded(overloaded(self.wait)))?;
		connection.busy_timeout(self.wait.saturating_sub(started.elapsed())).map_err(policy::error)?;
		Ok(connection)
	}
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
		connection.execute_batch(
			"CREATE TABLE IF NOT EXISTS driver_calls (id INTEGER NOT NULL, sequence INTEGER NOT NULL, expires INTEGER NOT NULL, last INTEGER NOT NULL, PRIMARY KEY (id, sequence)) WITHOUT ROWID"
		).map_err(fault)?;
		Ok(Self {
			connection: Lock::new(connection),
			wait: Duration::from_millis(LOCK_WAIT),
			hold: Duration::from_millis(LOCK_HOLD),
		})
	}

	fn resize(&self, bytes: u64) -> Result<(), Fault> {
		let connection =
			self.connection.take(self.wait)?.ok_or_else(|| Fault(overloaded(self.wait)))?;
		capacity(&connection, bytes)
	}
}

/// The batch's statements and its call's record, inside the transaction the caller opened.
fn batch(
	connection: &mut Connection,
	input: &DatabaseExecute,
	now: u64,
	call_id: Option<u64>,
) -> Result<Vec<DatabaseResult>, Unexecuted> {
	let answer: Result<Vec<_>, Unexecuted> = (|| {
		connection.authorizer(Some(policy::authorize)).map_err(policy::error)?;
		input.statements.iter().map(|s| statement::run(&*connection, s)).collect()
	})();
	let removed = connection.authorizer(None::<fn(AuthContext<'_>) -> _>).map_err(policy::error);
	let results = answer.and_then(|results| removed.map(|()| results))?;
	connection
		.execute(
			"DELETE FROM driver_calls WHERE ((id >> 16) + CASE WHEN id < 0 THEN (1 << 48) ELSE 0 END) < ?1",
			[signed(now.saturating_sub(STATUS_RETENTION))],
		)
		.map_err(policy::error)?;
	if let (Some(call), Some(id)) = (&input.call, call_id) {
		connection
			.execute(
				"INSERT INTO driver_calls (id, sequence, expires, last) VALUES (?1, ?2, ?3, ?4)",
				rusqlite::params![signed(id), call.sequence, signed(call.expires.get()), call.last],
			)
			.map_err(policy::error)?;
	}
	Ok(results)
}

impl Statements for Database {
	fn execute(&self, input: &DatabaseExecute) -> Result<DatabaseExecuted, Unexecuted> {
		let now = now()?;
		let call_id = input.call.as_ref().map(|call| id(&call.id)).transpose()?;
		if input.call.as_ref().is_some_and(|call| call.expires.get() <= now) {
			return Err(Unexecuted::Expired);
		}
		if input.statements.iter().any(|statement| statement.sql.len() > STATEMENT) {
			return Err(Unexecuted::BeyondLimit("statement exceeds 100000 UTF-8 bytes".into()));
		}
		let mut connection = self.connection()?;
		// The write lock taken first, so a lock met is met before anything is written.
		connection.execute_batch("BEGIN IMMEDIATE").map_err(policy::error)?;
		let (held, hold) = (Instant::now(), self.hold);
		let watched = connection.progress_handler(STEPS, Some(move || held.elapsed() > hold));
		let answer =
			watched.map_err(policy::error).and_then(|()| batch(&mut connection, input, now, call_id));
		let answer = match answer {
			Ok(_) | Err(Unexecuted::Aborted(_)) if held.elapsed() > hold => Err(aborted(hold)),
			answer => answer,
		};
		let unwatched = connection.progress_handler(0, None::<fn() -> bool>).map_err(policy::error);
		let answer = answer.and_then(|results| unwatched.map(|()| results));
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

	fn status(&self, text: &str) -> Result<DatabaseStatusAnswer, Unexecuted> {
		let id = id(text)?;
		if id >> 16 < now()?.saturating_sub(STATUS_RETENTION) {
			return Ok(DatabaseStatusAnswer::Forgotten);
		}
		let connection = self.connection()?;
		let mut statement = connection
			.prepare("SELECT sequence, expires, last FROM driver_calls WHERE id = ?1 ORDER BY sequence")
			.map_err(policy::error)?;
		let rows = statement
			.query_map([signed(id)], |row| {
				Ok((row.get::<_, u32>(0)?, row.get::<_, i64>(1)?, row.get::<_, bool>(2)?))
			})
			.map_err(policy::error)?;
		let mut committed = Vec::new();
		let mut expires = None;
		let mut finished = false;
		for row in rows {
			let (sequence, expiry, last) = row.map_err(policy::error)?;
			let expiry = u64::try_from(expiry).map_err(|e| Unexecuted::Fault(fault(e)))?;
			committed.push(sequence);
			expires = Some(
				Uint53::new(expiry)
					.ok_or_else(|| Unexecuted::Fault(Fault("invalid recorded expiry".into())))?,
			);
			finished |= last;
		}
		Ok(match expires {
			Some(expires) => DatabaseStatusAnswer::Found(CallSteps { committed, expires, finished }),
			None => DatabaseStatusAnswer::NotFound,
		})
	}
}

fn now() -> Result<u64, Unexecuted> {
	let duration =
		SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e| Unexecuted::Fault(fault(e)))?;
	u64::try_from(duration.as_millis()).map_err(|e| Unexecuted::Fault(fault(e)))
}

fn id(text: &str) -> Result<u64, Unexecuted> {
	if text.len() != 16 || !text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
		return Err(Unexecuted::Malformed(
			"call id must be sixteen lowercase hexadecimal digits".into(),
		));
	}
	u64::from_str_radix(text, 16).map_err(|e| Unexecuted::Malformed(e.to_string()))
}

fn signed(id: u64) -> i64 {
	i64::from_ne_bytes(id.to_ne_bytes())
}

fn rollback(connection: &Connection) -> Result<(), Unexecuted> {
	if !connection.is_autocommit() {
		connection.execute_batch("ROLLBACK").map_err(|e| Unexecuted::Fault(fault(e)))?;
	}
	Ok(())
}
