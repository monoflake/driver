//! What the samples do not reach, a write cut short, a range at and past the end, the names at the
//! edges of a string, contents held once, and a page no longer than the contract's.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::path::Path;

use common::{bucket, call, output};
use driver_machine_object::{Bucket, CONTENTS, INDEX, Open, PAGE, WRITING};
use serde_json::{Value, json};

/// Each file in a bucket's contents, by name.
fn files(directory: &Path) -> Vec<String> {
	let mut names: Vec<String> = std::fs::read_dir(directory.join(CONTENTS))
		.unwrap()
		.map(|e| e.unwrap().file_name().into_string().unwrap())
		.collect();
	names.sort();
	names
}

/// Content in base64url, unpadded, as the contract writes bytes.
fn encoded(bytes: &[u8]) -> String {
	let content = envelope::contracts::ObjectContent {
		content: bytes.to_vec(),
		size: envelope::Bounded::new(0).unwrap(),
	};
	envelope::Encoded::to_json(&content)["content"].as_str().unwrap().to_owned()
}

fn write(bucket: &Bucket, name: &str, content: &[u8]) {
	output(bucket, "write", json!({ "name": name, "content": encoded(content) }));
}

fn names(listed: &Value) -> Vec<String> {
	listed["objects"].as_array().unwrap().iter().map(|o| o["name"].as_str().unwrap().into()).collect()
}

#[test]
fn a_write_cut_between_its_rename_and_its_commit_leaves_no_object() {
	let (directory, held) = bucket("cut", None);
	write(&held, "kept", b"kept");
	drop(held);
	// A content renamed into place whose row was never committed, and one still being written.
	let content = b"never committed";
	let hash = blake3::hash(content).to_hex();
	std::fs::write(directory.path().join(CONTENTS).join(hash.as_str()), content).unwrap();
	std::fs::write(directory.path().join(WRITING).join(hash.as_str()), b"never").unwrap();
	let bucket = Bucket::open(directory.path(), None).unwrap();
	assert_eq!(names(&output(&bucket, "list", json!({ "prefix": "" }))), ["kept"]);
	assert_eq!(files(directory.path()), [blake3::hash(b"kept").to_hex().to_string()]);
	assert_eq!(std::fs::read_dir(directory.path().join(WRITING)).unwrap().count(), 0);
	// The same content written again is held whole.
	write(&bucket, "now", content);
	let read = output(&bucket, "read", json!({ "name": "now" }));
	assert_eq!(read, json!({ "content": encoded(content), "size": 15 }));
}

#[test]
fn a_bucket_opened_again_holds_what_was_written() {
	let (directory, held) = bucket("again", Some(10));
	write(&held, "a", b"hello");
	drop(held);
	assert!(directory.path().join(INDEX).exists());
	let bucket = Bucket::open(directory.path(), Some(10)).unwrap();
	assert_eq!(output(&bucket, "describe", json!({ "name": "a" })), json!({ "size": 5 }));
	// What was held counts again, so six bytes more is past ten.
	let answer = call(&bucket, "write", &json!({ "name": "b", "content": encoded(b"world!") }), None);
	assert_eq!(answer["reason"], "storage_full");
}

#[test]
fn a_range_at_or_past_the_end_is_cut_there() {
	let (_directory, bucket) = bucket("ranges", None);
	write(&bucket, "a", b"hello");
	let read = |start: u64, length: u64| {
		let input = json!({ "name": "a", "range": { "start": start, "length": length } });
		output(&bucket, "read", input)
	};
	assert_eq!(read(10, 1), json!({ "content": "", "size": 5 }));
	assert_eq!(read(2, 0), json!({ "content": "", "size": 5 }));
	let most = (1_u64 << 53) - 1;
	assert_eq!(read(0, most), json!({ "content": encoded(b"hello"), "size": 5 }));
	assert_eq!(read(most, most), json!({ "content": "", "size": 5 }));
	assert_eq!(read(4, most), json!({ "content": encoded(b"o"), "size": 5 }));
}

#[test]
fn a_name_at_the_edges_of_a_string_is_held_and_listed_in_byte_order() {
	let (_directory, bucket) = bucket("names", None);
	let long = "x".repeat(65_536);
	let edges = ["", "\u{0}", "a", "a\u{0}", "a/", "a/\u{10ffff}", "b", "\u{e9}", long.as_str()];
	for (n, name) in edges.iter().enumerate() {
		write(&bucket, name, format!("content {n}").as_bytes());
	}
	for (n, name) in edges.iter().enumerate() {
		let read = output(&bucket, "read", json!({ "name": name }));
		assert_eq!(read["content"], encoded(format!("content {n}").as_bytes()));
	}
	let mut sorted: Vec<&str> = edges.to_vec();
	sorted.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
	assert_eq!(names(&output(&bucket, "list", json!({ "prefix": "" }))), sorted);
	let under_a = names(&output(&bucket, "list", json!({ "prefix": "a" })));
	assert_eq!(under_a, ["a", "a\u{0}", "a/", "a/\u{10ffff}"]);
	assert_eq!(names(&output(&bucket, "list", json!({ "prefix": "a/" }))), ["a/", "a/\u{10ffff}"]);
	// After the empty name is every name but itself, and after one outside the prefix is the prefix.
	let after_empty = names(&output(&bucket, "list", json!({ "prefix": "", "after": "" })));
	assert_eq!(after_empty, sorted[1..]);
	let after_before = names(&output(&bucket, "list", json!({ "prefix": "a/", "after": "a" })));
	assert_eq!(after_before, ["a/", "a/\u{10ffff}"]);
	let after_past = output(&bucket, "list", json!({ "prefix": "a/", "after": "b" }));
	assert_eq!(after_past, json!({ "objects": [] }));
	output(&bucket, "delete", json!({ "name": "" }));
	assert_eq!(output(&bucket, "describe", json!({ "name": "" })), json!({}));
}

