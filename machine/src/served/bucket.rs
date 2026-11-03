//! Each `object_bucket` slot of an app's deployment served on a Unix socket of its own, made once
//! its deploy is answered and removed with the deployment, the forwarder's router on it, RFC ahcrp.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::PoisonError;

use driver_machine_function::{DATA, bucket_socket, bucketed, stored};
use envelope::Encoded as _;
use envelope::contracts::DeploymentRuns;

use super::forward;

/// Each slot's socket served, by its path, with the bucket it is filled with and the task serving
/// it.
struct Sockets(std::sync::Mutex<BTreeMap<PathBuf, (u32, tokio::task::AbortHandle)>>);

/// The slot sockets of this process's one driver.
static SOCKETS: Sockets = Sockets(std::sync::Mutex::new(BTreeMap::new()));

/// What a deployment's sockets are made from, kept in its directory so a start serves them again.
const FILL: &str = "fill.json";

/// A file at the path removed, one absent no failure.
fn removed(path: &Path) -> std::io::Result<()> {
	match std::fs::remove_file(path) {
		Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
		Ok(()) | Err(_) => Ok(()),
	}
}

/// A file removed, its failure told on stderr.
fn told(path: &Path) {
	if let Err(e) = removed(path) {
		eprintln!("bucket {}: {e}", path.display());
	}
}

/// The socket bound again in its directory, made 0755 so the app's user traverses it, and the
/// socket 0666 so that user connects, whatever the umask.
fn bound(path: &Path) -> std::io::Result<tokio::net::UnixListener> {
	use std::os::unix::fs::PermissionsExt;
	if let Some(directory) = path.parent() {
		std::fs::create_dir_all(directory)?;
		std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o755))?;
	}
	removed(path)?;
	let listener = tokio::net::UnixListener::bind(path)?;
	std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o666))?;
	Ok(listener)
}

/// Every socket file in a deployment's directory, one left from an earlier run among them.
fn listed(directory: &Path) -> Vec<PathBuf> {
	let Ok(entries) = std::fs::read_dir(directory) else { return Vec::new() };
	let sockets = entries.filter_map(Result::ok).map(|e| e.path());
	sockets.filter(|p| p.extension().is_some_and(|e| e == "sock")).collect()
}

/// A deployment's fill as its file keeps it, its runs and each slot's bucket.
fn written(runs: &DeploymentRuns, filled: &BTreeMap<String, u32>) -> Vec<u8> {
	let fill = serde_json::json!({ "runs": runs.to_json(), "bucket": filled });
	serde_json::to_vec(&fill).unwrap_or_default()
}

/// A deployment's fill read from its file's bytes, or why they hold none.
fn read(bytes: &[u8]) -> Result<(DeploymentRuns, BTreeMap<String, u32>), String> {
	let fill: serde_json::Value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
	let runs = fill.get("runs").ok_or("no runs")?;
	let runs = DeploymentRuns::from_json(runs).map_err(|e| format!("runs {e:?}"))?;
	let bucket = fill.get("bucket").and_then(serde_json::Value::as_object).ok_or("no bucket map")?;
	let id = |v: &serde_json::Value| v.as_u64().and_then(|n| u32::try_from(n).ok());
	let filled = bucket.iter().map(|(slot, v)| id(v).map(|id| (slot.clone(), id)));
	let filled = filled.collect::<Option<_>>().ok_or("a bucket id that is no u32")?;
	Ok((runs, filled))
}

/// An app deployment's sockets once its deploy is answered, one for each slot `bucket` fills, a
/// slot no longer filled losing its own, and the fill kept beside them; a component's makes none.
pub(super) fn deployed(
	slots: &Path,
	namespace: &str,
	runs: &DeploymentRuns,
	bucket: Option<&BTreeMap<String, u32>>,
) {
	let DeploymentRuns::App { .. } = runs else { return };
	let directory = bucketed(slots, namespace, runs);
	let named = bucket.cloned().unwrap_or_default();
	let filled: BTreeMap<PathBuf, u32> =
		named.iter().map(|(slot, id)| (directory.join(bucket_socket(slot)), *id)).collect();
	let mut sockets = SOCKETS.0.lock().unwrap_or_else(PoisonError::into_inner);
	let mut mine: BTreeSet<PathBuf> =
		sockets.keys().filter(|p| p.starts_with(&directory)).cloned().collect();
	mine.extend(listed(&directory));
	for path in mine {
		if !filled.contains_key(&path) {
			if let Some((_, task)) = sockets.remove(&path) {
				task.abort();
			}
			told(&path);
		}
	}
	let fill = directory.join(FILL);
	if filled.is_empty() {
		told(&fill);
	} else if let Err(e) =
		std::fs::create_dir_all(&directory).and_then(|()| std::fs::write(&fill, written(runs, &named)))
	{
		eprintln!("bucket {}: {e}", fill.display());
	}
	let data = stored(slots, namespace).join(DATA);
	for (path, id) in filled {
		let serving = sockets.get(&path).filter(|(held, task)| *held == id && !task.is_finished());
		if serving.is_some() {
			continue;
		}
		if let Some((_, task)) = sockets.remove(&path) {
			task.abort();
		}
		let listener = match bound(&path) {
			Ok(listener) => listener,
			Err(e) => {
				eprintln!("bucket {}: {e}", path.display());
				continue;
			}
		};
		let router = forward::router(data.clone(), id, runs.clone());
		let at = path.clone();
		let task = tokio::spawn(async move {
			if let Err(e) = axum::serve(listener, router).await {
				eprintln!("bucket {}: {e}", at.display());
			}
		});
		sockets.insert(path, (id, task.abort_handle()));
	}
}

