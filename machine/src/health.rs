//! A driver update judged, `snapshot` written by the version being replaced and `check` run by the
//! version replacing it, so the updater reads an exit code and learns no call, RFC okz12.

use std::collections::{BTreeMap, BTreeSet};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::{Duration, Instant};

use driver_machine_container::{Containerd as _, Listed, Socket};
use driver_machine_management::{Binding, Hold as _, Tokens};
use reqwest::header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, HOST, SERVER};
use serde_json::{Value, json};

use crate::{entry, kept};

/// How the driver names itself on every answer, what `check` holds the new version to.
pub(crate) const SERVED_AS: &str = concat!("driver-machine/", env!("CARGO_PKG_VERSION"));

/// The two services an update restarts.
const SERVICES: [&str; 2] = ["driver-machine.service", "driver-machine-entry.service"];

/// How long one call is waited on.
const ASKED: Duration = Duration::from_secs(5);

/// How long passes between two reads while a level waits.
const AGAIN: Duration = Duration::from_secs(1);

/// What both commands reach, each named as the driver and its entry are started with it.
#[derive(Debug, Clone, clap::Args)]
pub(crate) struct Reach {
	/// A binding token's file, the driver's own; repeated.
	#[arg(long = "bindings", value_name = "file")]
	bindings: Vec<PathBuf>,
	/// The driver's address.
	#[arg(long, value_name = "address:port", default_value_t = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), crate::PORT))]
	driver: SocketAddr,
	/// The entry's address, every address of the machine read as loopback.
	#[arg(long, value_name = "address:port", default_value_t = entry::LISTEN)]
	entry: SocketAddr,
	/// The driver's state.
	#[arg(long, value_name = "directory", default_value = crate::STATE)]
	state: PathBuf,
	/// containerd's socket.
	#[arg(long, value_name = "socket", default_value = "/run/containerd/containerd.sock")]
	containerd: PathBuf,
	/// systemctl's binary.
	#[arg(long, value_name = "binary", default_value = "systemctl")]
	systemctl: PathBuf,
}

/// What `snapshot` is started with.
#[derive(Debug, Clone, clap::Args)]
pub(crate) struct SnapshotArguments {
	/// The file the baseline is written to.
	file: PathBuf,
	#[command(flatten)]
	reach: Reach,
	/// Seconds between its two reads, a deployment changing across them left out of the baseline.
	#[arg(long, value_name = "seconds", default_value_t = 3)]
	apart: u64,
}

/// What `check` is started with.
#[derive(Debug, Clone, clap::Args)]
pub(crate) struct CheckArguments {
	/// The baseline `snapshot` wrote; without one level 3 is skipped, and says so.
	snapshot: Option<PathBuf>,
	#[command(flatten)]
	reach: Reach,
	/// Seconds both services must stay active.
	#[arg(long, value_name = "seconds", default_value_t = 20)]
	settle: u64,
	/// Seconds the driver and the entry are given to answer, past the driver's 60 s of roots.
	#[arg(long, value_name = "seconds", default_value_t = 90)]
	answering: u64,
	/// Seconds the deployments are given to match the baseline.
	#[arg(long, value_name = "seconds", default_value_t = 60)]
	matching: u64,
}

/// A field's text, none where the value holds none.
fn text<'a>(value: &'a Value, field: &str) -> Option<&'a str> {
	value.get(field).and_then(Value::as_str)
}

/// A deployment's state, as `deployments describe` answers it.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Seen {
	Running,
	Stopped,
	Absent,
	/// Any other, by its name, never judged as a baseline.
	Other(String),
}

impl Seen {
	fn named(&self) -> &str {
		match self {
			Self::Running => "running",
			Self::Stopped => "stopped",
			Self::Absent => "absent",
			Self::Other(name) => name,
		}
	}

