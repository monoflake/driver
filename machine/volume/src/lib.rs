//! `driver(machine)`'s volume, a binding's item as a btrfs subvolume under a quota group's limit,
//! which a bucket and a container's layer stand on too, RFC 54q45. This file is its interface, the
//! model's, `docs/code.md`.

use std::path::{Path, PathBuf};

mod btrfs;
mod volumes;

/// Where a `volume` item's volume lies under the mount, `<mount>/volumes/<binding>/<item>`.
pub const VOLUMES: &str = "volumes";

/// Where an `object` item's bucket lies under the mount, `<mount>/buckets/<binding>/<item>`.
pub const BUCKETS: &str = "buckets";

/// What btrfs could not do at a moment, answered `fault`, RFC ge55b.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fault(pub String);

/// A binding's item made a volume, by their integers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Volume {
	/// The binding, by its `capacity` space's integer.
	pub binding: u32,
	/// The item, by its id in the binding's list.
	pub item: u32,
}

/// btrfs at the mount the workloads lie on, by its `btrfs` command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Btrfs {
	/// The mount, `/data`.
	pub mount: PathBuf,
	/// The `btrfs` binary.
	pub binary: PathBuf,
}

/// Subvolumes made and removed; implemented for [`Btrfs`].
pub trait Subvolumes {
	/// A subvolume made at `at`, its parent a directory of the mount.
	fn create(&self, at: &Path) -> Result<(), Fault>;
	/// The subvolume at `at` removed with everything in it, waited on until btrfs has cleaned it.
	fn delete(&self, at: &Path) -> Result<(), Fault>;
}

/// Quota groups, btrfs's simple quotas at the mount; implemented for [`Btrfs`].
pub trait Quotas {
	/// A subvolume's own qgroup made a member of `qgroup`, which is made first where it is not,
	/// while nothing is written in the subvolume yet; one a member already is no failure.
	fn assign(&self, subvolume: &Path, qgroup: &str) -> Result<(), Fault>;
	/// A qgroup's limit of the bytes it references set, none for no limit.
	fn limit(&self, qgroup: &str, bytes: Option<u64>) -> Result<(), Fault>;
	/// A qgroup removed; one absent is no failure.
	fn destroy(&self, qgroup: &str) -> Result<(), Fault>;
}

/// A binding's items' volumes made, listed and removed, each under [`VOLUMES`] or [`BUCKETS`];
/// implemented for [`Btrfs`].
pub trait Volumes {
	/// The volume made where it is not, its own qgroup limited to `size` bytes and a member of its
	/// binding's [`qgroup`]; its directory. One made already is limited to `size` again.
	fn make(&self, under: &str, volume: Volume, size: u64) -> Result<PathBuf, Fault>;
	/// Every volume under `under`, in order; none where nothing was made there yet.
	fn list(&self, under: &str) -> Result<Vec<Volume>, Fault>;
	/// The volume removed with its own qgroup, and its binding's directory once that is empty; one
	/// absent is no failure.
	fn remove(&self, under: &str, volume: Volume) -> Result<(), Fault>;
	/// The bytes free on the mount's file system.
	fn free(&self) -> Result<u64, Fault>;
}

/// A volume's directory, `<mount>/<under>/<binding>/<item>`.
#[must_use]
pub fn place(mount: &Path, under: &str, volume: Volume) -> PathBuf {
	mount.join(under).join(volume.binding.to_string()).join(volume.item.to_string())
}

/// A binding's qgroup above every subvolume it holds, `1/<binding>`, as RFC 4elqc proposes.
#[must_use]
pub fn qgroup(binding: u32) -> String {
	format!("1/{binding}")
}
