//! A bucket's index in SQLite, each name to its content's hash and size, each content to how many
//! names hold it, and the bytes held. A name is a blob, so it sorts by its bytes.

use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};

/// The schema's version, SQLite's `user_version`, 0 before it is made.
const VERSION: i64 = 1;

const SCHEMA: &str = "
	CREATE TABLE IF NOT EXISTS objects (
		name BLOB PRIMARY KEY,
		hash BLOB NOT NULL,
		size INTEGER NOT NULL
	) WITHOUT ROWID;
	CREATE TABLE IF NOT EXISTS contents (
		hash BLOB PRIMARY KEY,
		size INTEGER NOT NULL,
		names INTEGER NOT NULL
	) WITHOUT ROWID;
	CREATE TABLE IF NOT EXISTS held (
		only INTEGER PRIMARY KEY CHECK (only = 0),
		bytes INTEGER NOT NULL
	);
	INSERT OR IGNORE INTO held (only, bytes) VALUES (0, 0);
";

/// Why the index failed, SQLite's own, a value it holds that is not what a row says, or a version
/// this driver does not read.
#[derive(Debug)]
pub(crate) enum Failed {
	Sqlite(rusqlite::Error),
	Number(i64),
	Large(u64),
	Hash(usize),
	Version(i64),
}

impl From<rusqlite::Error> for Failed {
	fn from(e: rusqlite::Error) -> Self {
		Self::Sqlite(e)
	}
}

impl Failed {
	/// Whether SQLite found no room to write.
	pub(crate) fn full(&self) -> bool {
		match self {
			Self::Sqlite(e) => e.sqlite_error_code() == Some(rusqlite::ErrorCode::DiskFull),
			Self::Number(_) | Self::Large(_) | Self::Hash(_) | Self::Version(_) => false,
		}
	}
}

impl std::fmt::Display for Failed {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			Self::Sqlite(e) => write!(f, "the index: {e}"),
			Self::Number(n) => write!(f, "the index holds {n} where a size is"),
			Self::Large(n) => write!(f, "{n} bytes is past what the index holds"),
			Self::Hash(n) => write!(f, "the index holds a hash of {n} bytes"),
			Self::Version(v) => write!(f, "the index is at version {v}, this driver's {VERSION}"),
		}
	}
}

pub(crate) type Result<T> = std::result::Result<T, Failed>;

/// A size as SQLite holds it.
fn stored(size: u64) -> Result<i64> {
	i64::try_from(size).map_err(|_| Failed::Large(size))
}

/// A size SQLite held.
fn size(number: i64) -> Result<u64> {
	u64::try_from(number).map_err(|_| Failed::Number(number))
}

/// A hash SQLite held, 32 bytes.
fn hash(bytes: &[u8]) -> Result<[u8; 32]> {
	<[u8; 32]>::try_from(bytes).map_err(|_| Failed::Hash(bytes.len()))
}

/// The index at its file, made where it is not, each commit flushed before it is answered.
pub(crate) fn opened(file: &Path) -> Result<Connection> {
	let connection = Connection::open(file)?;
	connection.pragma_update(None, "journal_mode", "WAL")?;
	connection.pragma_update(None, "synchronous", "FULL")?;
	let version: i64 = connection.pragma_query_value(None, "user_version", |r| r.get(0))?;
	match version {
		0 => {
			connection.execute_batch(SCHEMA)?;
			connection.pragma_update(None, "user_version", VERSION)?;
		}
		VERSION => {}
		other => return Err(Failed::Version(other)),
	}
	Ok(connection)
}

/// The object of a name, its content's hash and its size.
pub(crate) fn object(c: &Connection, name: &str) -> Result<Option<([u8; 32], u64)>> {
	let row = c
		.query_row("SELECT hash, size FROM objects WHERE name = ?1", [name.as_bytes()], |r| {
			Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?))
		})
		.optional()?;
	row.map(|(h, s)| Ok((hash(&h)?, size(s)?))).transpose()
}

/// How many names hold a content, none where it is not held.
pub(crate) fn names(c: &Connection, hash: &[u8; 32]) -> Result<Option<u64>> {
	let row = c
		.query_row("SELECT names FROM contents WHERE hash = ?1", [hash.as_slice()], |r| {
			r.get::<_, i64>(0)
		})
		.optional()?;
	row.map(size).transpose()
}