	/// The state a call's answer tells.
	fn told(answered: &Answered) -> Self {
		let body = &answered.body;
		match (text(body, "status"), text(body, "reason")) {
			(Some("success"), _) => match body.pointer("/data/state/name").and_then(Value::as_str) {
				Some("running") => Self::Running,
				Some("stopped") => Self::Stopped,
				Some(other) => Self::Other(other.to_owned()),
				None => Self::Other("unread".to_owned()),
			},
			(_, Some("not_found")) => Self::Absent,
			(_, Some(reason)) => Self::Other(reason.to_owned()),
			_ => Self::Other("unread".to_owned()),
		}
	}
}

/// One deployment of a binding, by its id.
type Deployment = (Binding, u32);

/// A call's answer, its status, how the driver named itself and its body.
struct Answered {
	status: u16,
	served: Option<String>,
	body: Value,
}

/// The driver's port and the entry's, called as a control and a request call them.
struct Ports {
	driver: SocketAddr,
	entry: SocketAddr,
	client: reqwest::Client,
}

/// An address as it is called, every address of the machine read as loopback.
fn called(address: SocketAddr) -> SocketAddr {
	match address.ip().is_unspecified() {
		true => SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), address.port()),
		false => address,
	}
}

impl Ports {
	fn of(reach: &Reach) -> Result<Self, String> {
		let client = reqwest::Client::builder()
			.no_proxy()
			.redirect(reqwest::redirect::Policy::none())
			.timeout(ASKED)
			.build()
			.map_err(|e| format!("no client, {e}"))?;
		Ok(Self { driver: called(reach.driver), entry: called(reach.entry), client })
	}

	/// A call in JSON, with a binding's token where one is given.
	async fn call(
		&self,
		token: Option<&str>,
		interface: &str,
		operation: &str,
		input: &Value,
	) -> Result<Answered, String> {
		let url = format!("http://{}/{interface}/{operation}", self.driver);
		let body = json!({ "interface": interface, "operation": operation, "input": input });
		let mut request = self
			.client
			.post(url)
			.header(CONTENT_TYPE, "application/json")
			.header(ACCEPT, "application/json")
			.body(body.to_string());
		if let Some(token) = token {
			request = request.header(AUTHORIZATION, format!("Bearer {token}"));
		}
		let reply = request.send().await.map_err(|e| format!("no answer, {e}"))?;
		let status = reply.status().as_u16();
		let served = reply.headers().get(SERVER).and_then(|v| v.to_str().ok()).map(str::to_owned);
		let bytes = reply.bytes().await.map_err(|e| format!("no answer read, {e}"))?;
		let body = serde_json::from_slice(&bytes).map_err(|e| format!("no JSON answered, {e}"))?;
		Ok(Answered { status, served, body })
	}

	/// A deployment's state, an answer not read being a failure rather than a state.
	async fn deployment(&self, token: &str, id: u32) -> Result<Seen, String> {
		let input = json!({ "runs": { "name": "app", "id": id } });
		let answered = self.call(Some(token), "deployments", "describe", &input).await?;
		Ok(Seen::told(&answered))
	}

	/// Whether the entry answers a request at all, as it answers a host it holds nothing of.
	async fn entry_answers(&self) -> Result<(), String> {
		let url = format!("http://{}/", self.entry);
		let reply = self.client.get(url).header(HOST, "localhost").send().await;
		reply.map(|_| ()).map_err(|e| format!("the entry did not answer, {e}"))
	}
}

/// Each binding's live token, read as a start of the driver reads them, none forgotten.
fn live(files: &[PathBuf], state: &Path) -> BTreeMap<Binding, String> {
	let (lists, unread) = kept::held(&state.join("lists"));
	for why in unread {
		eprintln!("lists {why}");
	}
	let forgotten: Vec<[u8; 32]> = lists.iter().flat_map(|l| l.forgotten.iter().copied()).collect();
	let mut tokens = Tokens::default();
	tokens.forget(&forgotten);
	tokens.reload(files);
	let mut live = BTreeMap::new();
	for file in files {
		let Ok(text) = std::fs::read_to_string(file) else { continue };
		let token = text.strip_suffix('\n').unwrap_or(&text);
		if let Ok(binding) = tokens.check(Some(&format!("Bearer {token}"))) {
			live.entry(binding).or_insert_with(|| token.to_owned());
		}
	}
	live
}

