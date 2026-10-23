//! Subvolumes and quota groups by the `btrfs` command.
//! https://btrfs.readthedocs.io/en/latest/btrfs-subvolume.html
//! https://btrfs.readthedocs.io/en/latest/btrfs-qgroup.html

use std::ffi::OsStr;
use std::path::Path;
use std::process::Command;

use crate::{Btrfs, Fault, Quotas, Subvolumes};

impl Btrfs {
	/// The command run, and what it wrote, or what it wrote to its error when it failed.
	pub(crate) fn run(&self, args: &[&OsStr]) -> Result<String, Fault> {
		let shown = || {
			let words: Vec<_> = args.iter().map(|a| a.to_string_lossy()).collect();
			format!("btrfs {}", words.join(" "))
		};
		let output = Command::new(&self.binary)
			.args(args)
			.output()
			.map_err(|e| Fault(format!("{}: {e}", shown())))?;
		if output.status.success() {
			Ok(String::from_utf8_lossy(&output.stdout).into_owned())
		} else {
			Err(Fault(format!("{}: {}", shown(), String::from_utf8_lossy(&output.stderr).trim())))
		}
	}

	/// The id of the subvolume holding `at`, as `btrfs inspect-internal rootid` writes it.
	pub(crate) fn rootid(&self, at: &Path) -> Result<u64, Fault> {
		let written = self.run(&["inspect-internal".as_ref(), "rootid".as_ref(), at.as_os_str()])?;
		written.trim().parse().map_err(|_| Fault(format!("btrfs rootid wrote {written:?}")))
	}

	/// A qgroup command at the mount, its arguments before the mount's.
	fn qgroup(&self, args: &[&str]) -> Result<String, Fault> {
		let mut all: Vec<&OsStr> = vec!["qgroup".as_ref()];
		all.extend(args.iter().map(OsStr::new));
		all.push(self.mount.as_os_str());
		self.run(&all)
	}

	/// The qgroup made where it is not yet, so a binding's first subvolume makes it, RFC 4elqc.
	fn made(&self, qgroup: &str) -> Result<(), Fault> {
		match self.qgroup(&["create", qgroup]) {
			Ok(_) => Ok(()),
			Err(Fault(why)) if why.contains("File exists") => Ok(()),
			Err(fault) => Err(fault),
		}
	}

	/// A qgroup `0/<id>` made a member of another, made first where it is not.
	pub(crate) fn member(&self, own: &str, qgroup: &str) -> Result<(), Fault> {
		self.made(qgroup)?;
		match self.qgroup(&["assign", own, qgroup]) {
			Ok(_) => Ok(()),
			Err(Fault(why)) if why.contains("File exists") => Ok(()),
			Err(fault) => Err(fault),
		}
	}
}

/// A subvolume's own qgroup, `0/<its id>`.
pub(crate) fn own(id: u64) -> String {
	format!("0/{id}")
}

impl Subvolumes for Btrfs {
	fn create(&self, at: &Path) -> Result<(), Fault> {
		self.run(&["subvolume".as_ref(), "create".as_ref(), at.as_os_str()]).map(drop)
	}

	fn delete(&self, at: &Path) -> Result<(), Fault> {
		let id = self.rootid(at)?.to_string();
		// Committed at once, so the cleaner starts now and not at the next commit, 30 s on.
		let delete =
			["subvolume".as_ref(), "delete".as_ref(), "--commit-after".as_ref(), at.as_os_str()];
		self.run(&delete)?;
		// Deleting returns before the cleaner frees it, and its qgroup is held until then.
		let sync = ["subvolume".as_ref(), "sync".as_ref(), self.mount.as_os_str(), id.as_ref()];
		self.run(&sync).map(drop)
	}
}

impl Quotas for Btrfs {
	fn assign(&self, subvolume: &Path, qgroup: &str) -> Result<(), Fault> {
		self.member(&own(self.rootid(subvolume)?), qgroup)
	}

	fn limit(&self, qgroup: &str, bytes: Option<u64>) -> Result<(), Fault> {
		let size = bytes.map_or_else(|| "none".to_owned(), |b| b.to_string());
		self.qgroup(&["limit", &size, qgroup]).map(drop)
	}

	fn destroy(&self, qgroup: &str) -> Result<(), Fault> {
		// Simple quotas remove a deleted subvolume's own qgroup once it is cleaned.
		match self.qgroup(&["destroy", qgroup]) {
			Ok(_) => Ok(()),
			Err(Fault(why)) if why.contains("No such file or directory") => Ok(()),
			Err(fault) => Err(fault),
		}
	}
}