/// Every app deployment of a binding whose fill its directory keeps served again, as a start does;
/// a fill not read told on stderr and passed over.
pub(super) fn restored(slots: &Path, namespace: &str) {
	let Ok(entries) = std::fs::read_dir(slots.join("apps").join(namespace)) else { return };
	for directory in entries.filter_map(Result::ok).map(|e| e.path()) {
		let fill = directory.join(FILL);
		let bytes = match std::fs::read(&fill) {
			Ok(bytes) => bytes,
			Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
			Err(e) => {
				eprintln!("bucket {}: {e}", fill.display());
				continue;
			}
		};
		match read(&bytes) {
			Ok((runs, filled)) if bucketed(slots, namespace, &runs) == directory => {
				deployed(slots, namespace, &runs, Some(&filled));
			}
			Ok(_) => eprintln!("bucket {}: its runs name another directory", fill.display()),
			Err(why) => eprintln!("bucket {}: {why}", fill.display()),
		}
	}
}

/// An app deployment's sockets once its delete is answered, every one gone with its directory.
pub(super) fn deleted(slots: &Path, namespace: &str, runs: &DeploymentRuns) {
	let DeploymentRuns::App { .. } = runs else { return };
	let directory = bucketed(slots, namespace, runs);
	let mut sockets = SOCKETS.0.lock().unwrap_or_else(PoisonError::into_inner);
	sockets.retain(|path, (_, task)| {
		let kept = !path.starts_with(&directory);
		if !kept {
			task.abort();
		}
		kept
	});
	match std::fs::remove_dir_all(&directory) {
		Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
			eprintln!("bucket {}: {e}", directory.display());
		}
		Ok(()) | Err(_) => {}
	}
}

#[cfg(test)]
mod tests {
	use std::collections::BTreeMap;
	use std::io::{Read as _, Write as _};
	use std::os::unix::fs::PermissionsExt as _;
	use std::path::{Path, PathBuf};

	use envelope::contracts::DeploymentRuns;

	use super::{deleted, deployed, read, restored};

	/// A directory of its own, short enough to hold a Unix socket's path below it, removed on drop.
	struct Directory(PathBuf);

	impl Directory {
		fn new() -> Self {
			static COUNT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
			let count = COUNT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
			let path = std::env::temp_dir().join(format!("bk{}-{count}", std::process::id()));
			std::fs::create_dir_all(&path).unwrap();
			Self(path)
		}
	}

	impl Drop for Directory {
		fn drop(&mut self) {
			let _ = std::fs::remove_dir_all(&self.0);
		}
	}

	const NAMESPACE: &str = "b00000001";

	fn filled(slots: &[(&str, u32)]) -> BTreeMap<String, u32> {
		slots.iter().map(|(n, id)| ((*n).to_owned(), *id)).collect()
	}

	fn mode(path: &Path) -> u32 {
		std::fs::metadata(path).unwrap().permissions().mode() & 0o777
	}

	/// The deployment's directory of sockets, as the driver names it under `slots`.
	fn directory(slots: &Path, runs: &DeploymentRuns) -> PathBuf {
		slots.join("apps").join(NAMESPACE).join(match runs {
			DeploymentRuns::App { id } => format!("{id:08x}"),
			DeploymentRuns::Component { component, id } => format!("{component}-{id:08x}"),
		})
	}

	/// The status line a request on the socket is answered with, read on a thread that may block.
	async fn answered(socket: PathBuf) -> String {
		tokio::task::spawn_blocking(move || {
			let mut stream = std::os::unix::net::UnixStream::connect(socket).unwrap();
			let head = "POST /storage/object_list HTTP/1.1\r\nHost: localhost\r\n\
				Connection: close\r\nContent-Length: 0\r\n\r\n";
			stream.write_all(head.as_bytes()).unwrap();
			let mut read = String::new();
			stream.read_to_string(&mut read).unwrap();
			read.lines().next().unwrap_or_default().to_owned()
		})
		.await
		.unwrap()
	}

