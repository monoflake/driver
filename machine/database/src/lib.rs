//! `driver(machine)`'s database, one SQLite file on a volume with one writer and one copy, RFC
//! 4elqc. This file is its interface, the model's, `docs/code.md`.

use std::path::Path;
use std::sync::Mutex;

use envelope::contracts::{CallSteps, DatabaseExecute, DatabaseExecuted};

mod database;

mod calls;

pub use calls::{ID_LIFE, LOCK_HOLD, LOCK_WAIT, LOOKUP_DEADLINE, STATUS_RETENTION};

/// The file within a database's volume, its WAL beside it.
pub const FILE: &str = "database.sqlite";

/// The most a statement's text holds in bytes, D1's own so both homes agree, driver's RFC nrs5v.
pub const STATEMENT: usize = 100_000;

/// What a database's volume holds past its capacity, its WAL and its index of it.
pub const ROOM: u64 = 64 * 1024 * 1024;

/// What a database could not do at a moment, answered `fault`, RFC ge55b.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fault(pub String);

/// Why a batch changed nothing, by its reason as the `database` interface declares it, or a fault.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Unexecuted {
	/// `expired`, the call's expiry has passed.
	Expired,
	/// `malformed`, the call id is not sixteen lowercase hexadecimal digits.
	Malformed(String),
	/// `invalid`, a statement that does not parse or may not run here, and SQLite's words.
	Invalid(String),
	/// `constraint`, a constraint broken, and SQLite's words.
	Constraint(String),
	/// `beyond_limit`, a statement past [`STATEMENT`] or a limit of SQLite's, and which.
	BeyondLimit(String),
	/// `beyond_range`, an integer past what a JavaScript number holds, or a real not finite, read.
	BeyondRange(String),
	/// `storage_full`, past the database's capacity or the file system's room.
	StorageFull,
	/// `overloaded`, another writer holding the file's lock, the batch rolled back, RFC 49qyg.
	Overloaded(String),
	/// Anything else.
	Fault(Fault),
}

/// A database open at its directory, its one connection the one writer; opened by [`Open`] alone,
/// and one open at a time for a directory, which a volume of the machine's holds.
#[derive(Debug)]
pub struct Database {
	connection: Mutex<rusqlite::Connection>,
}

/// A database opened at its directory, made where nothing is there yet; implemented for
/// [`Database`].
pub trait Open: Sized {
	/// The database at `directory`, at most `capacity` bytes of pages.
	fn open(directory: &Path, capacity: u64) -> Result<Self, Fault>;
	/// Its capacity changed, held from the next write on; what it holds past it stays.
	fn resize(&self, capacity: u64) -> Result<(), Fault>;
}

/// The `database` interface's `execute`, RFC zn3u5, implemented for [`Database`]. A batch is one
/// transaction, each statement seeing those before it, and one that fails changes nothing.
pub trait Statements {
	/// Each statement run in order, one result for each.
	fn execute(&self, input: &DatabaseExecute) -> Result<DatabaseExecuted, Unexecuted>;
	/// The committed steps, or whether the id is unseen or past status retention.
	fn status(&self, id: &str) -> Result<DatabaseStatusAnswer, Unexecuted>;
}

/// What the database knows about a call within the protocol's status retention.
#[derive(Debug)]
pub enum DatabaseStatusAnswer {
	/// The call's committed steps in sequence order.
	Found(CallSteps),
	/// No step of this call has committed.
	NotFound,
	/// The id's milliseconds precede the retained interval, regardless of stored rows.
	Forgotten,
}
