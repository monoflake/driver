//! Each binding's database served on a Unix socket of its own, the call the binding's with no
//! token, made while its list holds the database and removed with it, RFC rt6gi.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, PoisonError};

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{HeaderMap, Method, Uri};
use axum::response::Response;
use driver_machine_container::Refused;
use driver_machine_function::DATABASE;
use driver_machine_management::Binding;
use envelope::contracts::AppBindings;

use super::{Caller, routed};
use crate::Driver;
use crate::listed::namespace;

/// Each socket served, by its path, and the task serving it.
struct Sockets(std::sync::Mutex<BTreeMap<PathBuf, tokio::task::AbortHandle>>);

/// The sockets of this process's one driver.
static SOCKETS: Sockets = Sockets(std::sync::Mutex::new(BTreeMap::new()));

/// A binding's database socket, `<slots>/<namespace>/database.sock`.
pub(super) fn socket(slots: &Path, binding: Binding) -> PathBuf {
	slots.join(namespace(binding)).join(DATABASE)
}

/// Every request on a binding's socket, answered as the binding's own and logged.
async fn route(
	State((driver, binding)): State<(Arc<Driver>, Binding)>,
	method: Method,
	uri: Uri,
	headers: HeaderMap,
	body: Body,
) -> Response {
	routed(driver, Caller::Slot(binding), method, uri, headers, body).await
}

/// A file at the path removed, one absent no failure.
fn removed(path: &Path) -> std::io::Result<()> {
	match std::fs::remove_file(path) {
		Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
		Ok(()) | Err(_) => Ok(()),
	}
}

/// The socket bound again in its own directory, one left from an earlier run replaced.
fn bound(path: &Path) -> std::io::Result<tokio::net::UnixListener> {
	if let Some(directory) = path.parent() {
		std::fs::create_dir_all(directory)?;
	}
	removed(path)?;
	let listener = tokio::net::UnixListener::bind(path)?;
	// workerd runs as its image's user, not root, and a connect needs write on the socket.
	std::fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(0o666))?;
	Ok(listener)
}

/// A binding's socket served while `holds`, its database held, and removed otherwise; each
/// failure told on stderr.
pub(super) fn kept(driver: &Arc<Driver>, binding: Binding, holds: bool) {
	let path = socket(&driver.functions.slots, binding);
	let mut sockets = SOCKETS.0.lock().unwrap_or_else(PoisonError::into_inner);
	if !holds {
		if let Some(task) = sockets.remove(&path) {
			task.abort();
		}
		if let Err(e) = removed(&path) {
			eprintln!("slot {}: {e}", path.display());
		}
		return;
	}
	if sockets.get(&path).is_some_and(|task| !task.is_finished()) {
		return;
	}
	let listener = match bound(&path) {
		Ok(listener) => listener,
		Err(e) => {
			eprintln!("slot {}: {e}", path.display());
			return;
		}
	};
	let router = Router::new().fallback(route).with_state((Arc::clone(driver), binding));
	let at = path.clone();
	let task = tokio::spawn(async move {
		if let Err(e) = axum::serve(listener, router).await {
			eprintln!("slot {}: {e}", at.display());
		}
	});
	sockets.insert(path, task.abort_handle());
}

/// A deploy's `bindings` within what the binding holds, each `database` slot its held item and no
/// `app` or `bucket` slot, as nothing serves them yet.
pub(super) fn filled(bindings: Option<&AppBindings>, held: Option<u32>) -> Result<(), Refused> {
	let Some(bindings) = bindings else { return Ok(()) };
	let invalid = |message: String| Refused { reason: "invalid", message: Some(message) };
	let unserved = [("app", &bindings.app), ("bucket", &bindings.bucket)];
	for (kind, slots) in unserved {
		if let Some(name) = slots.iter().flatten().map(|(name, _)| name).next() {
			let message =
				format!("the slot {name} is filled under {kind}, which a machine serves not yet");
			return Err(invalid(message));
		}
	}
	for (name, id) in bindings.database.iter().flatten() {
		if held != Some(*id) {
			let holding = held.map_or_else(|| "none".to_owned(), |h| format!("item {h}'s"));
			return Err(invalid(format!(
				"the slot {name} names the database {id}, and the binding holds {holding}"
			)));
		}
	}
	Ok(())
}

#[cfg(test)]
mod tests {
	use std::collections::BTreeMap;

	use envelope::contracts::AppBindings;

	use super::filled;

	fn named(slots: &[(&str, u32)]) -> Option<BTreeMap<String, u32>> {
		Some(slots.iter().map(|(n, id)| ((*n).to_owned(), *id)).collect())
	}

	#[test]
	fn a_deploy_s_bindings_are_held_to_the_database_the_binding_holds() {
		let database = |slots| AppBindings { app: None, database: named(slots), bucket: None };
		assert!(filled(None, None).is_ok());
		assert!(filled(Some(&database(&[])), None).is_ok());
		assert!(filled(Some(&database(&[("database", 3)])), Some(3)).is_ok());
		let refused = filled(Some(&database(&[("database", 4)])), Some(3)).unwrap_err();
		assert_eq!(refused.reason, "invalid");
		assert_eq!(
			refused.message.as_deref(),
			Some("the slot database names the database 4, and the binding holds item 3's")
		);
		let refused = filled(Some(&database(&[("database", 4)])), None).unwrap_err();
		assert_eq!(
			refused.message.as_deref(),
			Some("the slot database names the database 4, and the binding holds none")
		);
	}

	#[test]
	fn an_app_or_bucket_slot_is_refused_and_an_empty_map_is_not() {
		let app = AppBindings { app: named(&[("peer", 1)]), database: None, bucket: None };
		let refused = filled(Some(&app), None).unwrap_err();
		assert_eq!(refused.reason, "invalid");
		assert_eq!(
			refused.message.as_deref(),
			Some("the slot peer is filled under app, which a machine serves not yet")
		);
		let bucket = AppBindings { app: None, database: None, bucket: named(&[("files", 1)]) };
		assert_eq!(filled(Some(&bucket), None).unwrap_err().reason, "invalid");
		let empty = AppBindings { app: named(&[]), database: None, bucket: named(&[]) };
		assert!(filled(Some(&empty), None).is_ok());
	}
}
