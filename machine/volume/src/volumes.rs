//! A binding's items' volumes, each a subvolume under `<mount>/<under>/<binding>/<item>`.

use std::fs;
use std::io;
use std::path::Path;

use crate::btrfs::own;
use crate::{Btrfs, Fault, Quotas, Subvolumes, Volume, Volumes, place, qgroup};

/// A file system's failure, what it did and to which path.
fn failed(doing: &str, path: &Path, e: &io::Error) -> Fault {
	Fault(format!("{doing} {}: {e}", path.display()))
}

/// Whether anything is at the path, a link not followed.
fn there(path: &Path) -> Result<bool, Fault> {
	match fs::symlink_metadata(path) {
		Ok(_) => Ok(true),
		Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
		Err(e) => Err(failed("read", path, &e)),
	}
}

/// Each entry of a directory named by an integer, in order, none where it is not there.
fn numbered(directory: &Path) -> Result<Vec<u32>, Fault> {
	let entries = match fs::read_dir(directory) {
		Ok(entries) => entries,
		Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
		Err(e) => return Err(failed("read", directory, &e)),
	};
	let mut numbers = Vec::new();
	for entry in entries {
		let name = entry.map_err(|e| failed("read", directory, &e))?.file_name();
		// Only a number in its own spelling is a binding or an item, so `07` is passed over.
		if let Some(n) =
			name.to_str().and_then(|n| n.parse::<u32>().ok().filter(|v| v.to_string() == n))
		{
			numbers.push(n);
		}
	}
	numbers.sort_unstable();
	Ok(numbers)
}

impl Btrfs {
	/// The own qgroup of the subvolume at `at`, refused where `at` is a directory of its parent's
	/// subvolume, so no limit ever reaches the mount's own.
	fn own_of(&self, at: &Path) -> Result<String, Fault> {
		let id = self.rootid(at)?;
		let parent = at.parent().unwrap_or(at);
		if self.rootid(parent)? == id {
			return Err(Fault(format!("{} is a directory, not a subvolume", at.display())));
		}
		Ok(own(id))
	}
}

impl Volumes for Btrfs {
	fn make(&self, under: &str, volume: Volume, size: u64) -> Result<std::path::PathBuf, Fault> {
		let at = place(&self.mount, under, volume);
		if !there(&at)? {
			let parent = at.parent().unwrap_or(&self.mount);
			fs::create_dir_all(parent).map_err(|e| failed("make", parent, &e))?;
			self.create(&at)?;
		}
		let own = self.own_of(&at)?;
		self.limit(&own, Some(size))?;
		self.member(&own, &qgroup(volume.binding))?;
		Ok(at)
	}

	fn list(&self, under: &str) -> Result<Vec<Volume>, Fault> {
		let root = self.mount.join(under);
		let mut volumes = Vec::new();
		for binding in numbered(&root)? {
			for item in numbered(&root.join(binding.to_string()))? {
				volumes.push(Volume { binding, item });
			}
		}
		Ok(volumes)
	}

	fn remove(&self, under: &str, volume: Volume) -> Result<(), Fault> {
		let at = place(&self.mount, under, volume);
		if there(&at)? {
			let own = self.own_of(&at)?;
			self.delete(&at)?;
			self.destroy(&own)?;
		}
		let parent = at.parent().unwrap_or(&self.mount);
		match fs::remove_dir(parent) {
			Ok(()) => Ok(()),
			Err(e) if matches!(e.kind(), io::ErrorKind::NotFound | io::ErrorKind::DirectoryNotEmpty) => {
				Ok(())
			}
			Err(e) => Err(failed("remove", parent, &e)),
		}
	}

	fn free(&self) -> Result<u64, Fault> {
		let stat = rustix::fs::statvfs(&self.mount)
			.map_err(|e| Fault(format!("statvfs {}: {e}", self.mount.display())))?;
		stat
			.f_bavail
			.checked_mul(stat.f_frsize)
			.ok_or_else(|| Fault(format!("{}: a size past 64 bits", self.mount.display())))
	}
}
