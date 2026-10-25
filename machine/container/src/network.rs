//! A container's network, a named namespace joined to a bridge by the CNI plugins, `bridge`'s ADD
//! answer kept for DEL.
//! https://github.com/containernetworking/cni/blob/main/SPEC.md

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::process::Stdio;

use serde_json::{Value, json};
use tokio::io::AsyncWriteExt;

use crate::{Attachment, Bridge, Fault, Network};

/// How long one connection to a container's address is waited on.
const CONNECT: std::time::Duration = std::time::Duration::from_secs(1);

/// The CNI version the configuration is written in.
const VERSION: &str = "1.0.0";

/// Where named network namespaces are, as `ip netns` keeps them.
const NETNS: &str = "/run/netns";

/// The interface a container reaches the bridge by.
const INTERFACE: &str = "eth0";

/// Where a reacher's element is written in the machine's nftables, its table's family and name
/// and its set, of `ipv4_addr . ipv4_addr . inet_service`, the driver's RFC p95sv.
const FENCE: [&str; 3] = ["inet", "fence", "reaching"];

/// What one plugin is asked, its command, its interface and its `CNI_ARGS`.
struct Call<'a> {
	command: &'a str,
	id: &'a str,
	interface: &'a str,
	netns: &'a Path,
	args: &'a str,
}

impl Bridge {
	fn kept(&self, id: &str) -> PathBuf {
		self.state.join(format!("{id}.json"))
	}

	fn loopback(&self) -> Value {
		json!({ "cniVersion": VERSION, "name": "loopback", "type": "loopback" })
	}

	// Nothing forwards a port and the bridge masquerades; the machine's nftables keep containers
	// apart, and let a reacher reach the entry alone by its element, RFC p95sv.
	fn bridge(&self) -> Value {
		json!({
			"cniVersion": VERSION,
			"name": self.name,
			"type": "bridge",
			"bridge": self.name,
			"isGateway": true,
			"ipMasq": true,
			"hairpinMode": true,
			"ipam": {
				"type": "host-local",
				"ranges": [[{ "subnet": self.subnet }]],
				"routes": [{ "dst": "0.0.0.0/0" }],
				"dataDir": self.state.join("ipam"),
			},
		})
	}

	/// A plugin run with its configuration on its input, and what it answered.
	async fn plugin(&self, kind: &str, call: &Call<'_>, config: &Value) -> Result<Value, Fault> {
		let binary = self.plugins.join(kind);
		let at = |e: std::io::Error| Fault(format!("{} {}: {e}", binary.display(), call.command));
		let mut child = tokio::process::Command::new(&binary)
			.env("CNI_COMMAND", call.command)
			.env("CNI_CONTAINERID", call.id)
			.env("CNI_NETNS", call.netns)
			.env("CNI_IFNAME", call.interface)
			.env("CNI_PATH", &self.plugins)
			.env("CNI_ARGS", call.args)
			.stdin(Stdio::piped())
			.stdout(Stdio::piped())
			.stderr(Stdio::piped())
			.spawn()
			.map_err(at)?;
		if let Some(mut input) = child.stdin.take() {
			input.write_all(config.to_string().as_bytes()).await.map_err(at)?;
		}
		let output = child.wait_with_output().await.map_err(at)?;
		let answered = String::from_utf8_lossy(&output.stdout);
		if output.status.success() {
			if answered.trim().is_empty() {
				return Ok(Value::Null);
			}
			return serde_json::from_str(&answered)
				.map_err(|e| Fault(format!("{} {}: its answer: {e}", binary.display(), call.command)));
		}
		Err(Fault(format!(
			"{} {}: {} {}",
			binary.display(),
			call.command,
			answered.trim(),
			String::from_utf8_lossy(&output.stderr).trim()
		)))
	}

