//! A binding's share of btrfs held by simple quotas, through the volume kind, which owns every
//! subvolume and qgroup, RFC 54q45.

use std::path::Path;

use crate::{Btrfs, Fault, Quota};

/// A call of the volume kind's run on a thread that may block, as the `btrfs` command does.
async fn blocking<F>(call: F) -> Result<(), Fault>
where
	F: FnOnce() -> Result<(), driver_machine_volume::Fault> + Send + 'static,
{
	match tokio::task::spawn_blocking(call).await {
		Ok(done) => done.map_err(|f| Fault(f.0)),
		Err(e) => Err(Fault(format!("btrfs: {e}"))),
	}
}

impl Quota for Btrfs {
	async fn assign(&self, subvolume: &Path, qgroup: &str) -> Result<(), Fault> {
		let (btrfs, subvolume, qgroup) = (self.clone(), subvolume.to_owned(), qgroup.to_owned());
		blocking(move || driver_machine_volume::Quotas::assign(&btrfs, &subvolume, &qgroup)).await
	}

	async fn limit(&self, qgroup: &str, bytes: Option<u64>) -> Result<(), Fault> {
		let (btrfs, qgroup) = (self.clone(), qgroup.to_owned());
		blocking(move || driver_machine_volume::Quotas::limit(&btrfs, &qgroup, bytes)).await
	}
}
