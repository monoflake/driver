//! One `object_bucket` slot's calls forwarded to its binding's storage product, the bucket the slot
//! is filled with and the calling deployment set outside the Worker, RFC ahcrp.

use std::path::PathBuf;

use envelope::contracts::DeploymentRuns;

/// The router one slot's socket serves, forwarding to the storage product's data socket at `data`.
#[allow(dead_code, reason = "a stub until the slot sockets serve it")]
pub(super) fn router(data: PathBuf, bucket: u32, caller: DeploymentRuns) -> axum::Router {
	let _ = (data, bucket, caller);
	axum::Router::new()
}