	/// What ADD answered kept for DEL, written whole or not at all.
	async fn keep(&self, id: &str, answered: &Value) -> Result<(), Fault> {
		let kept = self.kept(id);
		let partial = self.state.join(format!("{id}.json.partial"));
		let at = |e: std::io::Error, p: &Path| Fault(format!("{}: {e}", p.display()));
		tokio::fs::write(&partial, answered.to_string()).await.map_err(|e| at(e, &partial))?;
		tokio::fs::rename(&partial, &kept).await.map_err(|e| at(e, &kept))
	}

	async fn ip(&self, args: &[&str]) -> Result<(), Fault> {
		let output = tokio::process::Command::new("ip")
			.args(args)
			.output()
			.await
			.map_err(|e| Fault(format!("ip {}: {e}", args.join(" "))))?;
		if output.status.success() {
			Ok(())
		} else {
			Err(Fault(format!(
				"ip {}: {}",
				args.join(" "),
				String::from_utf8_lossy(&output.stderr).trim()
			)))
		}
	}

	/// What ADD made undone, by what it answered.
	async fn undone(&self, id: &str, netns: &Path, answered: &Value) -> Result<(), Fault> {
		let mut config = self.bridge();
		if let Some(object) = config.as_object_mut() {
			object.insert("prevResult".to_owned(), answered.clone());
		}
		self
			.plugin(
				"bridge",
				&Call { command: "DEL", id, interface: INTERFACE, netns, args: "" },
				&config,
			)
			.await?;
		let lo = Call { command: "DEL", id, interface: "lo", netns, args: "" };
		self.plugin("loopback", &lo, &self.loopback()).await?;
		Ok(())
	}
}

/// The address ADD gave the container's interface, from its result's `ips`.
fn address(answered: &Value) -> Result<IpAddr, Fault> {
	answered
		.get("ips")
		.and_then(Value::as_array)
		.and_then(|ips| ips.first())
		.and_then(|ip| ip.get("address"))
		.and_then(Value::as_str)
		.and_then(|a| a.split('/').next())
		.and_then(|a| a.parse().ok())
		.ok_or_else(|| Fault(format!("bridge ADD answered no address: {answered}")))
}

async fn exists(path: &Path) -> bool {
	tokio::fs::try_exists(path).await.unwrap_or(false)
}

impl Network for Bridge {
	async fn attach(&self, id: &str, port: u16) -> Result<Attachment, Fault> {
		let netns = Path::new(NETNS).join(id);
		let kept = self.kept(id);
		let at = |e: std::io::Error, p: &Path| Fault(format!("{}: {e}", p.display()));
		let mut asked = String::new();
		if let Ok(text) = tokio::fs::read_to_string(&kept).await {
			let answered: Value =
				serde_json::from_str(&text).map_err(|e| Fault(format!("{}: {e}", kept.display())))?;
			if exists(&netns).await {
				return attachment(&answered, port, self.entry, netns);
			}
			// The namespace went with a reboot, so all is made again at the address its label holds.
			self.undone(id, &netns, &answered).await?;
			tokio::fs::remove_file(&kept).await.map_err(|e| at(e, &kept))?;
			asked = format!("IgnoreUnknown=1;IP={}", address(&answered)?);
		}
		tokio::fs::create_dir_all(&self.state).await.map_err(|e| at(e, &self.state))?;
		if !exists(&netns).await {
			self.ip(&["netns", "add", id]).await?;
		}
		self
			.plugin(
				"loopback",
				&Call { command: "ADD", id, interface: "lo", netns: &netns, args: "" },
				&self.loopback(),
			)
			.await?;
		let answered = self
			.plugin(
				"bridge",
				&Call { command: "ADD", id, interface: INTERFACE, netns: &netns, args: &asked },
				&self.bridge(),
			)
			.await?;
		self.keep(id, &answered).await?;
		attachment(&answered, port, self.entry, netns)
	}

