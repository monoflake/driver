//! A bucket in a directory of its own, and each operation called as a sample writes it and answered
//! as the program answers it.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]
#![allow(dead_code, reason = "each test file uses its own part of what is here")]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

use driver_machine_object::{Bucket, Fault, Objects, Open, Unread, Unwritten};
use envelope::Encoded;
use envelope::contracts::{ObjectList, ObjectName, ObjectRead, ObjectWrite};
use serde_json::{Value, json};

static MADE: AtomicU32 = AtomicU32::new(0);

/// A directory of its own under cargo's, removed when dropped.
pub struct Directory(pub PathBuf);

impl Directory {
	pub fn new(name: &str) -> Self {
		let n = MADE.fetch_add(1, Ordering::Relaxed);
		let path = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
			.join(format!("driver-machine-object-{name}-{}-{n}", std::process::id()));
		let _ = std::fs::remove_dir_all(&path);
		std::fs::create_dir_all(&path).unwrap();
		Self(path)
	}

	pub fn path(&self) -> &Path {
		&self.0
	}
}

impl Drop for Directory {
	fn drop(&mut self) {
		let _ = std::fs::remove_dir_all(&self.0);
	}
}

/// A bucket opened in a directory of its own.
pub fn bucket(name: &str, capacity: Option<u64>) -> (Directory, Bucket) {
	let directory = Directory::new(name);
	let bucket = Bucket::open(directory.path(), capacity).unwrap();
	(directory, bucket)
}

fn success<O: Encoded>(output: &O) -> Value {
	json!({ "status": "success", "data": output.to_json() })
}

fn error(failure: &str, reason: &str, message: &str) -> Value {
	json!({ "status": "error", "failure": failure, "reason": reason, "message": message })
}

fn fault(f: &Fault) -> Value {
	error("unknown", "fault", &f.0)
}

/// An operation called with its input in JSON, `content` replaced by `bytes` where given, and
/// answered in JSON.
pub fn call(bucket: &Bucket, operation: &str, input: &Value, bytes: Option<Vec<u8>>) -> Value {
	match operation {
		"write" => {
			let mut write = ObjectWrite::from_json(input).unwrap();
			if let Some(content) = bytes {
				write.content = content;
			}
			match bucket.write(&write) {
				Ok(o) => success(&o),
				Err(Unwritten::TooLarge) => error("rejected", "too_large", ""),
				Err(Unwritten::StorageFull) => error("unavailable", "storage_full", ""),
				Err(Unwritten::Fault(f)) => fault(&f),
			}
		}
		"read" => match bucket.read(&ObjectRead::from_json(input).unwrap()) {
			Ok(o) => success(&o),
			Err(Unread::NotFound) => error("rejected", "not_found", ""),
			Err(Unread::Fault(f)) => fault(&f),
		},
		"describe" => match bucket.describe(&ObjectName::from_json(input).unwrap()) {
			Ok(o) => success(&o),
			Err(f) => fault(&f),
		},
		"delete" => match bucket.delete(&ObjectName::from_json(input).unwrap()) {
			Ok(o) => success(&o),
			Err(f) => fault(&f),
		},
		"list" => match bucket.list(&ObjectList::from_json(input).unwrap()) {
			Ok(o) => success(&o),
			Err(f) => fault(&f),
		},
		other => panic!("no operation {other} in object"),
	}
}

/// A call's output, which must be a success.
pub fn output(bucket: &Bucket, operation: &str, input: Value) -> Value {
	let answer = call(bucket, operation, &input, None);
	assert_eq!(answer["status"], "success", "{operation} {input} answered {answer}");
	answer["data"].clone()
}
