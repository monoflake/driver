//! Each binding's database and bucket served each on a Unix socket of its own, the call the
//! binding's with no token, made while its list holds the item and removed with it, RFCs rt6gi and
//! ahcrp.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, PoisonError};

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{HeaderMap, Method, Uri};
use axum::response::Response;
use driver_machine_container::Refused;
use driver_machine_function::{
	OBJECT_SOCKET, database_socket, database_status_socket, objected, slotted,
};
use driver_machine_management::Binding;
use envelope::contracts::{AppBindings, DeploymentForm};

use super::{Caller, routed};
use crate::{Driver, Listed};

/// The items a binding holds that a deploy's slots may name, by their ids.
#[derive(Debug, Clone, Default)]
pub(super) struct Held {
	pub databases: Vec<u32>,
	pub bucket: Option<u32>,
}

/// What a binding's list holds that a slot may name.
pub(super) fn held(listed: &Listed) -> Held {
	Held {
		databases: listed.databases.keys().copied().collect(),
		bucket: listed.bucket.as_ref().map(|(id, _)| *id),
	}
}

/// Each socket served, by its path, and the task serving it.
struct Sockets(std::sync::Mutex<BTreeMap<PathBuf, tokio::task::AbortHandle>>);

/// The sockets of this process's one driver.
static SOCKETS: Sockets = Sockets(std::sync::Mutex::new(BTreeMap::new()));

/// A binding's object socket, `<slots>/object/<namespace>/object.sock`, in `Listed::namespaced`.
fn object_socket(slots: &Path, namespace: &str) -> PathBuf {
	objected(slots, namespace).join(OBJECT_SOCKET)
}

/// Every request on a binding's socket, answered as the binding's own on its one interface.
async fn route(
	State((driver, binding, interface, item)): State<(
		Arc<Driver>,
		Binding,
		&'static str,
		Option<u32>,
	)>,
	method: Method,
	uri: Uri,
	headers: HeaderMap,
	body: Body,
) -> Response {
	routed(driver, Caller::Slot(binding, interface, item), method, uri, headers, body).await
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
	use std::os::unix::fs::PermissionsExt;
	// workerd runs as its image's user, not root, so it traverses the directory and writes the
	// socket to connect, whatever the umask.
	if let Some(directory) = path.parent() {
		std::fs::create_dir_all(directory)?;
		std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o755))?;
	}
	removed(path)?;
	let listener = tokio::net::UnixListener::bind(path)?;
	std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o666))?;
	Ok(listener)
}

/// A file removed, its failure told on stderr.
fn told(path: &Path) {
	if let Err(e) = removed(path) {
		eprintln!("slot {}: {e}", path.display());
	}
}

/// A binding's sockets in `namespace`, `Listed::namespaced`, the database one served while its
/// database is held and the object one while its bucket is, each removed otherwise.
pub(super) fn kept(driver: &Arc<Driver>, binding: Binding, namespace: &str, held: Held) {
	let slots = &driver.functions.slots;
	let directory = slotted(slots, namespace);
	let paths: Vec<_> = held
		.databases
		.iter()
		.flat_map(|id| {
			[database_socket(slots, namespace, *id), database_status_socket(slots, namespace, *id)]
		})
		.collect();
	let stale: Vec<_> = std::fs::read_dir(&directory)
		.into_iter()
		.flatten()
		.flatten()
		.map(|entry| entry.path())
		.filter(|path| {
			path
				.file_name()
				.and_then(|name| name.to_str())
				.is_some_and(|name| name.starts_with("database-") && name.ends_with(".sock"))
				&& !paths.contains(path)
		})
		.collect();
	for path in stale {
		served(driver, binding, path, "database", None, false);
	}
	for id in held.databases {
		served(driver, binding, database_socket(slots, namespace, id), "database", Some(id), true);
		let status = database_status_socket(slots, namespace, id);
		served(driver, binding, status, "database-status", Some(id), true);
	}
	served(driver, binding, object_socket(slots, namespace), "object", None, held.bucket.is_some());
}