	async fn detach(&self, id: &str) -> Result<(), Fault> {
		let netns = Path::new(NETNS).join(id);
		let kept = self.kept(id);
		if let Ok(text) = tokio::fs::read_to_string(&kept).await {
			let answered: Value =
				serde_json::from_str(&text).map_err(|e| Fault(format!("{}: {e}", kept.display())))?;
			self.undone(id, &netns, &answered).await?;
			tokio::fs::remove_file(&kept).await.map_err(|e| Fault(format!("{}: {e}", kept.display())))?;
		}
		if exists(&netns).await {
			self.ip(&["netns", "delete", id]).await?;
		}
		Ok(())
	}

	async fn reached(&self, address: SocketAddr) -> bool {
		let connected = tokio::net::TcpStream::connect(address);
		matches!(tokio::time::timeout(CONNECT, connected).await, Ok(Ok(_)))
	}

	/// A reacher's element written at the entry given, or the one it was written at removed where
	/// none is given; one already so is no failure.
	async fn fence(&self, id: &str, reached: &[SocketAddr]) -> Result<(), Fault> {
		let kept = self.kept(id);
		let text = tokio::fs::read_to_string(&kept)
			.await
			.map_err(|e| Fault(format!("{}: {e}", kept.display())))?;
		let answered: Value =
			serde_json::from_str(&text).map_err(|e| Fault(format!("{}: {e}", kept.display())))?;
		let (IpAddr::V4(reacher), IpAddr::V4(host)) = (address(&answered)?, gateway(&answered)?) else {
			return Err(Fault(format!("{id}: a fence holds IPv4 addresses alone")));
		};
		let written = self.state.join(format!("{id}.element"));
		let at = |e: std::io::Error| Fault(format!("{}: {e}", written.display()));
		match reached.first() {
			// Added at the entry given, which is kept beside it so its delete names the same.
			Some(SocketAddr::V4(entry)) => {
				let entry = (*entry.ip(), entry.port());
				nft(&element(reacher, entry, true)).await?;
				tokio::fs::write(&written, format!("{} {}", entry.0, entry.1)).await.map_err(at)
			}
			Some(SocketAddr::V6(entry)) => Err(Fault(format!("{entry}: a fence holds IPv4 alone"))),
			None => {
				let recorded = tokio::fs::read_to_string(&written).await.ok();
				let entry = recorded.as_deref().and_then(recorded_entry).unwrap_or((host, self.entry));
				nft(&element(reacher, entry, false)).await?;
				match tokio::fs::remove_file(&written).await {
					Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(at(e)),
					_ => Ok(()),
				}
			}
		}
	}
}

/// The entry an element was added at, as it is kept, `<address> <port>`.
fn recorded_entry(text: &str) -> Option<(Ipv4Addr, u16)> {
	let (address, port) = text.trim().split_once(' ')?;
	Some((address.parse().ok()?, port.parse().ok()?))
}

/// What a container is attached as, its address, and the entry at the host's address ADD answered
/// and the entry's port.
fn attachment(
	answered: &Value,
	port: u16,
	entry: u16,
	netns: PathBuf,
) -> Result<Attachment, Fault> {
	let address = SocketAddr::new(address(answered)?, port);
	Ok(Attachment { address, entry: SocketAddr::new(gateway(answered)?, entry), netns })
}

/// The host's own address on the bridge, the gateway of ADD's result's first `ips`.
fn gateway(answered: &Value) -> Result<IpAddr, Fault> {
	answered
		.get("ips")
		.and_then(Value::as_array)
		.and_then(|ips| ips.first())
		.and_then(|ip| ip.get("gateway"))
		.and_then(Value::as_str)
		.and_then(|a| a.parse().ok())
		.ok_or_else(|| Fault(format!("bridge ADD answered no gateway: {answered}")))
}

/// The arguments of `nft` adding a reacher's element, or deleting the one it had.
fn element(reacher: Ipv4Addr, (entry, port): (Ipv4Addr, u16), add: bool) -> Vec<String> {
	let verb = if add { "add" } else { "delete" };
	let [family, table, set] = FENCE;
	[verb, "element", family, table, set, &format!("{{ {reacher} . {entry} . {port} }}")]
		.map(str::to_owned)
		.to_vec()
}

