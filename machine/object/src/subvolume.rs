//! A bucket's subvolume made and removed by the `btrfs` command.
//! https://btrfs.readthedocs.io/en/latest/btrfs-subvolume.html

use std::ffi::OsStr;
use std::path::Path;
use std::process::Command;

use crate::{Btrfs, Fault, Subvolumes};

impl Btrfs {
	/// The command run, or what it wrote to its error when it failed.
	fn run(&self, args: &[&OsStr]) -> Result<(), Fault> {
		let shown = || {
			let words: Vec<_> = args.iter().map(|a| a.to_string_lossy()).collect();
			format!("btrfs {}", words.join(" "))
		};
		let output = Command::new(&self.binary)
			.args(args)
			.output()
			.map_err(|e| Fault(format!("{}: {e}", shown())))?;
		if output.status.success() {
			Ok(())
		} else {
			Err(Fault(format!("{}: {}", shown(), String::from_utf8_lossy(&output.stderr).trim())))
		}
	}
}

impl Subvolumes for Btrfs {
	fn create(&self, at: &Path) -> Result<(), Fault> {
		self.run(&["subvolume".as_ref(), "create".as_ref(), at.as_os_str()])
	}

	fn delete(&self, at: &Path) -> Result<(), Fault> {
		self.run(&["subvolume".as_ref(), "delete".as_ref(), at.as_os_str()])
	}
}
