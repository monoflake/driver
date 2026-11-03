//! `driver(machine)`'s database, one SQLite file on a volume with one writer and one copy, RFC
//! 4elqc. This file is its interface, the model's, `docs/code.md`.

use std::path::Path;
use std::sync::Mutex;

use envelope::contracts::{DatabaseExecute, DatabaseExecuted};

mod database;

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
	/// `invalid`, a statement that does not parse or may not run here, and SQLite's words.
	Invalid(String),
	/// `constraint`, a constraint broken, and SQLite's words.
	Constraint(String),
	/// `beyond_limit`, a statement past [`STATEMENT`] or a limit of SQLite's, and which.
	BeyondLimit(String),
	/// `beyond_range`, an integer read past what a JavaScript number holds, and which.
	BeyondRange(String),
	/// `storage_full`, past the database's capacity or the file system's room.
	StorageFull,
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
}