#[test]
fn a_content_is_held_once_and_removed_with_its_last_name() {
	let (directory, bucket) = bucket("once", Some(10));
	let file = |content: &[u8]| blake3::hash(content).to_hex().to_string();
	write(&bucket, "a", b"hello");
	write(&bucket, "b", b"hello");
	assert_eq!(files(directory.path()), [file(b"hello")]);
	write(&bucket, "a", b"world");
	assert_eq!(files(directory.path()).len(), 2, "b still holds hello");
	// Ten bytes are held, so this fits only as the content it replaces is freed.
	write(&bucket, "a", b"again");
	let mut left = vec![file(b"hello"), file(b"again")];
	left.sort();
	assert_eq!(files(directory.path()), left);
	output(&bucket, "delete", json!({ "name": "b" }));
	assert_eq!(files(directory.path()), [file(b"again")]);
	output(&bucket, "delete", json!({ "name": "a" }));
	assert!(files(directory.path()).is_empty());
}

#[test]
fn a_page_holds_at_most_the_contracts_thousand() {
	let (_directory, bucket) = bucket("page", None);
	let count = usize::try_from(PAGE).unwrap() + 1;
	for n in 0..count {
		write(&bucket, &format!("n/{n:05}"), b"same");
	}
	let first = output(&bucket, "list", json!({ "prefix": "n/", "limit": 4_000_000_000_u32 }));
	assert_eq!(names(&first).len(), count - 1);
	assert_eq!(first["next"], "n/00999");
	let rest = output(&bucket, "list", json!({ "prefix": "n/", "after": first["next"] }));
	assert_eq!(rest, json!({ "objects": [{ "name": "n/01000", "size": 4 }] }));
}

#[test]
fn a_write_whose_commit_fails_leaves_no_file_behind() {
	let (directory, bucket) = bucket("refused", None);
	// A trigger of the test's own makes the index refuse one name, after its content is put.
	let other = rusqlite::Connection::open(directory.path().join(INDEX)).unwrap();
	other
		.execute_batch(
			"CREATE TRIGGER refused BEFORE INSERT ON objects WHEN NEW.name = X'726566' \
			BEGIN SELECT RAISE(ABORT, 'refused'); END;",
		)
		.unwrap();
	drop(other);
	let answer = call(&bucket, "write", &json!({ "name": "ref", "content": encoded(b"lost") }), None);
	assert_eq!(answer["reason"], "fault", "{answer}");
	assert!(files(directory.path()).is_empty());
	assert_eq!(std::fs::read_dir(directory.path().join(WRITING)).unwrap().count(), 0);
	assert_eq!(output(&bucket, "describe", json!({ "name": "ref" })), json!({}));
}

#[test]
fn a_write_whose_rename_fails_leaves_nothing_being_written() {
	let (directory, bucket) = bucket("unrenamed", None);
	// A directory where the content's file would go, so the rename into place fails.
	let content = b"blocked";
	let hash = blake3::hash(content).to_hex();
	std::fs::create_dir(directory.path().join(CONTENTS).join(hash.as_str())).unwrap();
	std::fs::write(directory.path().join(CONTENTS).join(hash.as_str()).join("in"), b"").unwrap();
	let answer = call(&bucket, "write", &json!({ "name": "a", "content": encoded(content) }), None);
	assert_eq!(answer["reason"], "fault", "{answer}");
	assert_eq!(std::fs::read_dir(directory.path().join(WRITING)).unwrap().count(), 0);
}

#[test]
fn an_object_whose_content_file_is_lost_is_gone_once_opened_again() {
	let (directory, held) = bucket("lost", Some(10));
	write(&held, "a", b"hello");
	write(&held, "b", b"hello");
	write(&held, "c", b"kept");
	drop(held);
	let hash = blake3::hash(b"hello").to_hex();
	std::fs::remove_file(directory.path().join(CONTENTS).join(hash.as_str())).unwrap();
	let bucket = Bucket::open(directory.path(), Some(10)).unwrap();
	assert_eq!(output(&bucket, "describe", json!({ "name": "a" })), json!({}));
	assert_eq!(call(&bucket, "read", &json!({ "name": "b" }), None)["reason"], "not_found");
	assert_eq!(names(&output(&bucket, "list", json!({ "prefix": "" }))), ["c"]);
	// The five bytes lost are no longer held, so six more fit beside the four kept.
	write(&bucket, "d", b"world!");
	output(&bucket, "delete", json!({ "name": "d" }));
	// The same bytes written again are put again rather than taken for held.
	write(&bucket, "a", b"hello");
	let read = output(&bucket, "read", json!({ "name": "a" }));
	assert_eq!(read, json!({ "content": encoded(b"hello"), "size": 5 }));
}