/// Each deployment's id among a namespace's containers.
fn ids(listed: &[Listed]) -> BTreeSet<u32> {
	listed.iter().filter_map(|l| entry::labeled(l.labels.get(entry::RUNS)?)).collect()
}

/// A read of every deployment containerd holds of a binding with a live token.
async fn read_all(
	reach: &Reach,
	ports: &Ports,
	tokens: &BTreeMap<Binding, String>,
) -> Result<BTreeMap<Deployment, Seen>, String> {
	let containerd = Socket { path: reach.containerd.clone() };
	let (lists, _) = kept::held(&reach.state.join("lists"));
	let mut read = BTreeMap::new();
	for list in lists {
		let listed = containerd.list(&list.namespace).await.map_err(|f| f.0)?;
		let found = ids(&listed);
		let Some(token) = tokens.get(&list.binding) else {
			if !found.is_empty() {
				eprintln!("snapshot: binding {} has no live token, not judged", list.binding);
			}
			continue;
		};
		for id in found {
			read.insert((list.binding, id), ports.deployment(token, id).await?);
		}
	}
	Ok(read)
}

/// The baseline, what both reads agree stands running or stopped; the rest is in flight, a deploy,
/// a stop or a replacement a restart may cut short, which no later state can be held to.
fn settled(
	first: &BTreeMap<Deployment, Seen>,
	second: &BTreeMap<Deployment, Seen>,
) -> (BTreeMap<Deployment, Seen>, Vec<Deployment>) {
	let mut baseline = BTreeMap::new();
	let mut flight = Vec::new();
	for key in first.keys().chain(second.keys()).collect::<BTreeSet<_>>() {
		match (first.get(key), second.get(key)) {
			(Some(one), Some(two)) if one == two && matches!(one, Seen::Running | Seen::Stopped) => {
				baseline.insert(*key, one.clone());
			}
			_ => flight.push(*key),
		}
	}
	(baseline, flight)
}

/// A baseline as its file holds it, read by a later version than wrote it, so its fields stay.
fn written(baseline: &BTreeMap<Deployment, Seen>) -> Value {
	let deployments: Vec<Value> = baseline
		.iter()
		.map(|((binding, id), seen)| json!({ "binding": binding, "id": id, "state": seen.named() }))
		.collect();
	json!({ "deployments": deployments })
}

/// A baseline from its file, any state but the two passed over as a later version's own.
fn unwritten(file: &str) -> Result<BTreeMap<Deployment, Seen>, String> {
	let json: Value = serde_json::from_str(file).map_err(|e| format!("not JSON, {e}"))?;
	let rows = json.get("deployments").and_then(Value::as_array).ok_or("no list of deployments")?;
	let mut baseline = BTreeMap::new();
	for row in rows {
		let number =
			|name: &str| row.get(name).and_then(Value::as_u64).and_then(|n| u32::try_from(n).ok());
		let (Some(binding), Some(id)) = (number("binding"), number("id")) else {
			return Err("a deployment without its binding or id".to_owned());
		};
		match text(row, "state") {
			Some("running") => baseline.insert((binding, id), Seen::Running),
			Some("stopped") => baseline.insert((binding, id), Seen::Stopped),
			_ => None,
		};
	}
	Ok(baseline)
}

/// The baseline taken and written, the old version's own answer of what stands.
pub(crate) async fn snapshot(arguments: SnapshotArguments) -> ExitCode {
	match snapshot_taken(&arguments).await {
		Ok(()) => ExitCode::SUCCESS,
		Err(why) => {
			eprintln!("snapshot: {why}");
			ExitCode::FAILURE
		}
	}
}

async fn snapshot_taken(arguments: &SnapshotArguments) -> Result<(), String> {
	let reach = &arguments.reach;
	let ports = Ports::of(reach)?;
	let tokens = live(&reach.bindings, &reach.state);
	let first = read_all(reach, &ports, &tokens).await?;
	let second = if first.is_empty() {
		first.clone()
	} else {
		tokio::time::sleep(Duration::from_secs(arguments.apart)).await;
		read_all(reach, &ports, &tokens).await?
	};
	let (baseline, flight) = settled(&first, &second);
	for (binding, id) in &flight {
		eprintln!("snapshot: deployment {id:08x} of binding {binding} in flight, not judged");
	}
	eprintln!("snapshot: {} deployments", baseline.len());
	let file = &arguments.file;
	std::fs::write(file, written(&baseline).to_string())
		.map_err(|e| format!("{}: {e}", file.display()))
}

