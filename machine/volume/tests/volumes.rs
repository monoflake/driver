//! A binding's items' volumes made, listed and removed by the commands each operation builds, run
//! by a `btrfs` keeping subvolumes as marked directories, `tests/btrfs.sh`.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

use driver_machine_volume::{
	BUCKETS, Btrfs, Fault, Quotas, Subvolumes, VOLUMES, Volume, Volumes, place, qgroup,
};

static MADE: AtomicU32 = AtomicU32::new(0);

/// A mount of its own under cargo's temporary directory, its `btrfs` beside it, removed when
/// dropped.
struct Mount {
	directory: PathBuf,
	btrfs: Btrfs,
}

impl Mount {
	fn new(name: &str) -> Self {
		let n = MADE.fetch_add(1, Ordering::Relaxed);
		let directory = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
			.join(format!("driver-machine-volume-{name}-{}-{n}", std::process::id()));
		let _ = std::fs::remove_dir_all(&directory);
		let mount = directory.join("data");
		std::fs::create_dir_all(&mount).unwrap();
		std::fs::write(mount.join(".subvolume"), b"").unwrap();
		let binary = directory.join("btrfs");
		std::fs::copy(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/btrfs.sh"), &binary).unwrap();
		std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755)).unwrap();
		Self { directory, btrfs: Btrfs { mount, binary } }
	}

	/// Every command asked since the last call, the mount written `<mount>`.
	fn asked(&self) -> Vec<String> {
		let file = self.directory.join("asked");
		let text = std::fs::read_to_string(&file).unwrap_or_default();
		let _ = std::fs::remove_file(&file);
		let mount = self.btrfs.mount.display().to_string();
		text.lines().map(|l| l.replace(&mount, "<mount>")).collect()
	}

	/// The lines of a file the `btrfs` keeps, `qgroups` or `members`.
	fn kept(&self, name: &str) -> Vec<String> {
		let text = std::fs::read_to_string(self.directory.join(name)).unwrap_or_default();
		text.lines().map(str::to_owned).collect()
	}
}

impl Drop for Mount {
	fn drop(&mut self) {
		let _ = std::fs::remove_dir_all(&self.directory);
	}
}

const SEVEN_TWO: Volume = Volume { binding: 7, item: 2 };

#[test]
fn a_volume_is_a_subvolume_limited_to_its_size_in_its_binding_s_qgroup() {
	let mount = Mount::new("made");
	let at = mount.btrfs.make(VOLUMES, SEVEN_TWO, 1_048_576).unwrap();
	assert_eq!(at, mount.btrfs.mount.join("volumes/7/2"));
	assert!(at.join(".subvolume").exists());
	let asked = mount.asked();
	let own = asked[3].split(' ').nth(3).unwrap().to_owned();
	assert!(own.starts_with("0/"), "{asked:#?}");
	assert_eq!(
		asked,
		vec![
			"subvolume create <mount>/volumes/7/2".to_owned(),
			"inspect-internal rootid <mount>/volumes/7/2".to_owned(),
			"inspect-internal rootid <mount>/volumes/7".to_owned(),
			format!("qgroup limit 1048576 {own} <mount>"),
			"qgroup create 1/7 <mount>".to_owned(),
			format!("qgroup assign {own} 1/7 <mount>"),
		]
	);
	assert_eq!(mount.kept("members"), vec![format!("{own} 1/7")]);
}

#[test]
fn a_volume_made_again_is_limited_to_its_new_size_and_nothing_else_changes() {
	let mount = Mount::new("again");
	let at = mount.btrfs.make(VOLUMES, SEVEN_TWO, 1024).unwrap();
	std::fs::write(at.join("kept"), b"kept").unwrap();
	mount.asked();
	mount.btrfs.make(VOLUMES, SEVEN_TWO, 2048).unwrap();
	let asked = mount.asked();
	assert!(!asked.iter().any(|a| a.starts_with("subvolume create")), "{asked:#?}");
	assert!(asked.iter().any(|a| a.starts_with("qgroup limit 2048 0/")), "{asked:#?}");
	assert_eq!(std::fs::read(at.join("kept")).unwrap(), b"kept");
	assert_eq!(mount.kept("qgroups"), vec!["1/7".to_owned()]);
}

