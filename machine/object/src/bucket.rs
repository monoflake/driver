//! A bucket's operations. A content is flushed and renamed into place before a row names it, and
//! removed only once the last row naming it is gone, so no object is ever seen in part.

use std::fs::{self, File};
use std::io::{self, Read as _, Seek as _, SeekFrom, Write as _};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};

use envelope::contracts::{
	ObjectContent, ObjectDeleted, ObjectDescribed, ObjectList, ObjectListed, ObjectListedOne,
	ObjectName, ObjectRead, ObjectWrite, ObjectWritten,
};
use envelope::{Bounded as _, Uint53};
use rusqlite::{Connection, TransactionBehavior};

use crate::index::{self, Failed, Start};
use crate::{
	Bucket, CONTENTS, Fault, INDEX, MOST, Objects, Open, PAGE, Unread, Unwritten, WRITING,
};

impl From<Failed> for Fault {
	fn from(e: Failed) -> Self {
		Self(e.to_string())
	}
}

impl From<Failed> for Unwritten {
	fn from(e: Failed) -> Self {
		if e.full() { Self::StorageFull } else { Self::Fault(e.into()) }
	}
}

impl From<Failed> for Unread {
	fn from(e: Failed) -> Self {
		Self::Fault(e.into())
	}
}

impl From<rusqlite::Error> for Fault {
	fn from(e: rusqlite::Error) -> Self {
		Failed::from(e).into()
	}
}

impl From<rusqlite::Error> for Unwritten {
	fn from(e: rusqlite::Error) -> Self {
		Failed::from(e).into()
	}
}

/// A file system's failure, what it did and to which path.
fn failed(doing: &str, path: &Path, e: &io::Error) -> Fault {
	Fault(format!("{doing} {}: {e}", path.display()))
}

/// A file system's failure in a write, `storage_full` where it had no room or the quota is spent.
fn unwritten(doing: &str, path: &Path, e: &io::Error) -> Unwritten {
	if matches!(e.kind(), io::ErrorKind::StorageFull | io::ErrorKind::QuotaExceeded) {
		Unwritten::StorageFull
	} else {
		Unwritten::Fault(failed(doing, path, e))
	}
}

/// A size as the contract writes it.
fn uint53(size: u64) -> Result<Uint53, Fault> {
	Uint53::new(size).ok_or_else(|| Fault(format!("{size} is past 2^53")))
}

/// A content written to a file, flushed, then renamed to where it is placed.
fn placed(writing: &Path, placed: &Path, content: &[u8]) -> Result<(), Unwritten> {
	let mut file = File::create(writing).map_err(|e| unwritten("make", writing, &e))?;
	file.write_all(content).map_err(|e| unwritten("write", writing, &e))?;
	file.sync_all().map_err(|e| unwritten("flush", writing, &e))?;
	drop(file);
	fs::rename(writing, placed).map_err(|e| unwritten("rename", writing, &e))
}

/// A directory's entries flushed, so a rename in it outlasts a crash.
fn flushed(directory: &Path) -> io::Result<()> {
	File::open(directory)?.sync_all()
}

/// Every file of a directory removed.
fn emptied(directory: &Path) -> Result<(), Fault> {
	let entries = fs::read_dir(directory).map_err(|e| failed("read", directory, &e))?;
	for entry in entries {
		let path = entry.map_err(|e| failed("read", directory, &e))?.path();
		fs::remove_file(&path).map_err(|e| failed("remove", &path, &e))?;
	}
	Ok(())
}

/// Every content's file no row names removed, as a write cut before its commit leaves one.
fn swept(index: &Connection, contents: &Path) -> Result<(), Fault> {
	let entries = fs::read_dir(contents).map_err(|e| failed("read", contents, &e))?;
	for entry in entries {
		let path = entry.map_err(|e| failed("read", contents, &e))?.path();
		let named = match path.file_name().and_then(|n| n.to_str()).map(blake3::Hash::from_hex) {
			Some(Ok(hash)) => index::known(index, hash.as_bytes())?,
			Some(Err(_)) | None => false,
		};
		if !named {
			fs::remove_file(&path).map_err(|e| failed("remove", &path, &e))?;
		}
	}
	Ok(())
}

