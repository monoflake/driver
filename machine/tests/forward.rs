//! A slot's calls forwarded to a fake storage on a Unix socket, the bucket and the caller set by
//! the driver, RFC ahcrp.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

// The router is the binary's own, so its module is compiled here as well.
#[path = "../src/served/forward.rs"]
mod forward;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use axum::body::Body;
use axum::extract::State;
use axum::http::{HeaderMap, Request, StatusCode, Uri};
use envelope::contracts::DeploymentRuns;
use hyper_util::rt::TokioIo;
use serde_json::{Value, json};

/// A directory of its own, short enough to hold a Unix socket below it, removed when dropped.
struct Directory(PathBuf);

impl Directory {
	fn new() -> Self {
		static COUNT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
		let count = COUNT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
		let path = std::env::temp_dir().join(format!("fw{}-{count}", std::process::id()));
		std::fs::create_dir_all(&path).unwrap();
		Self(path)
	}
}

impl Drop for Directory {
	fn drop(&mut self) {
		let _ = std::fs::remove_dir_all(&self.0);
	}
}

/// What the fake storage received, each call's path, caller and body.
type Received = Arc<Mutex<Vec<(String, Option<String>, Value)>>>;

/// The fake storage's one answer, refusing a data call that names no caller as storage does.
async fn stored(
	State(received): State<Received>,
	uri: Uri,
	headers: HeaderMap,
	body: Body,
) -> (StatusCode, String) {
	let caller = headers.get("caller").and_then(|v| v.to_str().ok()).map(str::to_owned);
	let bytes = axum::body::to_bytes(body, usize::MAX).await.unwrap();
	let json: Value = serde_json::from_slice(&bytes).unwrap();
	received.lock().unwrap().push((uri.path().to_owned(), caller.clone(), json.clone()));
	if caller.is_none() {
		let denied = json!({ "status": "error", "failure": "rejected", "reason": "denied",
			"message": "a data call names its caller" });
		return (StatusCode::FORBIDDEN, denied.to_string());
	}
	let object = json!({ "status": "success", "data": { "object": "aa", "hash": "00",
		"size": 5, "bucket": json["bucket"] } });
	(StatusCode::CREATED, object.to_string())
}

/// A router served on a Unix socket at `path`, until the test ends.
fn served(path: &Path, router: axum::Router) {
	let listener = tokio::net::UnixListener::bind(path).unwrap();
	tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
}

/// The fake storage served at `<directory>/data.sock`, and what it receives.
fn storage(directory: &Directory) -> (PathBuf, Received) {
	let path = directory.0.join("data.sock");
	let received = Received::default();
	served(&path, axum::Router::new().fallback(stored).with_state(Arc::clone(&received)));
	(path, received)
}

/// A slot's socket at `<directory>/slot.sock`, forwarding to `data` for app 0x2a, bucket 7.
fn slot(directory: &Directory, data: PathBuf) -> PathBuf {
	let path = directory.0.join("slot.sock");
	served(&path, forward::router(data, 7, DeploymentRuns::App { id: 0x2a }));
	path
}

/// A request on a socket, and its status and JSON answer.
async fn called(
	socket: &Path,
	method: &str,
	path: &str,
	headers: &[(&str, &str)],
	body: &Value,
) -> (u16, Value) {
	let stream = tokio::net::UnixStream::connect(socket).await.unwrap();
	let (mut sender, connection) =
		hyper::client::conn::http1::handshake(TokioIo::new(stream)).await.unwrap();
	tokio::spawn(connection);
	let mut request = Request::builder().method(method).uri(path).header("host", "localhost");
	for (name, value) in headers {
		request = request.header(*name, *value);
	}
	let request = request.body(Body::from(body.to_string())).unwrap();
	let answered = sender.send_request(request).await.unwrap();
	let status = answered.status().as_u16();
	let bytes = axum::body::to_bytes(Body::new(answered.into_body()), usize::MAX).await.unwrap();
	(status, serde_json::from_slice(&bytes).unwrap())
}

#[tokio::test]
async fn a_write_is_forwarded_with_the_slot_s_bucket_and_the_driver_s_caller() {
	let directory = Directory::new();
	let (data, received) = storage(&directory);
	let socket = slot(&directory, data);
	let write = json!({ "bucket": 99, "content": "aGVsbG8", "extension": "txt" });
	let forged = [("content-type", "application/json"), ("caller", "ffffffff")];
	let (status, answer) = called(&socket, "POST", "/storage/object_write", &forged, &write).await;
	// Storage's status and body come back as they went.
	assert_eq!(status, 201, "{answer}");
	assert_eq!(answer["data"]["bucket"], 7, "{answer}");
	let received = received.lock().unwrap().clone();
	let sent = json!({ "bucket": 7, "content": "aGVsbG8", "extension": "txt" });
	assert_eq!(
		received,
		vec![("/storage/object_write".to_owned(), Some("0000002a".to_owned()), sent)]
	);
}

