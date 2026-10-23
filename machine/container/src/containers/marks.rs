//! A stop the driver was asked for, marked in its own state, a file per container, so a task that
//! ended without one is told apart as failed, and when each task was started.

use std::path::{Path, PathBuf};

use crate::Refused;

fn mark(state: &Path, namespace: &str, id: &str) -> PathBuf {
	state.join("stopped").join(namespace).join(id)
}

fn failed(path: &Path, e: &std::io::Error) -> Refused {
	Refused::new("fault", format!("{}: {e}", path.display()))
}

/// The stop marked, before it is made.
pub(super) async fn set(state: &Path, namespace: &str, id: &str) -> Result<(), Refused> {
	let path = mark(state, namespace, id);
	if let Some(parent) = path.parent() {
		tokio::fs::create_dir_all(parent).await.map_err(|e| failed(parent, &e))?;
	}
	tokio::fs::write(&path, b"").await.map_err(|e| failed(&path, &e))
}

/// The mark gone, none there being no failure.
pub(super) async fn clear(state: &Path, namespace: &str, id: &str) -> Result<(), Refused> {
	let path = mark(state, namespace, id);
	match tokio::fs::remove_file(&path).await {
		Ok(()) => Ok(()),
		Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
		Err(e) => Err(failed(&path, &e)),
	}
}

/// Whether a stop was asked for.
pub(super) async fn is_set(state: &Path, namespace: &str, id: &str) -> bool {
	tokio::fs::try_exists(mark(state, namespace, id)).await.unwrap_or(false)
}

fn start(state: &Path, namespace: &str, id: &str) -> PathBuf {
	state.join("started").join(namespace).join(id)
}

/// When its task was last started, in milliseconds since the epoch, kept beside its stop mark.
pub(super) async fn started(
	state: &Path,
	namespace: &str,
	id: &str,
	at: u64,
) -> Result<(), Refused> {
	let path = start(state, namespace, id);
	if let Some(parent) = path.parent() {
		tokio::fs::create_dir_all(parent).await.map_err(|e| failed(parent, &e))?;
	}
	tokio::fs::write(&path, at.to_string()).await.map_err(|e| failed(&path, &e))
}

/// When its task was last started, none where no start is marked.
pub(super) async fn started_at(state: &Path, namespace: &str, id: &str) -> Option<u64> {
	let text = tokio::fs::read_to_string(start(state, namespace, id)).await.ok()?;
	text.trim().parse().ok()
}

/// Its start's mark gone, none there being no failure.
pub(super) async fn unstarted(state: &Path, namespace: &str, id: &str) -> Result<(), Refused> {
	let path = start(state, namespace, id);
	match tokio::fs::remove_file(&path).await {
		Ok(()) => Ok(()),
		Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
		Err(e) => Err(failed(&path, &e)),
	}
}
