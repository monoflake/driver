//! Writable socket directories emptied of stale sockets and given to the container's user.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use crate::Refused;

fn failed(path: &Path, error: std::io::Error) -> Refused {
	Refused::new("fault", format!("{}: {error}", path.display()))
}

pub(super) async fn prepare(directories: &[PathBuf], uid: u32, gid: u32) -> Result<(), Refused> {
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
		while let Some(entry) = entries.next_entry().await.map_err(|e| failed(directory, e))? {
			let path = entry.path();
			if path.extension().is_some_and(|extension| extension == "sock")
				&& !entry.file_type().await.map_err(|e| failed(&path, e))?.is_dir()
			{
				tokio::fs::remove_file(&path).await.map_err(|e| failed(&path, e))?;
			}
		}
	}
	Ok(())
}