#[test]
fn volumes_and_buckets_are_listed_apart_and_in_order() {
	let mount = Mount::new("listed");
	assert_eq!(mount.btrfs.list(VOLUMES).unwrap(), Vec::new());
	for (binding, item) in [(9, 1), (7, 10), (7, 2)] {
		mount.btrfs.make(VOLUMES, Volume { binding, item }, 1024).unwrap();
	}
	mount.btrfs.make(BUCKETS, Volume { binding: 7, item: 3 }, 1024).unwrap();
	std::fs::create_dir_all(mount.btrfs.mount.join("volumes/notes")).unwrap();
	let listed = mount.btrfs.list(VOLUMES).unwrap();
	let pairs: Vec<_> = listed.iter().map(|v| (v.binding, v.item)).collect();
	assert_eq!(pairs, vec![(7, 2), (7, 10), (9, 1)]);
	assert_eq!(mount.btrfs.list(BUCKETS).unwrap(), vec![Volume { binding: 7, item: 3 }]);
}

#[test]
fn a_volume_removed_takes_its_qgroup_and_its_binding_s_directory_once_empty() {
	let mount = Mount::new("removed");
	mount.btrfs.make(VOLUMES, SEVEN_TWO, 1024).unwrap();
	mount.btrfs.make(VOLUMES, Volume { binding: 7, item: 3 }, 1024).unwrap();
	mount.asked();
	mount.btrfs.remove(VOLUMES, SEVEN_TWO).unwrap();
	let asked = mount.asked();
	let id = asked[4].split(' ').nth(3).unwrap().to_owned();
	assert_eq!(
		asked,
		vec![
			"inspect-internal rootid <mount>/volumes/7/2".to_owned(),
			"inspect-internal rootid <mount>/volumes/7".to_owned(),
			"inspect-internal rootid <mount>/volumes/7/2".to_owned(),
			"subvolume delete --commit-after <mount>/volumes/7/2".to_owned(),
			format!("subvolume sync <mount> {id}"),
			format!("qgroup destroy 0/{id} <mount>"),
		]
	);
	assert!(mount.btrfs.mount.join("volumes/7").exists());
	mount.btrfs.remove(VOLUMES, Volume { binding: 7, item: 3 }).unwrap();
	assert!(!mount.btrfs.mount.join("volumes/7").exists());
	assert!(mount.btrfs.mount.join("volumes").exists());
	// One absent is no failure, and asks btrfs nothing.
	mount.asked();
	mount.btrfs.remove(VOLUMES, SEVEN_TWO).unwrap();
	assert_eq!(mount.asked(), Vec::<String>::new());
}

#[test]
fn a_directory_that_is_no_subvolume_is_never_limited() {
	let mount = Mount::new("directory");
	let at = place(&mount.btrfs.mount, VOLUMES, SEVEN_TWO);
	std::fs::create_dir_all(&at).unwrap();
	let refused = mount.btrfs.make(VOLUMES, SEVEN_TWO, 1024).unwrap_err();
	assert!(refused.0.ends_with("volumes/7/2 is a directory, not a subvolume"), "{refused:?}");
	assert!(!mount.asked().iter().any(|a| a.starts_with("qgroup")));
}

#[test]
fn a_binding_s_qgroup_is_destroyed_once_and_absent_after() {
	let mount = Mount::new("destroyed");
	mount.btrfs.make(VOLUMES, SEVEN_TWO, 1024).unwrap();
	mount.btrfs.remove(VOLUMES, SEVEN_TWO).unwrap();
	mount.btrfs.destroy(&qgroup(7)).unwrap();
	mount.btrfs.destroy(&qgroup(7)).unwrap();
	assert_eq!(mount.kept("qgroups"), Vec::<String>::new());
}

#[test]
fn a_subvolume_assigned_twice_is_assigned_once() {
	let mount = Mount::new("assigned");
	let at = mount.btrfs.mount.join("snapshot");
	mount.btrfs.create(&at).unwrap();
	mount.btrfs.assign(&at, "1/7").unwrap();
	mount.btrfs.assign(&at, "1/7").unwrap();
	assert_eq!(mount.kept("members").len(), 1);
	mount.btrfs.limit("1/7", None).unwrap();
	assert_eq!(mount.asked().last().unwrap(), "qgroup limit none 1/7 <mount>");
}

#[test]
fn a_failing_command_is_a_fault_naming_it_and_what_it_said() {
	let mount = Mount::new("failing");
	let outside = Btrfs { mount: PathBuf::from("/"), binary: mount.btrfs.binary.clone() };
	let failed = outside.delete(Path::new("/nowhere")).unwrap_err();
	assert_eq!(
		failed,
		Fault("btrfs inspect-internal rootid /nowhere: ERROR: not a btrfs filesystem: /nowhere".into())
	);
}

#[test]
fn the_free_space_is_the_mount_s() {
	let mount = Mount::new("free");
	assert!(mount.btrfs.free().unwrap() > 0);
	let gone = Btrfs { mount: mount.directory.join("absent"), binary: mount.btrfs.binary.clone() };
	assert!(gone.free().unwrap_err().0.starts_with("statvfs "));
}