/// Every object whose content's file is gone removed with its content's row and the bytes it held,
/// since what it held is lost and no answer may say it is there.
fn healed(index: &mut Connection, contents: &Path) -> Result<(), Fault> {
	let transaction = index.transaction_with_behavior(TransactionBehavior::Immediate)?;
	let mut held = index::held(&transaction)?;
	for (hash, size) in index::contents(&transaction)? {
		let path = contents.join(blake3::Hash::from_bytes(hash).to_hex().as_str());
		match fs::symlink_metadata(&path) {
			Ok(_) => {}
			Err(e) if e.kind() == io::ErrorKind::NotFound => {
				index::lose(&transaction, &hash)?;
				held = held.saturating_sub(size);
			}
			Err(e) => return Err(failed("read", &path, &e)),
		}
	}
	index::hold(&transaction, held)?;
	transaction.commit()?;
	Ok(())
}

impl Open for Bucket {
	fn open(directory: &Path, capacity: Option<u64>) -> Result<Self, Fault> {
		for made in [CONTENTS, WRITING] {
			let path = directory.join(made);
			fs::create_dir_all(&path).map_err(|e| failed("make", &path, &e))?;
		}
		let mut index = index::opened(&directory.join(INDEX))?;
		emptied(&directory.join(WRITING))?;
		swept(&index, &directory.join(CONTENTS))?;
		healed(&mut index, &directory.join(CONTENTS))?;
		let (directory, capacity) = (directory.to_owned(), Mutex::new(capacity));
		Ok(Self { directory, capacity, index: Mutex::new(index) })
	}

	fn resize(&self, capacity: Option<u64>) {
		*self.capacity.lock().unwrap_or_else(PoisonError::into_inner) = capacity;
	}
}

impl Bucket {
	/// The index, held while an operation reads or changes it, so each sees every one before it.
	fn index(&self) -> MutexGuard<'_, Connection> {
		self.index.lock().unwrap_or_else(PoisonError::into_inner)
	}

	/// A content's file, by its hash.
	fn content(&self, hash: &[u8; 32]) -> PathBuf {
		self.directory.join(CONTENTS).join(blake3::Hash::from_bytes(*hash).to_hex().as_str())
	}

	/// A content written to its file, flushed, then renamed into place and the rename flushed; the
	/// file being written is removed where any of it fails, so no room stays taken by it.
	fn put(&self, hash: &[u8; 32], content: &[u8]) -> Result<(), Unwritten> {
		let hex = blake3::Hash::from_bytes(*hash).to_hex();
		let writing = self.directory.join(WRITING).join(hex.as_str());
		let placed = placed(&writing, &self.content(hash), content);
		if placed.is_err() {
			let _ = fs::remove_file(&writing);
		}
		placed?;
		let contents = self.directory.join(CONTENTS);
		flushed(&contents).map_err(|e| unwritten("flush", &contents, &e))
	}

	/// Where an operation has let the index go, so a test runs another just after.
	fn released(&self) {
		#[cfg(test)]
		tests::between(self);
	}

	/// A content's file removed once no row names it, called with the index still held so no write
	/// puts the same content between; one left by a failure here is swept at open.
	fn unlink(&self, hash: &[u8; 32]) {
		let _ = fs::remove_file(self.content(hash));
	}
}

