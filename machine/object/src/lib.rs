//! `driver(machine)`'s object, a bucket of objects by name on the machine's file system, RFC
//! vr5lw. This file is its interface, the model's, `docs/code.md`.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use envelope::contracts::{
	ObjectContent, ObjectDeleted, ObjectDescribed, ObjectList, ObjectListed, ObjectName, ObjectRead,
	ObjectWrite, ObjectWritten,
};

mod bucket;
mod index;
mod subvolume;

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

/// A bucket open at its directory, the index's one connection and the capacity it holds; opened by
/// [`Open`] alone, and one open at a time for a directory.
#[derive(Debug)]
pub struct Bucket {
	directory: PathBuf,
	capacity: Option<u64>,
	index: Mutex<rusqlite::Connection>,
}

/// A bucket opened at its directory, made where nothing is there yet; implemented for [`Bucket`].
pub trait Open: Sized {
	/// The bucket at `directory`, at most `capacity` bytes of content, none for no bound but the
	/// file system's; what no row names is removed, as a write cut short leaves it.
	fn open(directory: &Path, capacity: Option<u64>) -> Result<Self, Fault>;
}

/// The `object` interface, RFC vr5lw, implemented for [`Bucket`]. Each read sees every write
/// answered before it, and none sees a write in part.
pub trait Objects {
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

/// btrfs, by its `btrfs` command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Btrfs {
	/// The `btrfs` binary.
	pub binary: PathBuf,
}

/// A bucket's subvolume made and removed; implemented for [`Btrfs`].
pub trait Subvolumes {
	/// A subvolume made at `at`, its parent a directory of a btrfs mount.
	fn create(&self, at: &Path) -> Result<(), Fault>;
	/// The subvolume at `at` removed, with everything in it.
	fn delete(&self, at: &Path) -> Result<(), Fault>;
}