/// A service as systemctl shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Shown {
	active: String,
	identity: (String, String),
}

/// What `systemctl show` wrote of a service.
fn shown(text: &str) -> Shown {
	let field = |name: &str| {
		let prefix = format!("{name}=");
		text.lines().find_map(|l| l.strip_prefix(&prefix)).unwrap_or_default().to_owned()
	};
	Shown { active: field("ActiveState"), identity: (field("MainPID"), field("NRestarts")) }
}

/// Both services as systemctl shows them now.
async fn services(systemctl: &Path) -> Result<[Shown; 2], String> {
	let systemctl = systemctl.to_owned();
	let read = move |unit: &str| {
		let output = Command::new(&systemctl)
			.args(["show", "--property=ActiveState", "--property=MainPID", "--property=NRestarts", unit])
			.output()
			.map_err(|e| format!("{}: {e}", systemctl.display()))?;
		if !output.status.success() {
			return Err(format!("systemctl show {unit} ended {}", output.status));
		}
		Ok(shown(&String::from_utf8_lossy(&output.stdout)))
	};
	tokio::task::spawn_blocking(move || Ok([read(SERVICES[0])?, read(SERVICES[1])?]))
		.await
		.map_err(|e| e.to_string())?
}

/// Whether each service is active and is the process it was.
fn held_up(unit: &str, first: &Shown, now: &Shown) -> Result<(), String> {
	if !matches!(now.active.as_str(), "active" | "reloading" | "refreshing") {
		return Err(format!("{unit} is {}", now.active));
	}
	if now.identity != first.identity {
		let (pid, restarts) = (&now.identity.0, &now.identity.1);
		return Err(format!("{unit} restarted, now pid {pid} after {restarts} restarts"));
	}
	Ok(())
}

/// Level 1, both services active from now and each the same process at the end of the settle.
async fn level_one(systemctl: &Path, settle: Duration) -> Result<[Shown; 2], String> {
	let first = services(systemctl).await?;
	let until = Instant::now() + settle;
	loop {
		let now = services(systemctl).await?;
		for (at, unit) in SERVICES.iter().enumerate() {
			if let (Some(first), Some(now)) = (first.get(at), now.get(at)) {
				held_up(unit, first, now)?;
			}
		}
		if Instant::now() >= until {
			return Ok(first);
		}
		tokio::time::sleep(AGAIN).await;
	}
}

/// One round of level 2, each binding's describe, a live token denied or a version not this one's
/// a failure, and the entry's answer.
async fn answering(ports: &Ports, tokens: &BTreeMap<Binding, String>) -> Result<(), String> {
	let bare = tokens.is_empty();
	for token in tokens.values().map(|t| Some(t.as_str())).chain(bare.then_some(None)) {
		let answered = ports.call(token, "management", "describe", &json!({})).await?;
		// With no token to call by, the answer that it is denied is the port's whole answer.
		let good = match token {
			Some(_) => answered.status == 200 && text(&answered.body, "status") == Some("success"),
			None => answered.status == 403 && text(&answered.body, "reason") == Some("denied"),
		};
		if !good {
			return Err(format!("describe answered {}", answered.status));
		}
		if answered.served.as_deref() != Some(SERVED_AS) {
			let served = answered.served.as_deref().unwrap_or("nothing");
			return Err(format!("the driver answered as {served}, not {SERVED_AS}"));
		}
	}
	ports.entry_answers().await
}

/// Level 2, asked again until the driver has done with what a start does before it listens.
async fn level_two(
	ports: &Ports,
	tokens: &BTreeMap<Binding, String>,
	within: Duration,
) -> Result<(), String> {
	let until = Instant::now() + within;
	loop {
		match answering(ports, tokens).await {
			Ok(()) => return Ok(()),
			Err(why) if Instant::now() >= until => return Err(why),
			Err(_) => tokio::time::sleep(AGAIN).await,
		}
	}
}

