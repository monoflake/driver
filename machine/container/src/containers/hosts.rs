//! A reacher's hosts file, written fresh with the loopback lines and a line for each name it
//! reaches, in the driver's state and bound read-only at `/etc/hosts`, RFC y2xd3.

use std::net::IpAddr;
use std::path::{Path, PathBuf};

use crate::Refused;

/// The lines every hosts file holds, the loopback's own names.
const LOOPBACK: &str = "127.0.0.1\tlocalhost\n::1\tlocalhost\n";

fn place(state: &Path, namespace: &str, id: &str) -> PathBuf {
	state.join("hosts").join(namespace).join(id)
}

fn failed(path: &Path, e: &std::io::Error) -> Refused {
	Refused::new("fault", format!("{}: {e}", path.display()))
}

/// The loopback lines and a line for each name, mapped to the host's address.
pub(super) fn lines(host: IpAddr, names: &[String]) -> String {
	let mut text = LOOPBACK.to_owned();
	for name in names {
		text.push_str(&format!("{host}\t{name}\n"));
	}
	text
}

/// The hosts file written for a new container, which is answered.
pub(super) async fn write(
	state: &Path,
	namespace: &str,
	id: &str,
	host: IpAddr,
	names: &[String],
) -> Result<PathBuf, Refused> {
	let file = place(state, namespace, id);
	if let Some(parent) = file.parent() {
		tokio::fs::create_dir_all(parent).await.map_err(|e| failed(parent, &e))?;
	}
	tokio::fs::write(&file, lines(host, names)).await.map_err(|e| failed(&file, &e))?;
	Ok(file)
}

/// A container's hosts file removed, if it has one.
pub(super) async fn remove(state: &Path, namespace: &str, id: &str) -> Result<(), Refused> {
	let file = place(state, namespace, id);
	match tokio::fs::remove_file(&file).await {
		Ok(()) => Ok(()),
		Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
		Err(e) => Err(failed(&file, &e)),
	}
}

#[cfg(test)]
mod tests {
	use super::lines;

	#[test]
	fn the_loopback_lines_and_each_name_reached_alone() {
		let host = "192.0.2.1".parse().unwrap();
		let names = ["00000009.b1".to_owned(), "1a2b3c4d.b1".to_owned()];
		assert_eq!(
			lines(host, &names),
			"127.0.0.1\tlocalhost\n::1\tlocalhost\n192.0.2.1\t00000009.b1\n192.0.2.1\t1a2b3c4d.b1\n"
		);
	}
}