impl Objects for Bucket {
	fn write(&self, input: &ObjectWrite) -> Result<ObjectWritten, Unwritten> {
		if input.content.len() > MOST {
			return Err(Unwritten::TooLarge);
		}
		let size = u64::try_from(input.content.len()).map_err(|_| Unwritten::TooLarge)?;
		let hash = *blake3::hash(&input.content).as_bytes();
		let mut index = self.index();
		let transaction = index.transaction_with_behavior(TransactionBehavior::Immediate)?;
		let old = index::object(&transaction, &input.name)?;
		if old.is_some_and(|(h, _)| h == hash) {
			return Ok(ObjectWritten {});
		}
		let present = index::names(&transaction, &hash)?.is_some();
		let freed = match old {
			Some((h, s)) if index::names(&transaction, &h)? == Some(1) => s,
			Some(_) | None => 0,
		};
		let added = if present { 0 } else { size };
		let after = index::held(&transaction)?.saturating_add(added).saturating_sub(freed);
		let capacity = *self.capacity.lock().unwrap_or_else(PoisonError::into_inner);
		if capacity.is_some_and(|c| after > c) {
			return Err(Unwritten::StorageFull);
		}
		// A content put here is named by no row but this transaction's, so a failure removes it.
		let recorded = if present { Ok(()) } else { self.put(&hash, &input.content) }
			.and_then(|()| recorded(transaction, &input.name, &hash, size, old, after));
		match recorded {
			Ok(Some(gone)) => self.unlink(&gone),
			Ok(None) => {}
			Err(e) => {
				if !present {
					self.unlink(&hash);
				}
				return Err(e);
			}
		}
		drop(index);
		self.released();
		Ok(ObjectWritten {})
	}

	fn read(&self, input: &ObjectRead) -> Result<ObjectContent, Unread> {
		let index = self.index();
		let Some((hash, size)) = index::object(&index, &input.name)? else {
			return Err(Unread::NotFound);
		};
		let path = self.content(&hash);
		// The file stays readable once open, though a write or a delete after removes its name.
		let mut file = File::open(&path).map_err(|e| Unread::Fault(failed("open", &path, &e)))?;
		drop(index);
		let (start, length) =
			input.range.as_ref().map_or((0, size), |r| (r.start.get(), r.length.get()));
		let start = start.min(size);
		let length = length.min(size - start);
		file.seek(SeekFrom::Start(start)).map_err(|e| Unread::Fault(failed("seek", &path, &e)))?;
		let mut content = Vec::new();
		file
			.take(length)
			.read_to_end(&mut content)
			.map_err(|e| Unread::Fault(failed("read", &path, &e)))?;
		if u64::try_from(content.len()).ok() != Some(length) {
			let got = content.len();
			return Err(Unread::Fault(Fault(format!(
				"{} holds {got} of {length} bytes",
				path.display()
			))));
		}
		Ok(ObjectContent { content, size: uint53(size).map_err(Unread::Fault)? })
	}

	fn describe(&self, input: &ObjectName) -> Result<ObjectDescribed, Fault> {
		let index = self.index();
		let size = index::object(&index, &input.name)?.map(|(_, s)| uint53(s)).transpose()?;
		Ok(ObjectDescribed { size })
	}

	fn delete(&self, input: &ObjectName) -> Result<ObjectDeleted, Fault> {
		let mut index = self.index();
		let transaction = index.transaction_with_behavior(TransactionBehavior::Immediate)?;
		let Some((hash, size)) = index::object(&transaction, &input.name)? else {
			return Ok(ObjectDeleted {});
		};
		index::unname(&transaction, &input.name)?;
		let gone = index::release(&transaction, &hash)?;
		if gone {
			let held = index::held(&transaction)?;
			index::hold(&transaction, held.saturating_sub(size))?;
		}
		transaction.commit()?;
		if gone {
			self.unlink(&hash);
		}
		drop(index);
		self.released();
		Ok(ObjectDeleted {})
	}

	fn list(&self, input: &ObjectList) -> Result<ObjectListed, Fault> {
		let most = match input.limit {
			None => PAGE,
			Some(0) => todo!("lnxbp"),
			Some(limit) => limit.min(PAGE),
		};
		let prefix = input.prefix.as_bytes();
		let before = successor(prefix);
		let start = match input.after.as_deref().map(str::as_bytes) {
			Some(after) if after >= prefix => Start::After(after),
			Some(_) | None => Start::At(prefix),
		};
		let rows = index::page(&self.index(), &start, before.as_deref(), most.saturating_add(1))?;
		let mut objects = Vec::new();
		for (name, size) in rows {
			let name = String::from_utf8(name)
				.map_err(|e| Fault(format!("the index holds a name not UTF-8: {e}")))?;
			objects.push(ObjectListedOne { name, size: uint53(size)? });
		}
		let next = if objects.len() > usize::try_from(most).unwrap_or(usize::MAX) {
			objects.pop();
			objects.last().map(|o| o.name.clone())
		} else {
			None
		};
		Ok(ObjectListed { objects, next })
	}
}