	#[tokio::test]
	async fn a_deploy_filling_two_slots_makes_and_serves_two_sockets() {
		let slots = Directory::new();
		let runs = DeploymentRuns::App { id: 1 };
		deployed(&slots.0, NAMESPACE, &runs, Some(&filled(&[("a", 4), ("b", 5)])));
		let at = directory(&slots.0, &runs);
		assert_eq!(mode(&at), 0o755);
		for socket in ["a.sock", "b.sock"] {
			assert_eq!(mode(&at.join(socket)), 0o666);
			// Served by the forwarder's router, whatever it answers.
			assert!(answered(at.join(socket)).await.starts_with("HTTP/1.1 "));
		}
		let fill = std::fs::read(at.join("fill.json")).unwrap();
		assert_eq!(read(&fill).unwrap(), (runs.clone(), filled(&[("a", 4), ("b", 5)])));
		assert_eq!(std::fs::read_dir(&at).unwrap().count(), 3);
		deleted(&slots.0, NAMESPACE, &runs);
	}

	#[tokio::test]
	async fn a_deploy_filling_none_or_a_component_s_makes_none() {
		let slots = Directory::new();
		let runs = DeploymentRuns::App { id: 2 };
		deployed(&slots.0, NAMESPACE, &runs, None);
		deployed(&slots.0, NAMESPACE, &runs, Some(&filled(&[])));
		assert!(!directory(&slots.0, &runs).exists());
		let storage = DeploymentRuns::Component { component: "storage".into(), id: 3 };
		deployed(&slots.0, NAMESPACE, &storage, Some(&filled(&[("a", 4)])));
		assert!(!directory(&slots.0, &storage).exists());
		assert!(!slots.0.join("apps").exists());
	}

	#[tokio::test]
	async fn a_redeploy_with_a_slot_fewer_removes_that_one() {
		let slots = Directory::new();
		let runs = DeploymentRuns::App { id: 3 };
		let at = directory(&slots.0, &runs);
		// One left from an earlier run is removed as well.
		std::fs::create_dir_all(&at).unwrap();
		std::fs::write(at.join("old.sock"), b"").unwrap();
		deployed(&slots.0, NAMESPACE, &runs, Some(&filled(&[("a", 4), ("b", 5)])));
		assert!(!at.join("old.sock").exists());
		deployed(&slots.0, NAMESPACE, &runs, Some(&filled(&[("a", 6)])));
		let fill = std::fs::read(at.join("fill.json")).unwrap();
		assert_eq!(read(&fill).unwrap().1, filled(&[("a", 6)]));
		assert!(at.join("a.sock").exists());
		assert!(!at.join("b.sock").exists());
		assert!(answered(at.join("a.sock")).await.starts_with("HTTP/1.1 "));
		deployed(&slots.0, NAMESPACE, &runs, None);
		assert_eq!(std::fs::read_dir(&at).unwrap().count(), 0);
	}

	#[tokio::test]
	async fn a_delete_removes_every_socket_with_its_directory_and_no_other_s() {
		let slots = Directory::new();
		let runs = DeploymentRuns::App { id: 4 };
		let other = DeploymentRuns::App { id: 5 };
		deployed(&slots.0, NAMESPACE, &runs, Some(&filled(&[("a", 4), ("b", 5)])));
		deployed(&slots.0, NAMESPACE, &other, Some(&filled(&[("a", 4)])));
		deleted(&slots.0, NAMESPACE, &runs);
		assert!(!directory(&slots.0, &runs).exists());
		let kept = directory(&slots.0, &other).join("a.sock");
		assert!(answered(kept).await.starts_with("HTTP/1.1 "));
		// A delete of a deployment never deployed is no failure.
		deleted(&slots.0, NAMESPACE, &runs);
		deleted(&slots.0, NAMESPACE, &other);
	}

	#[test]
	fn a_fill_not_as_written_is_refused() {
		for bytes in [&b"{"[..], b"{}", br#"{"runs":{},"bucket":{}}"#] {
			assert!(read(bytes).is_err(), "{}", String::from_utf8_lossy(bytes));
		}
		let runs = envelope::Encoded::to_json(&DeploymentRuns::App { id: 1 });
		let large = serde_json::json!({ "runs": runs, "bucket": { "a": 4_294_967_296_u64 } });
		assert!(read(large.to_string().as_bytes()).is_err());
	}

	#[test]
	fn a_new_driver_serves_again_the_sockets_an_ended_one_made() {
		let slots = Directory::new();
		let runs = DeploymentRuns::App { id: 6 };
		let at = directory(&slots.0, &runs);
		let runtime = || tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
		let ended = runtime();
		ended.block_on(async {
			deployed(&slots.0, NAMESPACE, &runs, Some(&filled(&[("a", 4), ("b", 5)])));
		});
		drop(ended);
		assert!(std::os::unix::net::UnixStream::connect(at.join("a.sock")).is_err());
		runtime().block_on(async {
			restored(&slots.0, NAMESPACE);
			for socket in ["a.sock", "b.sock"] {
				assert!(answered(at.join(socket)).await.starts_with("HTTP/1.1 "));
			}
			deleted(&slots.0, NAMESPACE, &runs);
		});
	}
}
