//! A bucket's operations. A content is flushed and renamed into place before a row names it, and
//! removed only once the last row naming it is gone, so no object is ever seen in part.

use std::fs::{self, File};
use std::io::{self, Read as _, Seek as _, SeekFrom, Write as _};
use std::path::{Path, PathBuf};
use std::sync::{MutexGuard, PoisonError};

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

impl Open for Bucket {
	fn open(directory: &Path, capacity: Option<u64>) -> Result<Self, Fault> {
		for made in [CONTENTS, WRITING] {
			let path = directory.join(made);
			fs::create_dir_all(&path).map_err(|e| failed("make", &path, &e))?;
		}
		let index = index::opened(&directory.join(INDEX))?;
		emptied(&directory.join(WRITING))?;
		swept(&index, &directory.join(CONTENTS))?;
		Ok(Self { directory: directory.to_owned(), capacity, index: std::sync::Mutex::new(index) })
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

	/// A content written to its file, flushed, then renamed into place and the rename flushed.
	fn put(&self, hash: &[u8; 32], content: &[u8]) -> Result<(), Unwritten> {
		let hex = blake3::Hash::from_bytes(*hash).to_hex();
		let writing = self.directory.join(WRITING).join(hex.as_str());
		let mut file = File::create(&writing).map_err(|e| unwritten("make", &writing, &e))?;
		file.write_all(content).map_err(|e| unwritten("write", &writing, &e))?;
		file.sync_all().map_err(|e| unwritten("flush", &writing, &e))?;
		drop(file);
		let placed = self.content(hash);
		fs::rename(&writing, &placed).map_err(|e| unwritten("rename", &writing, &e))?;
		let contents = self.directory.join(CONTENTS);
		flushed(&contents).map_err(|e| unwritten("flush", &contents, &e))
	}

	/// A content's file removed once no row names it; one left by a failure here is swept at open.
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
		if self.capacity.is_some_and(|c| after > c) {
			return Err(Unwritten::StorageFull);
		}
		if !present {
			self.put(&hash, &input.content)?;
		}
		index::name(&transaction, &input.name, &hash, size)?;
		let gone = match old {
			Some((h, _)) => index::release(&transaction, &h)?.then_some(h),
			None => None,
		};
		index::hold(&transaction, after)?;
		transaction.commit()?;
		drop(index);
		if let Some(h) = gone {
			self.unlink(&h);
		}
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
		drop(index);
		if gone {
			self.unlink(&hash);
		}
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
	use super::successor;

	#[test]
	fn a_prefix_is_followed_by_its_last_byte_raised_past_every_highest_one() {
		assert_eq!(successor(b"a/"), Some(b"a0".to_vec()));
		assert_eq!(successor(&[b'a', 0xff, 0xff]), Some(b"b".to_vec()));
		assert_eq!(successor(&[0xff]), None);
		assert_eq!(successor(b""), None);
	}
}