/// A write's rows changed and committed, the name given its content and the old one released;
/// the old content's hash where no name holds it now.
fn recorded(
	transaction: rusqlite::Transaction<'_>,
	name: &str,
	hash: &[u8; 32],
	size: u64,
	old: Option<([u8; 32], u64)>,
	after: u64,
) -> Result<Option<[u8; 32]>, Unwritten> {
	index::name(&transaction, name, hash, size)?;
	let gone = match old {
		Some((h, _)) => index::release(&transaction, &h)?.then_some(h),
		None => None,
	};
	index::hold(&transaction, after)?;
	transaction.commit()?;
	Ok(gone)
}

/// The least byte string after every one starting with `prefix`, none where nothing is after them.
fn successor(prefix: &[u8]) -> Option<Vec<u8>> {
	let mut bytes = prefix.to_vec();
	while let Some(last) = bytes.pop() {
		if last < u8::MAX {
			bytes.push(last.saturating_add(1));
			return Some(bytes);
		}
	}
	None
}

#[cfg(test)]
mod tests {
	use std::cell::RefCell;
	use std::path::PathBuf;

	use envelope::contracts::{ObjectName, ObjectRead, ObjectWrite};

	use super::successor;
	use crate::{Bucket, Objects as _, Open as _};

	/// What runs once where the next operation lets the index go.
	type Between = Box<dyn FnOnce(&Bucket)>;

	thread_local! {
		static BETWEEN: RefCell<Option<Between>> = RefCell::new(None);
	}

	/// The operation set to run where this one let the index go, taken so it runs once.
	pub(super) fn between(bucket: &Bucket) {
		if let Some(run) = BETWEEN.with(|b| b.borrow_mut().take()) {
			run(bucket);
		}
	}

	/// A bucket in a directory of its own under the system's temporary one.
	fn opened(name: &str) -> (PathBuf, Bucket) {
		let directory = std::env::temp_dir()
			.join(format!("driver-machine-object-unit-{name}-{}", std::process::id()));
		let _ = std::fs::remove_dir_all(&directory);
		let bucket = Bucket::open(&directory, None).unwrap();
		(directory, bucket)
	}

	fn write(bucket: &Bucket, name: &str, content: &[u8]) {
		let input = ObjectWrite { name: name.into(), content: content.to_vec() };
		bucket.write(&input).unwrap();
	}

	fn read(bucket: &Bucket, name: &str) -> Vec<u8> {
		bucket.read(&ObjectRead { name: name.into(), range: None }).unwrap().content
	}

	#[test]
	fn a_write_of_the_same_bytes_just_after_a_delete_of_their_last_name_keeps_its_file() {
		let (directory, bucket) = opened("delete-race");
		write(&bucket, "a", b"same");
		BETWEEN.with(|b| *b.borrow_mut() = Some(Box::new(|bucket| write(bucket, "b", b"same"))));
		bucket.delete(&ObjectName { name: "a".into() }).unwrap();
		assert_eq!(read(&bucket, "b"), b"same");
		let _ = std::fs::remove_dir_all(directory);
	}

	#[test]
	fn a_write_of_the_same_bytes_just_after_a_write_freed_them_keeps_its_file() {
		let (directory, bucket) = opened("write-race");
		write(&bucket, "a", b"old");
		BETWEEN.with(|b| *b.borrow_mut() = Some(Box::new(|bucket| write(bucket, "b", b"old"))));
		write(&bucket, "a", b"new");
		assert_eq!(read(&bucket, "b"), b"old");
		assert_eq!(read(&bucket, "a"), b"new");
		let _ = std::fs::remove_dir_all(directory);
	}

	#[test]
	fn a_prefix_is_followed_by_its_last_byte_raised_past_every_highest_one() {
		assert_eq!(successor(b"a/"), Some(b"a0".to_vec()));
		assert_eq!(successor(&[b'a', 0xff, 0xff]), Some(b"b".to_vec()));
		assert_eq!(successor(&[0xff]), None);
		assert_eq!(successor(b""), None);
	}
}