#[tokio::test]
async fn an_operation_outside_the_five_is_refused_before_forwarding() {
	let directory = Directory::new();
	let (data, received) = storage(&directory);
	let socket = slot(&directory, data);
	let input = json!({ "bucket": 7, "path": "a" });
	for (method, path) in [
		("POST", "/storage/file_write"),
		("POST", "/storage/publish"),
		("POST", "/object/write"),
		("POST", "/storage/object_write/more"),
		("GET", "/storage/object_read"),
	] {
		let (status, answer) = called(&socket, method, path, &[], &input).await;
		assert_eq!(status, 400, "{method} {path} {answer}");
		assert_eq!(answer["status"], "error");
		assert_eq!(answer["failure"], "rejected");
		assert_eq!(answer["reason"], "malformed");
	}
	let (status, answer) = called(&socket, "POST", "/storage/object_read", &[], &json!([1])).await;
	assert_eq!((status, &answer["reason"]), (400, &json!("malformed")), "{answer}");
	assert!(received.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_storage_that_is_down_is_answered_unavailable() {
	let directory = Directory::new();
	let socket = slot(&directory, directory.0.join("absent.sock"));
	let input = json!({ "object": "aa" });
	let (status, answer) = called(&socket, "POST", "/storage/object_describe", &[], &input).await;
	assert_eq!(status, 503, "{answer}");
	assert_eq!(answer["failure"], "unavailable");
	assert_eq!(answer["reason"], "unreachable");
}

/// A storage that takes each call's first bytes and closes before answering, as a crash would.
fn dropping(directory: &Directory) -> PathBuf {
	use tokio::io::AsyncReadExt;
	let path = directory.0.join("drop.sock");
	let listener = tokio::net::UnixListener::bind(&path).unwrap();
	tokio::spawn(async move {
		while let Ok((mut stream, _)) = listener.accept().await {
			let mut first = [0u8; 64];
			let _ = stream.read(&mut first).await;
		}
	});
	path
}

#[tokio::test]
async fn a_change_lost_after_it_was_sent_is_unknown_and_a_read_stays_unavailable() {
	let directory = Directory::new();
	let socket = slot(&directory, dropping(&directory));
	let write = json!({ "content": "aGVsbG8", "extension": "txt" });
	for (path, input) in
		[("/storage/object_write", &write), ("/storage/object_delete", &json!({ "object": "aa" }))]
	{
		let (status, answer) = called(&socket, "POST", path, &[], input).await;
		assert_eq!(status, 500, "{path} {answer}");
		assert_eq!((&answer["failure"], &answer["reason"]), (&json!("unknown"), &json!("fault")));
	}
	let read = json!({ "object": "aa" });
	let (status, answer) = called(&socket, "POST", "/storage/object_read", &[], &read).await;
	assert_eq!(status, 503, "{answer}");
	assert_eq!(
		(&answer["failure"], &answer["reason"]),
		(&json!("unavailable"), &json!("unreachable"))
	);
}

#[tokio::test]
async fn the_fake_refuses_a_data_call_that_did_not_come_through_the_forwarder() {
	let directory = Directory::new();
	let (data, received) = storage(&directory);
	let input = json!({ "bucket": 7, "object": "aa" });
	let (status, answer) = called(&data, "POST", "/storage/object_delete", &[], &input).await;
	assert_eq!((status, &answer["reason"]), (403, &json!("denied")), "{answer}");
	let socket = slot(&directory, data);
	let (status, answer) = called(&socket, "POST", "/storage/object_delete", &[], &input).await;
	assert_eq!(status, 201, "{answer}");
	assert_eq!(received.lock().unwrap().len(), 2);
}

/// Compute's status socket at `<directory>/status.sock`, forwarding to `data` for compute 0x2b.
fn status(directory: &Directory, data: PathBuf) -> PathBuf {
	let path = directory.0.join("status.sock");
	let compute = DeploymentRuns::Component { component: "compute".into(), id: 0x2b };
	served(&path, forward::status(data, compute));
	path
}

#[tokio::test]
async fn compute_s_status_is_forwarded_with_no_bucket_and_compute_as_its_caller() {
	let directory = Directory::new();
	let (data, received) = storage(&directory);
	let socket = status(&directory, data);
	let forged = [("content-type", "application/json"), ("caller", "ffffffff")];
	let input = json!({ "id": "call" });
	let (status, answer) = called(&socket, "POST", "/storage/status", &forged, &input).await;
	assert_eq!(status, 201, "{answer}");
	let received = received.lock().unwrap().clone();
	assert_eq!(received, vec![("/storage/status".to_owned(), Some("0000002b".to_owned()), input)]);
}

#[tokio::test]
async fn compute_s_status_socket_refuses_every_other_path_before_forwarding() {
	let directory = Directory::new();
	let (data, received) = storage(&directory);
	let socket = status(&directory, data);
	let input = json!({ "id": "call" });
	for (method, path) in [
		("POST", "/storage/object_write"),
		("POST", "/storage/object_read"),
		("POST", "/storage/object_list"),
		("POST", "/storage/status/more"),
		("POST", "/object/status"),
		("GET", "/storage/status"),
	] {
		let (status, answer) = called(&socket, method, path, &[], &input).await;
		assert_eq!(status, 400, "{method} {path} {answer}");
		assert_eq!((&answer["failure"], &answer["reason"]), (&json!("rejected"), &json!("malformed")));
	}
	assert!(received.lock().unwrap().is_empty());
}

#[tokio::test]
async fn an_app_s_slot_refuses_status_which_takes_no_bucket() {
	let directory = Directory::new();
	let (data, received) = storage(&directory);
	let socket = slot(&directory, data);
	let input = json!({ "id": "call" });
	let (status, answer) = called(&socket, "POST", "/storage/status", &[], &input).await;
	assert_eq!(status, 400, "{answer}");
	assert_eq!((&answer["failure"], &answer["reason"]), (&json!("rejected"), &json!("malformed")));
	assert!(received.lock().unwrap().is_empty());
}
