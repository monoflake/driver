//! One `object_bucket` slot's calls forwarded to its binding's storage product, the bucket the slot
//! is filled with and the calling deployment set outside the Worker, RFC ahcrp; and the compute
//! component's status calls, forwarded with no bucket, RFC 49qyg.

use std::path::PathBuf;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::State;
use axum::http::{HeaderValue, Method, Request, StatusCode, Uri, header};
use axum::response::Response;
use driver_machine_object::MOST;
use envelope::contracts::{self, DeploymentRuns, Error, Failure, ObjectDeleted};
use envelope::{Answer, Encoded as _};
use hyper_util::rt::TokioIo;

/// The operations of the storage product a slot reaches, as `buckets.res` names them.
const OPERATIONS: [&str; 5] =
	["object_write", "object_read", "object_describe", "object_delete", "object_list"];

/// The one operation the compute component's status socket forwards.
const STATUS: &str = "status";

/// The header naming the calling deployment, which the driver alone sets.
const CALLER: &str = "caller";

/// The most a call's body may be, a content at `Objects.most` in base64url beside the rest.
const LARGEST: usize = MOST.div_ceil(3) * 4 + 2 * 1024 * 1024;

/// What a refused body is read up to before its refusal, so its caller reads the answer.
const DRAINED: usize = 2 * 1024 * 1024;

/// What one socket forwards with, a slot's bucket, or none on the compute component's status one.
struct Slot {
	data: PathBuf,
	bucket: Option<u32>,
	caller: HeaderValue,
}

/// The router one slot's socket serves, forwarding to the storage product's data socket at `data`.
pub(super) fn router(data: PathBuf, bucket: u32, caller: DeploymentRuns) -> axum::Router {
	forwarding(data, Some(bucket), caller)
}

/// The router the compute component's status socket serves, `POST /storage/status` alone
/// forwarded to `data` with no bucket.
pub(super) fn status(data: PathBuf, caller: DeploymentRuns) -> axum::Router {
	forwarding(data, None, caller)
}

/// A router forwarding to `data` as `caller`, its bucket set where one is given.
fn forwarding(data: PathBuf, bucket: Option<u32>, caller: DeploymentRuns) -> axum::Router {
	let id = match caller {
		DeploymentRuns::App { id } | DeploymentRuns::Component { id, .. } => id,
	};
	let caller = HeaderValue::from_str(&format!("{id:08x}")).unwrap_or(HeaderValue::from_static(""));
	let slot = Arc::new(Slot { data, bucket, caller });
	axum::Router::new().fallback(forwarded).with_state(slot)
}

/// An error answered in JSON, its status the failure's as the listener's answers are.
fn refused(failure: Failure, reason: &str, message: String) -> Response {
	let status = match failure {
		Failure::Rejected => StatusCode::BAD_REQUEST,
		Failure::Unavailable => StatusCode::SERVICE_UNAVAILABLE,
		Failure::Unknown => StatusCode::INTERNAL_SERVER_ERROR,
	};
	let error = Error { failure, reason: reason.to_owned(), message, call: None };
	let json = Answer::<ObjectDeleted>::Error(error).to_json();
	let mut response = Response::new(Body::from(json.to_string()));
	*response.status_mut() = status;
	let media = HeaderValue::from_static("application/json");
	response.headers_mut().insert(header::CONTENT_TYPE, media);
	response
}

/// A call not as a slot's are written, `malformed`.
fn malformed(message: impl Into<String>) -> Response {
	refused(Failure::Rejected, "malformed", message.into())
}

/// Storage not reached, `unreachable`, its message the contract's own beside what failed.
fn unreachable(data: &std::path::Path, why: impl std::fmt::Display) -> Response {
	let said = contracts::message("unreachable").unwrap_or("unreachable");
	refused(Failure::Unavailable, "unreachable", format!("{said}, {} {why}", data.display()))
}

/// Every request on a slot's socket, one of the five operations forwarded and the rest refused;
/// on the status socket, status alone.
async fn forwarded(
	State(slot): State<Arc<Slot>>,
	method: Method,
	uri: Uri,
	body: Body,
) -> Response {
	let operation = uri.path().strip_prefix("/storage/");
	let operation = match slot.bucket {
		Some(_) => operation.filter(|o| OPERATIONS.contains(o)),
		None => operation.filter(|o| *o == STATUS),
	};
	let (Some(operation), Method::POST) = (operation, method) else {
		// A body past the bound is the caller's to have sent, and its connection may then be reset.
		let _ = axum::body::to_bytes(body, DRAINED).await;
		let one = OPERATIONS.join(", ");
		return malformed(match slot.bucket {
			Some(_) => format!("a slot's call is POST /storage/{{operation}}, one of {one}"),
			None => format!("this socket takes POST /storage/{STATUS} alone"),
		});
	};
	let Ok(bytes) = axum::body::to_bytes(body, LARGEST).await else {
		let message = format!("a slot's call is at most {LARGEST} bytes");
		return refused(Failure::Rejected, "too_large", message);
	};
	let mut json = match serde_json::from_slice::<serde_json::Value>(&bytes) {
		Ok(json) => json,
		Err(e) => return malformed(format!("the body is not JSON, {e}")),
	};
	let Some(input) = json.as_object_mut() else {
		return malformed("the body is a JSON object, the operation's input");
	};
	if let Some(bucket) = slot.bucket {
		input.insert("bucket".to_owned(), serde_json::Value::from(bucket));
	}
	let sent = json.to_string();
	match storage(&slot, operation, sent).await {
		Ok(response) => response,
		Err(Unsent(why)) => unreachable(&slot.data, why),
		// A write sent may have reached storage, so whether it took effect is not known, RFC 49qyg.
		Err(Sent(why)) if CHANGING.contains(&operation) => refused(
			Failure::Unknown,
			"fault",
			format!("storage may have received the call, {} {why}", slot.data.display()),
		),
		Err(Sent(why)) => unreachable(&slot.data, why),
	}
}

/// The operations that change a bucket, whose outcome a call lost after sending cannot tell.
const CHANGING: [&str; 2] = ["object_write", "object_delete"];

/// Where a call to storage failed: before anything was sent, or once it may have been received.
enum Failed {
	Unsent(String),
	Sent(String),
}
use Failed::{Sent, Unsent};

/// The call posted to the data socket, and storage's status, type and body as they came.
async fn storage(slot: &Slot, operation: &str, body: String) -> Result<Response, Failed> {
	let unsent = |e: &dyn std::fmt::Display| Unsent(e.to_string());
	let stream = tokio::net::UnixStream::connect(&slot.data).await.map_err(|e| unsent(&e))?;
	let (mut sender, connection) =
		hyper::client::conn::http1::handshake(TokioIo::new(stream)).await.map_err(|e| unsent(&e))?;
	tokio::spawn(async move {
		let _ = connection.await;
	});
	let request = Request::post(format!("/storage/{operation}"))
		.header(header::HOST, "localhost")
		.header(header::CONTENT_TYPE, "application/json")
		.header(CALLER, slot.caller.clone())
		.body(Body::from(body))
		.map_err(|e| unsent(&e))?;
	let answered = sender.send_request(request).await.map_err(|e| Sent(e.to_string()))?;
	let (parts, incoming) = answered.into_parts();
	let mut response = Response::new(Body::new(incoming));
	*response.status_mut() = parts.status;
	if let Some(media) = parts.headers.get(header::CONTENT_TYPE) {
		response.headers_mut().insert(header::CONTENT_TYPE, media.clone());
	}
	Ok(response)
}