/// `nft` run with the arguments, a delete of what is not there no failure.
async fn nft(args: &[String]) -> Result<(), Fault> {
	let output = tokio::process::Command::new("nft")
		.args(args)
		.output()
		.await
		.map_err(|e| Fault(format!("nft {}: {e}", args.join(" "))))?;
	let said = String::from_utf8_lossy(&output.stderr);
	let absent = args.first().is_some_and(|a| a == "delete") && said.contains("No such file");
	match output.status.success() || absent {
		true => Ok(()),
		false => Err(Fault(format!("nft {}: {}", args.join(" "), said.trim()))),
	}
}

#[cfg(test)]
mod tests {
	use super::{address, attachment, element, gateway};
	use crate::Bridge;
	use serde_json::json;
	use std::net::Ipv4Addr;
	use std::path::PathBuf;

	#[tokio::test]
	async fn a_kept_answer_is_written_whole_and_nothing_partial_is_left() {
		let state = std::env::temp_dir().join("driver-machine-network-kept");
		let _ = std::fs::remove_dir_all(&state);
		std::fs::create_dir_all(&state).unwrap();
		let bridge = Bridge {
			plugins: PathBuf::from("/nonexistent"),
			name: "bridge-name".into(),
			subnet: "192.0.2.0/24".into(),
			state,
			entry: 4321,
		};
		bridge.keep("b1-app-1", &json!({ "ips": [] })).await.unwrap();
		let names: Vec<String> = std::fs::read_dir(&bridge.state)
			.unwrap()
			.map(|e| e.unwrap().file_name().into_string().unwrap())
			.collect();
		assert_eq!(names, ["b1-app-1.json"]);
	}

	#[test]
	fn a_reachers_element_is_its_address_the_hosts_and_the_entrys_port() {
		let (reacher, host) = (Ipv4Addr::new(192, 0, 2, 7), Ipv4Addr::new(192, 0, 2, 1));
		let added = ["add", "element", "inet", "fence", "reaching", "{ 192.0.2.7 . 192.0.2.1 . 4321 }"];
		assert_eq!(element(reacher, (host, 4321), true), added);
		let mut deleted = added;
		deleted[0] = "delete";
		assert_eq!(element(reacher, (host, 4321), false), deleted);
	}

	#[test]
	fn the_entry_an_element_was_added_at_is_read_back_as_kept() {
		assert_eq!(
			super::recorded_entry("192.0.2.1 4321\n"),
			Some((Ipv4Addr::new(192, 0, 2, 1), 4321))
		);
		assert_eq!(super::recorded_entry("192.0.2.1"), None);
	}

	#[test]
	fn the_entry_is_the_gateway_the_plugin_answered_at_the_bridges_port() {
		let answered = json!({ "ips": [{ "address": "192.0.2.7/24", "gateway": "192.0.2.254" }] });
		let attached = attachment(&answered, 8080, 4321, PathBuf::from("/run/netns/x")).unwrap();
		assert_eq!(attached.address, "192.0.2.7:8080".parse().unwrap());
		assert_eq!(attached.entry, "192.0.2.254:4321".parse().unwrap());
		assert!(gateway(&json!({ "ips": [{ "address": "192.0.2.7/24" }] })).is_err());
	}

	#[test]
	fn the_address_is_the_first_of_the_result() {
		let answered = json!({
			"cniVersion": "1.0.0",
			"interfaces": [{ "name": "eth0", "sandbox": "/run/netns/x" }],
			"ips": [{ "interface": 0, "address": "10.88.0.7/16", "gateway": "10.88.0.1" }],
		});
		assert_eq!(address(&answered).unwrap().to_string(), "10.88.0.7");
		assert!(address(&json!({ "ips": [] })).is_err());
	}
}