/// The bytes of content held, each content once.
pub(crate) fn held(c: &Connection) -> Result<u64> {
	size(c.query_row("SELECT bytes FROM held", [], |r| r.get(0))?)
}

/// The bytes of content held set.
pub(crate) fn hold(c: &Connection, bytes: u64) -> Result<()> {
	c.execute("UPDATE held SET bytes = ?1", [stored(bytes)?])?;
	Ok(())
}

/// A name given a content, held by one name more.
pub(crate) fn name(c: &Connection, name: &str, hash: &[u8; 32], size: u64) -> Result<()> {
	let size = stored(size)?;
	c.execute(
		"INSERT INTO contents (hash, size, names) VALUES (?1, ?2, 1)
			ON CONFLICT (hash) DO UPDATE SET names = names + 1",
		params![hash.as_slice(), size],
	)?;
	c.execute(
		"INSERT OR REPLACE INTO objects (name, hash, size) VALUES (?1, ?2, ?3)",
		params![name.as_bytes(), hash.as_slice(), size],
	)?;
	Ok(())
}

/// A name's row removed, without its content's count.
pub(crate) fn unname(c: &Connection, name: &str) -> Result<()> {
	c.execute("DELETE FROM objects WHERE name = ?1", [name.as_bytes()])?;
	Ok(())
}

/// A content held by one name fewer, its row removed with the last; whether that was the last.
pub(crate) fn release(c: &Connection, hash: &[u8; 32]) -> Result<bool> {
	c.execute("UPDATE contents SET names = names - 1 WHERE hash = ?1", [hash.as_slice()])?;
	let gone = c.execute("DELETE FROM contents WHERE hash = ?1 AND names <= 0", [hash.as_slice()])?;
	Ok(gone > 0)
}

/// Every content held, its hash and its size.
pub(crate) fn contents(c: &Connection) -> Result<Vec<([u8; 32], u64)>> {
	let mut statement = c.prepare("SELECT hash, size FROM contents")?;
	let read = |r: &rusqlite::Row<'_>| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?));
	let rows: rusqlite::Result<Vec<(Vec<u8>, i64)>> = statement.query_map([], read)?.collect();
	rows?.into_iter().map(|(h, s)| Ok((hash(&h)?, size(s)?))).collect()
}

/// A content's row removed with every name holding it, as when its file is lost.
pub(crate) fn lose(c: &Connection, hash: &[u8; 32]) -> Result<()> {
	c.execute("DELETE FROM objects WHERE hash = ?1", [hash.as_slice()])?;
	c.execute("DELETE FROM contents WHERE hash = ?1", [hash.as_slice()])?;
	Ok(())
}

/// Whether any row names a content.
pub(crate) fn known(c: &Connection, hash: &[u8; 32]) -> Result<bool> {
	Ok(names(c, hash)?.is_some())
}

/// Where a page of names starts, at a name or just after it.
pub(crate) enum Start<'a> {
	At(&'a [u8]),
	After(&'a [u8]),
}

/// The names from `from` and before `before`, in byte order, at most `most`, each with its size.
pub(crate) fn page(
	c: &Connection,
	from: &Start<'_>,
	before: Option<&[u8]>,
	most: u32,
) -> Result<Vec<(Vec<u8>, u64)>> {
	let (start, bound) = match from {
		Start::At(name) => (">=", *name),
		Start::After(name) => (">", *name),
	};
	let end = if before.is_some() { "AND name < ?3" } else { "" };
	let sql =
		format!("SELECT name, size FROM objects WHERE name {start} ?1 {end} ORDER BY name LIMIT ?2");
	let mut statement = c.prepare(&sql)?;
	let read = |r: &rusqlite::Row<'_>| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?));
	let rows: rusqlite::Result<Vec<(Vec<u8>, i64)>> = match before {
		Some(end) => statement.query_map(params![bound, most, end], read)?.collect(),
		None => statement.query_map(params![bound, most], read)?.collect(),
	};
	rows?.into_iter().map(|(n, s)| Ok((n, size(s)?))).collect()
}
