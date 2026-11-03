//! Writable socket directories emptied of stale sockets and given to the container's user.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use crate::Refused;

/// The extension a live socket is moved aside under while an older container still serves it.
const HELD: &str = "held";

fn failed(path: &Path, error: std::io::Error) -> Refused {
	Refused::new("fault", format!("{}: {error}", path.display()))
}

fn named(path: &Path, extension: &str) -> bool {
	path.extension().is_some_and(|named| named == extension)
}

/// Each directory made the container's user's alone and emptied of sockets. Where `held` is
/// given, an older container still serves them, so each is moved aside into it, never removed.
pub(super) async fn prepare(
	directories: &[PathBuf],
	uid: u32,
	gid: u32,
	mut held: Option<&mut Vec<PathBuf>>,
) -> Result<(), Refused> {
	for directory in directories {
		tokio::fs::DirBuilder::new()
			.recursive(true)
			.mode(0o700)
			.create(directory)
			.await
			.map_err(|e| failed(directory, e))?;
		tokio::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))
			.await
			.map_err(|e| failed(directory, e))?;
		std::os::unix::fs::chown(directory, Some(uid), Some(gid)).map_err(|e| failed(directory, e))?;
		let mut entries = tokio::fs::read_dir(directory).await.map_err(|e| failed(directory, e))?;
		let mut sockets = Vec::new();
		while let Some(entry) = entries.next_entry().await.map_err(|e| failed(directory, e))? {
			let path = entry.path();
			let set_aside =
				named(&path, HELD) && path.file_stem().is_some_and(|s| named(Path::new(s), "sock"));
			if (named(&path, "sock") || set_aside)
				&& !entry.file_type().await.map_err(|e| failed(&path, e))?.is_dir()
			{
				sockets.push((path, set_aside));
			}
		}
		for (path, set_aside) in sockets {
			match (&mut held, set_aside) {
				(Some(_), true) => {}
				(Some(held), false) => {
					let aside = path.with_extension(format!("sock.{HELD}"));
					tokio::fs::rename(&path, &aside).await.map_err(|e| failed(&path, e))?;
					held.push(aside);
				}
				(None, _) => tokio::fs::remove_file(&path).await.map_err(|e| failed(&path, e))?,
			}
		}
	}
	Ok(())
}

/// The sockets moved aside put back where they were, what a failed new container left there gone.
pub(super) async fn restore(held: &[PathBuf]) -> Result<(), Refused> {
	for aside in held {
		let path = aside.with_extension("");
		match tokio::fs::remove_file(&path).await {
			Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(failed(&path, e)),
			_ => {}
		}
		tokio::fs::rename(aside, &path).await.map_err(|e| failed(aside, e))?;
	}
	Ok(())
}

/// The sockets moved aside removed once the containers serving them are gone.
pub(super) async fn release(held: &[PathBuf]) -> Result<(), Refused> {
	for aside in held {
		match tokio::fs::remove_file(aside).await {
			Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(failed(aside, e)),
			_ => {}
		}
	}
	Ok(())
}
