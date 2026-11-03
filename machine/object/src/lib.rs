//! `driver(machine)`'s object, a bucket of objects by name on the machine's file system, RFC
//! vr5lw, reached by the storage product alone. This file is its interface, the model's,
//! `docs/code.md`.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use envelope::contracts::{
	CallSteps, ObjectContent, ObjectDeleted, ObjectDescribed, ObjectList, ObjectListed, ObjectName,
	ObjectRead, ObjectWrite, ObjectWritten,
};

mod bucket;
mod calls;
mod index;

/// The platform's call timing constants in milliseconds.
#[derive(Debug)]
pub struct CallTiming {
	/// The wait for a call lock.
	pub lock_wait: u64,
	/// The duration a call lock is held.
	pub lock_hold: u64,
	/// The deadline for a status lookup.
	pub lookup_deadline: u64,
	/// The lifetime of a call id.
	pub id_life: u64,
	/// The duration call status is retained.
	pub status_retention: u64,
}

/// The call timing constants supplied by the platform model, read once.
pub static CALLS: std::sync::LazyLock<Result<CallTiming, Fault>> = std::sync::LazyLock::new(|| {
	let values: serde_json::Value =
		serde_json::from_str(include_str!("../../../../platform/model/protocol/calls.json"))
			.map_err(|e| Fault(e.to_string()))?;
	let value = |name| {
		values
			.get(name)
			.and_then(serde_json::Value::as_u64)
			.ok_or_else(|| Fault(format!("call timing {name} is not milliseconds")))
	};
	Ok(CallTiming {
		lock_wait: value("lockWait")?,
		lock_hold: value("lockHold")?,
		lookup_deadline: value("lookupDeadline")?,
		id_life: value("idLife")?,
		status_retention: value("statusRetention")?,
	})
});

/// The most an object holds in bytes, the contract's `most`, a parcel's 16 MiB, RFC b8f35.
pub const MOST: usize = 16 * 1024 * 1024;

/// The most names one list answers, the contract's default, however many it asks.
pub const PAGE: u32 = 1000;

/// The index's file within a bucket, an SQLite database.
pub const INDEX: &str = "index.sqlite";

/// The directory within a bucket holding each content as a file named by its BLAKE3 in hex.
pub const CONTENTS: &str = "contents";

/// The directory within a bucket a content is written in before it is renamed into [`CONTENTS`].
pub const WRITING: &str = "writing";

/// What a bucket could not do at a moment, answered `fault`, RFC ge55b.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fault(pub String);

/// Why a write was refused, by its reason as the `object` interface declares it, or a fault.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Unwritten {
	/// `expired`, the call has passed its expiry.
	Expired,
	/// `malformed`, the call id is not sixteen lowercase hexadecimal digits.
	Malformed(String),
	/// `too_large`, its content past [`MOST`].
	TooLarge,
	/// `storage_full`, past the bucket's capacity or the file system's room.
	StorageFull,
	/// Anything else.
	Fault(Fault),
}

/// Why a read was refused, by its reason as the `object` interface declares it, or a fault.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Unread {
	/// `not_found`, no object of the name.
	NotFound,
	/// Anything else.
	Fault(Fault),
}

/// A call's committed steps, absent history, or history past the retention period.
#[derive(Debug, Clone, PartialEq)]
pub enum ObjectStatusAnswer {
	/// The steps committed with their object names.
	Found(CallSteps),
	/// No step with this id has committed.
	NotFound,
	/// The id's timestamp is older than the platform's status retention.
	Forgotten,
}

/// A bucket open at its directory, the index's one connection and the capacity it holds; opened by
/// [`Open`] alone, and one open at a time for a directory, which a volume of the machine's holds.
#[derive(Debug)]
pub struct Bucket {
	directory: PathBuf,
	capacity: Mutex<Option<u64>>,
	index: Mutex<rusqlite::Connection>,
}

/// A bucket opened at its directory, made where nothing is there yet; implemented for [`Bucket`].
pub trait Open: Sized {
	/// The bucket at `directory`, at most `capacity` bytes of content, none for no bound but the
	/// file system's; what no row names is removed, as a write cut short leaves it.
	fn open(directory: &Path, capacity: Option<u64>) -> Result<Self, Fault>;
	/// Its capacity changed, held from the next write on; what it holds past it stays.
	fn resize(&self, capacity: Option<u64>);
}

/// The `object` interface, RFC vr5lw, implemented for [`Bucket`]. Each read sees every write
/// answered before it, and none sees a write in part.
pub trait Objects {
	/// The call's committed steps, or absence determined by its id and retained history.
	fn status(&self, id: &str) -> Result<ObjectStatusAnswer, Fault>;
	/// The object written whole, its content kept once however many names hold it.
	fn write(&self, input: &ObjectWrite) -> Result<ObjectWritten, Unwritten>;
	/// The object read whole, or a range of it cut at its end, beside its whole size.
	fn read(&self, input: &ObjectRead) -> Result<ObjectContent, Unread>;
	/// Its size, absent when no object is there.
	fn describe(&self, input: &ObjectName) -> Result<ObjectDescribed, Fault>;
	/// The object removed, and its content once no other name holds it; one absent is no failure.
	fn delete(&self, input: &ObjectName) -> Result<ObjectDeleted, Fault>;
	/// The names under the prefix after `after` in byte order, at most `limit` and [`PAGE`].
	fn list(&self, input: &ObjectList) -> Result<ObjectListed, Fault>;
}
