//! A bundle read from its archive, and what is refused as none, RFC dg903.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use common::bundle;
use driver_machine_function::{Bundle, Kind, Unpack};

/// An archive of the files given, each by its name, as written.
fn archived(files: &[(&str, &[u8])]) -> Vec<u8> {
	let mut archive = tar::Builder::new(Vec::new());
	for (name, bytes) in files {
		let mut header = tar::Header::new_gnu();
		header.set_size(u64::try_from(bytes.len()).unwrap());
		header.set_mode(0o644);
		// Set directly, as `append_data` refuses a name holding `..` before it is written.
		header.as_gnu_mut().unwrap().name[..name.len()].copy_from_slice(name.as_bytes());
		header.set_cksum();
		archive.append(&header, *bytes).unwrap();
	}
	archive.into_inner().unwrap()
}

const METADATA: &[u8] = br#"{ "main_module": "main.js", "compatibility_date": "2026-10-21" }"#;

#[test]
fn a_bundle_is_its_main_module_first_then_the_rest_by_name() {
	let read = Bundle::unpack(&bundle("echo-modules")).unwrap();
	let names: Vec<(&str, Kind)> = read.modules.iter().map(|m| (m.name.as_str(), m.kind)).collect();
	assert_eq!(names, [("index.js", Kind::Es), ("lib/answer.js", Kind::Es)]);
	assert_eq!(read.compatibility_date, "2026-10-21");
	assert!(read.compatibility_flags.is_empty());
	let typed = archived(&[
		("metadata.json", METADATA),
		("z.wasm", b"\0asm"),
		("main.js", b""),
		("./a.cjs", b""),
		("b.txt", b""),
		("c.bin", b""),
		("d.json", b"{}"),
	]);
	let kinds: Vec<Kind> = Bundle::unpack(&typed).unwrap().modules.iter().map(|m| m.kind).collect();
	assert_eq!(kinds, [Kind::Es, Kind::CommonJs, Kind::Text, Kind::Data, Kind::Json, Kind::Wasm]);
}

#[test]
fn what_is_no_bundle_is_malformed() {
	let refused = |files: &[(&str, &[u8])]| Bundle::unpack(&archived(files)).map_err(|r| r.reason);
	assert_eq!(refused(&[("main.js", b"")]), Err("malformed"), "no metadata");
	assert_eq!(refused(&[("metadata.json", METADATA)]), Err("malformed"), "no main module");
	assert_eq!(refused(&[("metadata.json", b"{"), ("main.js", b"")]), Err("malformed"));
	let undated = br#"{ "main_module": "main.js", "compatibility_date": "October" }"#;
	assert_eq!(refused(&[("metadata.json", undated), ("main.js", b"")]), Err("malformed"));
	let flagged = br#"{ "main_module": "main.js", "compatibility_date": "2026-10-21",
		"compatibility_flags": [1] }"#;
	assert_eq!(refused(&[("metadata.json", flagged), ("main.js", b"")]), Err("malformed"));
	let typeless = [("metadata.json", METADATA), ("main.js", b"".as_slice()), ("x.py", b"")];
	assert_eq!(refused(&typeless), Err("malformed"), "a type no extension names");
	let outside = [("metadata.json", METADATA), ("main.js", b"".as_slice()), ("../x.js", b"")];
	assert_eq!(refused(&outside), Err("malformed"), "outside the bundle");
	let twice = [("metadata.json", METADATA), ("main.js", b"".as_slice()), ("./main.js", b"")];
	assert_eq!(refused(&twice), Err("malformed"), "one module twice");
	let mut linked = tar::Builder::new(Vec::new());
	let mut header = tar::Header::new_gnu();
	header.set_entry_type(tar::EntryType::Symlink);
	header.set_size(0);
	linked.append_link(&mut header, "main.js", "/etc/passwd").unwrap();
	let linked = linked.into_inner().unwrap();
	assert_eq!(Bundle::unpack(&linked).map_err(|r| r.reason), Err("malformed"), "a link");
	assert_eq!(Bundle::unpack(b"not a tar").map_err(|r| r.reason), Err("malformed"));
}