/// What of the baseline does not stand now, each a line.
fn differences(
	baseline: &BTreeMap<Deployment, Seen>,
	now: &BTreeMap<Deployment, Seen>,
) -> Vec<String> {
	let gone = Seen::Absent;
	baseline
		.iter()
		.filter_map(|(key, was)| {
			let seen = now.get(key).unwrap_or(&gone);
			(seen != was).then(|| {
				let (binding, id) = key;
				format!(
					"deployment {id:08x} of binding {binding} was {} and is {}",
					was.named(),
					seen.named()
				)
			})
		})
		.collect()
}

/// One round of level 3, a binding whose token went since the baseline passed over and told.
async fn matching(
	ports: &Ports,
	tokens: &BTreeMap<Binding, String>,
	baseline: &BTreeMap<Deployment, Seen>,
) -> Result<(), String> {
	let mut now = baseline.clone();
	for ((binding, id), seen) in &mut now {
		match tokens.get(binding) {
			Some(token) => *seen = ports.deployment(token, *id).await?,
			None => eprintln!("check: binding {binding} has no live token, {id:08x} not judged"),
		}
	}
	let different = differences(baseline, &now);
	if different.is_empty() { Ok(()) } else { Err(different.join("; ")) }
}

/// Level 3, asked again as a deployment's address comes back after a restart.
async fn level_three(
	ports: &Ports,
	tokens: &BTreeMap<Binding, String>,
	baseline: &BTreeMap<Deployment, Seen>,
	within: Duration,
) -> Result<(), String> {
	let until = Instant::now() + within;
	loop {
		match matching(ports, tokens, baseline).await {
			Ok(()) => return Ok(()),
			Err(why) if Instant::now() >= until => return Err(why),
			Err(_) => tokio::time::sleep(AGAIN).await,
		}
	}
}

/// The update judged, each level said, the first to fail its last line and a failure's exit.
pub(crate) async fn check(arguments: CheckArguments) -> ExitCode {
	match checked(&arguments).await {
		Ok(()) => {
			eprintln!("check: passed");
			ExitCode::SUCCESS
		}
		Err(why) => {
			eprintln!("check: {why}");
			ExitCode::FAILURE
		}
	}
}

async fn checked(arguments: &CheckArguments) -> Result<(), String> {
	let reach = &arguments.reach;
	let seconds = Duration::from_secs;
	let baseline = match &arguments.snapshot {
		Some(file) => {
			let text = std::fs::read_to_string(file);
			let text = text.map_err(|e| format!("level 3, {}: {e}", file.display()))?;
			Some(unwritten(&text).map_err(|why| format!("level 3, {}: {why}", file.display()))?)
		}
		None => None,
	};
	let ports = Ports::of(reach)?;
	let at = |level: u8| move |why: String| format!("level {level}, {why}");
	let first = level_one(&reach.systemctl, seconds(arguments.settle)).await.map_err(at(1))?;
	eprintln!("check: level 1 passed");
	let tokens = live(&reach.bindings, &reach.state);
	level_two(&ports, &tokens, seconds(arguments.answering)).await.map_err(at(2))?;
	eprintln!("check: level 2 passed");
	match &baseline {
		Some(baseline) => {
			level_three(&ports, &tokens, baseline, seconds(arguments.matching)).await.map_err(at(3))?;
			eprintln!("check: level 3 passed, {} deployments", baseline.len());
		}
		None => eprintln!("check: level 3 skipped, no snapshot"),
	}
	// A crash while the later levels waited is level 1's too.
	let now = services(&reach.systemctl).await.map_err(at(1))?;
	for (at_unit, unit) in SERVICES.iter().enumerate() {
		if let (Some(first), Some(now)) = (first.get(at_unit), now.get(at_unit)) {
			held_up(unit, first, now).map_err(at(1))?;
		}
	}
	Ok(())
}

#[cfg(test)]
mod tests;
