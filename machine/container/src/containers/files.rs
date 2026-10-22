//! The files a hosted runtime is given, written in the driver's state for each container and bound
//! read-only into it, so a reboot keeps them.

use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

use crate::Refused;

fn place(state: &Path, namespace: &str, id: &str) -> PathBuf {
	state.join("files").join(namespace).join(id)
}

fn failed(path: &Path, e: &std::io::Error) -> Refused {
	Refused::new("fault", format!("{}: {e}", path.display()))
}

/// A file's path below its directory, each part a name, never `..`, `.` or a root.
fn below(name: &str) -> Result<&Path, Refused> {
	let path = Path::new(name);
	let named = !name.is_empty() && path.components().all(|c| matches!(c, Component::Normal(_)));
	if named {
		Ok(path)
	} else {
		Err(Refused::new("malformed", format!("no file is named {name:?}")))
	}
}

/// The files written for a new container, in a directory of its own, which is answered.
pub(super) async fn write(
	state: &Path,
	namespace: &str,
	id: &str,
	files: &BTreeMap<String, Vec<u8>>,
) -> Result<PathBuf, Refused> {
	let directory = place(state, namespace, id);
	remove(state, namespace, id).await?;
	for (name, bytes) in files {
		let path = directory.join(below(name)?);
		if let Some(parent) = path.parent() {
			tokio::fs::create_dir_all(parent).await.map_err(|e| failed(parent, &e))?;
		}
		tokio::fs::write(&path, bytes).await.map_err(|e| failed(&path, &e))?;
	}
	tokio::fs::create_dir_all(&directory).await.map_err(|e| failed(&directory, &e))?;
	Ok(directory)
}

/// A container's files gone, none there being no failure.
pub(super) async fn remove(state: &Path, namespace: &str, id: &str) -> Result<(), Refused> {
	let directory = place(state, namespace, id);
	match tokio::fs::remove_dir_all(&directory).await {
		Ok(()) => Ok(()),
		Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
		Err(e) => Err(failed(&directory, &e)),
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_file_lies_below_its_directory_alone() {
		for name in ["config.capnp", "modules/index.js", "a/b/c.wasm"] {
			assert!(below(name).is_ok(), "{name}");
		}
		for name in ["", "/etc/passwd", "../x", "a/../../x", "./a"] {
			assert_eq!(below(name).map_err(|r| r.reason), Err("malformed"), "{name}");
		}
	}
}