/// One socket of a binding served on its one interface while `holds`, and removed otherwise; each
/// failure told on stderr.
fn served(
	driver: &Arc<Driver>,
	binding: Binding,
	path: PathBuf,
	interface: &'static str,
	item: Option<u32>,
	holds: bool,
) {
	let mut sockets = SOCKETS.0.lock().unwrap_or_else(PoisonError::into_inner);
	if !holds {
		if let Some(task) = sockets.remove(&path) {
			task.abort();
		}
		told(&path);
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
	let router =
		Router::new().fallback(route).with_state((Arc::clone(driver), binding, interface, item));
	let at = path.clone();
	let task = tokio::spawn(async move {
		if let Err(e) = axum::serve(listener, router).await {
			eprintln!("slot {}: {e}", at.display());
		}
	});
	sockets.insert(path, task.abort_handle());
}

/// A deploy's `bindings` within what the binding holds, each `database` slot its held item, each
/// `bucket` slot an object item held, no `app` slot, and none on a form declaring no slot.
pub(super) fn filled(
	bindings: Option<&AppBindings>,
	held: Held,
	form: DeploymentForm,
) -> Result<(), Refused> {
	let Some(bindings) = bindings else { return Ok(()) };
	let invalid = |message: String| Refused { reason: "invalid", message: Some(message) };
	let named = [&bindings.app, &bindings.database, &bindings.bucket];
	let first = named.into_iter().flatten().flat_map(|slots| slots.keys()).next();
	if let (Some(name), DeploymentForm::Image | DeploymentForm::Component) = (first, form) {
		let message = format!("the slot {name} is filled on a {form:?} deploy, which declares no slot");
		return Err(invalid(message));
	}
	if let Some(name) = bindings.app.iter().flatten().map(|(name, _)| name).next() {
		let message = format!("the slot {name} is filled under app, which a machine serves not yet");
		return Err(invalid(message));
	}
	for (name, id) in bindings.database.iter().flatten() {
		if !held.databases.contains(id) {
			let holding = if held.databases.is_empty() {
				"none".to_owned()
			} else {
				held.databases.iter().map(|h| format!("item {h}'s")).collect::<Vec<_>>().join(", ")
			};
			return Err(invalid(format!(
				"the slot {name} names the database {id}, and the binding holds {holding}"
			)));
		}
	}
	// The bucket id is the storage product's own, so only an object item held is asked here.
	if held.bucket.is_none()
		&& let Some(name) = bindings.bucket.iter().flatten().map(|(name, _)| name).next()
	{
		let message =
			format!("the slot {name} is filled under bucket, and the binding holds no object");
		return Err(invalid(message));
	}
	Ok(())
}

#[cfg(test)]
mod tests {
	use std::collections::BTreeMap;

	use envelope::contracts::{AppBindings, DeploymentForm};

	use super::{Held, filled};

	fn named(slots: &[(&str, u32)]) -> Option<BTreeMap<String, u32>> {
		Some(slots.iter().map(|(n, id)| ((*n).to_owned(), *id)).collect())
	}

	fn database(id: u32) -> Held {
		Held { databases: vec![id], bucket: None }
	}

	const NONE: Held = Held { databases: Vec::new(), bucket: None };

	#[test]
	fn a_deploy_s_bindings_are_held_to_the_database_the_binding_holds() {
		let slots = |slots| AppBindings { app: None, database: named(slots), bucket: None };
		assert!(filled(None, NONE, DeploymentForm::Modules).is_ok());
		assert!(filled(Some(&slots(&[])), NONE, DeploymentForm::Modules).is_ok());
		assert!(filled(Some(&slots(&[("database", 3)])), database(3), DeploymentForm::Modules).is_ok());
		let refused =
			filled(Some(&slots(&[("database", 4)])), database(3), DeploymentForm::Modules).unwrap_err();
		assert_eq!(refused.reason, "invalid");
		assert_eq!(
			refused.message.as_deref(),
			Some("the slot database names the database 4, and the binding holds item 3's")
		);
		let refused =
			filled(Some(&slots(&[("database", 4)])), NONE, DeploymentForm::Modules).unwrap_err();
		assert_eq!(
			refused.message.as_deref(),
			Some("the slot database names the database 4, and the binding holds none")
		);
	}

	#[test]
	fn slots_may_name_different_held_databases() {
		let held = Held { databases: vec![3, 7], bucket: None };
		let slots =
			AppBindings { app: None, database: named(&[("first", 3), ("second", 7)]), bucket: None };
		assert!(filled(Some(&slots), held.clone(), DeploymentForm::Modules).is_ok());
		let slots = AppBindings { database: named(&[("missing", 9)]), ..slots };
		let refused = filled(Some(&slots), held, DeploymentForm::Modules).unwrap_err();
		assert_eq!(refused.reason, "invalid");
		assert_eq!(
			refused.message.as_deref(),
			Some("the slot missing names the database 9, and the binding holds item 3's, item 7's")
		);
	}

	#[test]
	fn a_bucket_slot_is_held_to_an_object_item_whatever_its_id() {
		let bucket = AppBindings { app: None, database: None, bucket: named(&[("files", 9)]) };
		let holding = Held { databases: Vec::new(), bucket: Some(2) };
		assert!(filled(Some(&bucket), holding, DeploymentForm::Modules).is_ok());
		for held in [NONE, database(2)] {
			let refused = filled(Some(&bucket), held, DeploymentForm::Modules).unwrap_err();
			assert_eq!(refused.reason, "invalid");
			assert_eq!(
				refused.message.as_deref(),
				Some("the slot files is filled under bucket, and the binding holds no object")
			);
		}
	}

	#[test]
	fn an_app_slot_is_refused_and_an_empty_map_is_not() {
		let app = AppBindings { app: named(&[("peer", 1)]), database: None, bucket: None };
		let all = Held { databases: vec![1], bucket: Some(1) };
		let refused = filled(Some(&app), all, DeploymentForm::Modules).unwrap_err();
		assert_eq!(refused.reason, "invalid");
		assert_eq!(
			refused.message.as_deref(),
			Some("the slot peer is filled under app, which a machine serves not yet")
		);
		let empty = AppBindings { app: named(&[]), database: None, bucket: named(&[]) };
		assert!(filled(Some(&empty), NONE, DeploymentForm::Modules).is_ok());
	}

	#[test]
	fn an_image_or_component_deploy_fills_no_slot() {
		let slots = AppBindings { app: None, database: named(&[("database", 3)]), bucket: None };
		for form in [DeploymentForm::Image, DeploymentForm::Component] {
			let refused = filled(Some(&slots), database(3), form).unwrap_err();
			assert_eq!(refused.reason, "invalid");
			assert!(refused.message.unwrap().starts_with("the slot database is filled on a "));
		}
		let empty = AppBindings { app: None, database: named(&[]), bucket: None };
		assert!(filled(Some(&empty), NONE, DeploymentForm::Image).is_ok());
		assert!(filled(None, NONE, DeploymentForm::Component).is_ok());
	}
}
