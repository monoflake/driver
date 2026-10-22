//! A bucket's subvolume, by the command each operation builds, run by a `btrfs` that only writes
//! down what it was asked.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};

use common::Directory;
use driver_machine_object::{Btrfs, Fault, Subvolumes};

/// A `btrfs` writing its arguments to `asked`, or failing as btrfs does.
fn btrfs(directory: &Path, fails: bool) -> Btrfs {
	let binary = directory.join("btrfs");
	let asked = directory.join("asked");
	let body = if fails {
		"echo 'ERROR: not a btrfs filesystem' >&2; exit 1".to_owned()
	} else {
		format!("echo \"$@\" >> '{}'", asked.display())
	};
	std::fs::write(&binary, format!("#!/bin/sh\n{body}\n")).unwrap();
	std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755)).unwrap();
	Btrfs { binary }
}

#[test]
fn a_subvolume_is_made_and_removed_by_the_btrfs_command() {
	let directory = Directory::new("subvolume");
	let btrfs = btrfs(directory.path(), false);
	let at = PathBuf::from("/data/buckets/7-2");
	btrfs.create(&at).unwrap();
	btrfs.delete(&at).unwrap();
	let asked = std::fs::read_to_string(directory.path().join("asked")).unwrap();
	assert_eq!(asked, "subvolume create /data/buckets/7-2\nsubvolume delete /data/buckets/7-2\n");
}

#[test]
fn a_failing_command_is_a_fault_naming_it_and_what_it_said() {
	let directory = Directory::new("failing");
	let failed = btrfs(directory.path(), true).create(Path::new("/data/b")).unwrap_err();
	assert_eq!(failed, Fault("btrfs subvolume create /data/b: ERROR: not a btrfs filesystem".into()));
}
