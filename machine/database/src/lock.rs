//! The one connection lent to one caller at a time, waited for within a bound, RFC 49qyg.

use std::ops::{Deref, DerefMut};
use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use crate::Fault;

/// A value one caller holds at a time, the others waiting their turn for a bounded time.
#[derive(Debug)]
pub(crate) struct Lock<T> {
	value: Mutex<T>,
	gate: Gate,
}

#[derive(Debug, Default)]
struct Gate {
	lent: Mutex<bool>,
	freed: Condvar,
}

/// A turn at the gate, given back as it drops.
struct Turn<'a>(&'a Gate);

impl Drop for Turn<'_> {
	fn drop(&mut self) {
		*self.0.lent.lock().unwrap_or_else(PoisonError::into_inner) = false;
		self.0.freed.notify_one();
	}
}

/// The value held, its turn given back once the value is released, as the fields drop in order.
pub(crate) struct Held<'a, T> {
	value: MutexGuard<'a, T>,
	_turn: Turn<'a>,
}

impl<T> Lock<T> {
	pub(crate) fn new(value: T) -> Self {
		Self { value: Mutex::new(value), gate: Gate::default() }
	}

	/// The value once its holder lets it go, or `None` when nobody has within `wait`.
	pub(crate) fn take(&self, wait: Duration) -> Result<Option<Held<'_, T>>, Fault> {
		let lent = self.gate.lent.lock().unwrap_or_else(PoisonError::into_inner);
		let (mut lent, _) = self
			.gate
			.freed
			.wait_timeout_while(lent, wait, |lent| *lent)
			.unwrap_or_else(PoisonError::into_inner);
		if *lent {
			return Ok(None);
		}
		*lent = true;
		drop(lent);
		let turn = Turn(&self.gate);
		let value = self.value.lock().map_err(|e| Fault(e.to_string()))?;
		Ok(Some(Held { value, _turn: turn }))
	}
}

impl<T> Deref for Held<'_, T> {
	type Target = T;

	fn deref(&self) -> &T {
		&self.value
	}
}

impl<T> DerefMut for Held<'_, T> {
	fn deref_mut(&mut self) -> &mut T {
		&mut self.value
	}
}

#[cfg(test)]
mod tests {
	use std::path::PathBuf;
	use std::sync::atomic::{AtomicU32, Ordering};
	use std::time::{Duration, Instant};

	use envelope::{Encoded as _, contracts::DatabaseExecute};
	use serde_json::json;

	use super::Lock;
	use crate::{Database, LOCK_HOLD, LOCK_WAIT, Open as _, Statements as _, Unexecuted};

	static MADE: AtomicU32 = AtomicU32::new(0);

	struct Directory(PathBuf);

	impl Drop for Directory {
		fn drop(&mut self) {
			std::fs::remove_dir_all(&self.0).unwrap();
		}
	}

	fn opened() -> (Directory, Database) {
		let n = MADE.fetch_add(1, Ordering::Relaxed);
		let path =
			std::env::temp_dir().join(format!("driver-machine-database-lock-{}-{n}", std::process::id()));
		std::fs::create_dir_all(&path).unwrap();
		let database = Database::open(&path, 1024 * 1024).unwrap();
		(Directory(path), database)
	}

	fn database(wait: Duration, hold: Duration) -> (Directory, Database) {
		let (directory, mut database) = opened();
		database.wait = wait;
		database.hold = hold;
		(directory, database)
	}

	fn input(sql: &[&str]) -> DatabaseExecute {
		let statements = sql.iter().map(|sql| json!({"sql": sql})).collect::<Vec<_>>();
		DatabaseExecute::from_json(&json!({"statements": statements})).unwrap()
	}

	fn rows(database: &Database) -> usize {
		database.execute(&input(&["SELECT n FROM t"])).unwrap().results[0].rows.len()
	}

	#[test]
	fn open_takes_both_bounds_from_the_protocol() {
		let (_directory, database) = opened();
		assert_eq!(database.wait, Duration::from_millis(LOCK_WAIT));
		assert_eq!(database.hold, Duration::from_millis(LOCK_HOLD));
	}

	#[test]
	fn a_lock_still_held_past_the_wait_is_not_taken() {
		let lock = Lock::new(0);
		let held = lock.take(Duration::ZERO).unwrap().unwrap();
		let started = Instant::now();
		assert!(lock.take(Duration::from_millis(50)).unwrap().is_none());
		assert!(started.elapsed() >= Duration::from_millis(50));
		drop(held);
		assert!(lock.take(Duration::ZERO).unwrap().is_some());
	}

	#[test]
	fn a_lock_freed_within_the_wait_is_taken() {
		let lock = &Lock::new(0);
		std::thread::scope(|scope| {
			let mut held = lock.take(Duration::ZERO).unwrap().unwrap();
			let (sent, received) = std::sync::mpsc::channel();
			let waiter = scope.spawn(move || {
				sent.send(()).unwrap();
				*lock.take(Duration::from_secs(10)).unwrap().unwrap()
			});
			received.recv().unwrap();
			std::thread::sleep(Duration::from_millis(20));
			*held = 7;
			drop(held);
			assert_eq!(waiter.join().unwrap(), 7);
		});
	}

	#[test]
	fn a_batch_waiting_past_the_crate_lock_is_overloaded_and_writes_nothing() {
		let (_directory, database) = database(Duration::from_millis(50), Duration::from_secs(10));
		database.execute(&input(&["CREATE TABLE t (n INTEGER)"])).unwrap();
		let held = database.connection.take(Duration::ZERO).unwrap().unwrap();
		let refused = database.execute(&input(&["INSERT INTO t VALUES (1)"]));
		assert!(matches!(refused, Err(Unexecuted::Overloaded(_))), "{refused:?}");
		let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap();
		let status = database.status(&format!("{:016x}", now.as_millis() << 16));
		assert!(matches!(status, Err(Unexecuted::Overloaded(_))), "{status:?}");
		drop(held);
		assert_eq!(rows(&database), 0);
	}

	#[test]
	fn a_statement_running_past_the_hold_is_aborted_and_rolled_back() {
		let (_directory, database) = database(Duration::from_secs(10), Duration::from_millis(50));
		database.execute(&input(&["CREATE TABLE t (n INTEGER)"])).unwrap();
		let started = Instant::now();
		let aborted = database.execute(&input(&[
			"INSERT INTO t VALUES (1)",
			"WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c",
		]));
		assert!(matches!(aborted, Err(Unexecuted::Aborted(_))), "{aborted:?}");
		assert!(started.elapsed() < Duration::from_secs(5));
		assert_eq!(rows(&database), 0);
	}

	#[test]
	fn a_batch_ending_past_the_hold_is_aborted_before_its_commit() {
		let (_directory, database) = database(Duration::from_secs(10), Duration::ZERO);
		let refused = database.execute(&input(&["CREATE TABLE t (n INTEGER)"]));
		assert!(matches!(refused, Err(Unexecuted::Aborted(_))), "{refused:?}");
		let mut database = database;
		database.hold = Duration::from_secs(10);
		let missing = database.execute(&input(&["SELECT n FROM t"]));
		assert!(matches!(missing, Err(Unexecuted::Invalid(_))), "{missing:?}");
	}

	#[test]
	fn a_batch_within_both_bounds_commits() {
		let (_directory, database) = database(Duration::from_millis(50), Duration::from_secs(10));
		database.execute(&input(&["CREATE TABLE t (n INTEGER)", "INSERT INTO t VALUES (1)"])).unwrap();
		assert_eq!(rows(&database), 1);
	}
}
