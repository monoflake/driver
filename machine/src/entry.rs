//! The entry, a request for a host handed to the deployment its name is bound to and carried
//! unread both ways, a process of its own reading containerd alone, RFCs vr5lw, n0o4l and rmll5;
//! its listener taken from its socket unit and what it has begun answered before it stops, ehm48.

use std::collections::BTreeMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::Request;
use axum::http::uri::{Authority, Scheme};
use axum::http::{HeaderMap, HeaderName, HeaderValue, StatusCode, Uri, Version, header};
use axum::response::{IntoResponse, Response};
use driver_machine_container::{Containerd, Fault, Listed, Reached, Socket, Task};
use driver_machine_management::Binding;
use envelope::contracts::DeploymentRuns;
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::{TokioExecutor, TokioIo};

/// The entry's port, ENTRY on a keypad, as the driver's is DRIVE.
const PORT: u16 = 36879;

/// Where the entry listens unless told, loopback alone, so only what is put in front of it reaches
/// it and nothing is opened by a default.
const LISTEN: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), PORT);

/// What the entry is started with, its address and containerd's socket, and nothing of the driver.
#[derive(Debug, Clone, clap::Args)]
pub(crate) struct Arguments {
	/// The address and port it listens on, plain HTTP, TLS the tunnel's in front of it now, unless
	/// systemd passes it a listener.
	#[arg(long, value_name = "address:port", default_value_t = LISTEN)]
	listen: SocketAddr,
	/// containerd's socket.
	#[arg(long, value_name = "socket", default_value = "/run/containerd/containerd.sock")]
	containerd: PathBuf,
	/// The containers' subnet, in CIDR notation, the driver's own `--subnet`; a request from it is
	/// a deployment's, let reach only what that deployment reaches.
	#[arg(long, value_name = "subnet", value_parser = subnet)]
	subnet: Subnet,
}

/// An IPv4 subnet, its first address and its mask.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Subnet(u32, u32);

impl Subnet {
	pub(crate) fn holds(self, ip: IpAddr) -> bool {
		match ip.to_canonical() {
			IpAddr::V4(v4) => u32::from(v4) & self.1 == self.0,
			IpAddr::V6(_) => false,
		}
	}
}

/// A subnet as `--subnet` takes it.
pub(crate) fn subnet(text: &str) -> Result<Subnet, String> {
	let malformed = || "expected an IPv4 subnet in CIDR notation".to_owned();
	let (address, length) = text.split_once('/').ok_or_else(malformed)?;
	let address: Ipv4Addr = address.parse().map_err(|_| malformed())?;
	let length: u32 = length.parse().map_err(|_| malformed())?;
	let shift = 32u32.checked_sub(length).ok_or_else(malformed)?;
	let mask = u32::MAX.checked_shl(shift).unwrap_or(0);
	Ok(Subnet(u32::from(address) & mask, mask))
}

/// How long a deployment's address is given to accept a connection before it is taken as down.
const CONNECTING: Duration = Duration::from_secs(5);

/// How long the requests begun when it is told to stop are given to be answered before it exits.
const DRAIN: Duration = Duration::from_secs(10);

/// How long a connection that has sent nothing yet when it is told to stop is given to send its
/// first request, as one closed before it is read is lost to its client.
const FIRST: Duration = Duration::from_secs(1);

/// How long an address containerd last gave is answered from while containerd cannot be reached,
/// as while it restarts its shims keep each task running.
const KEPT: Duration = Duration::from_secs(60);

/// The headers of one connection alone, never carried past it, RFC 9110 section 7.6.1.
const HOP: [HeaderName; 6] = [
	header::CONNECTION,
	HeaderName::from_static("keep-alive"),
	HeaderName::from_static("proxy-connection"),
	header::TE,
	header::TRANSFER_ENCODING,
	header::UPGRADE,
];

/// The forwarding headers it adds.
const FORWARDED_FOR: HeaderName = HeaderName::from_static("x-forwarded-for");
const FORWARDED_PROTO: HeaderName = HeaderName::from_static("x-forwarded-proto");
const FORWARDED_HOST: HeaderName = HeaderName::from_static("x-forwarded-host");

/// The header families a proxy or an edge writes of a request or its client, by prefix, as the
/// control's `reach.res` takes every `cf-` header for the edge's.
const PROXIED_FAMILIES: [&str; 3] = ["cf-", "x-forwarded", "x-original-forwarded"];

/// The rest of what a proxy or an edge says of a request or its client, by name.
const PROXIED: [&str; 9] = [
	"forwarded",
	"via",
	"cdn-loop",
	"true-client-ip",
	"x-real-ip",
	"x-client-ip",
	"x-cluster-client-ip",
	"client-ip",
	"fastly-client-ip",
];

/// Whether a header describes forwarding or the client, its `_` read as `-` as some stacks read it.
fn proxied(name: &str) -> bool {
	let name = name.to_ascii_lowercase().replace('_', "-");
	PROXIED_FAMILIES.iter().any(|f| name.starts_with(f)) || PROXIED.contains(&name.as_str())
}

/// What kind of deployment runs in a container, as its labels say.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Kind {
	/// An app.
	App,
	/// A component, RFC y2xd3.
	Component,
}

/// How a host writes a deployment's id.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Written {
	/// In 8 lowercase hex digits, whatever its kind, RFC b8f35.
	Hex,
	/// As `app-<id>` in decimal, an app's alone.
	/// A scaffold kept for the apps deployed before, retired with platform RFC 8yl4b.
	App,
}

/// A deployment as a host names it, by its id within a binding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Named {
	pub(crate) binding: Binding,
	pub(crate) written: Written,
	pub(crate) id: u32,
}

impl Named {
	/// Its name, as a host gives it, its binding in 8 hex digits however the host wrote it.
	fn name(self) -> String {
		match self.written {
			Written::Hex => format!("{:08x}.b{:08x}", self.id, self.binding),
			Written::App => format!("app-{}.b{:08x}", self.id, self.binding),
		}
	}
}

/// A decimal number written as a name writes it, digits alone with no zero leading but zero's own,
/// so one deployment has one name.
fn number<T: std::str::FromStr>(text: &str) -> Option<T> {
	let canonical = !text.is_empty()
		&& text.bytes().all(|b| b.is_ascii_digit())
		&& (text == "0" || !text.starts_with('0'));
	canonical.then(|| text.parse().ok()).flatten()
}

/// An id written as a name writes it, 8 lowercase hex digits, so one deployment has one name.
fn hex(text: &str) -> Option<u32> {
	let written = text.len() == 8 && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
	written.then(|| u32::from_str_radix(text, 16).ok()).flatten()
}

/// The deployment a host names by its leftmost two labels, `<id in 8 hex digits>.b<binding in 8 hex
/// digits>`, the rest passed over, none where those two are not so.
pub(crate) fn named(host: &str) -> Option<Named> {
	// A name is its deployment's address with no table, provisional for RFC n0o4l.
	let host = host.split(':').next().unwrap_or_default();
	let mut labels = host.split('.');
	let deployment = labels.next()?;
	let binding = labels.next()?;
	let (written, id) = match hex(deployment) {
		Some(id) => (Written::Hex, id),
		None => {
			// A scaffold kept for the apps deployed before, retired with platform RFC 8yl4b.
			let head = deployment.get(..4)?;
			head.eq_ignore_ascii_case("app-").then_some(())?;
			(Written::App, number(deployment.get(4..)?)?)
		}
	};
	let (letter, binding) = (binding.get(..1)?, binding.get(1..)?);
	if !letter.eq_ignore_ascii_case("b") {
		return None;
	}
	// A scaffold for bindings made before hex ids, retired once none of them is on the machine.
	let binding = hex(binding).or_else(|| number(binding))?;
	Some(Named { binding, written, id })
}

/// The labels the container kind writes on each container, read here as it writes them.
pub(crate) const RUNS: &str = "driver.runs";
pub(crate) const ADDRESS: &str = "driver.address";
pub(crate) const REACHING: &str = "driver.reaching";
const KIND: &str = "driver.kind";

/// The id a label of what a container runs or reaches names, written in 8 hex digits, or as an
/// app's was before, `app/<id>` in decimal, a scaffold retired with platform RFC 8yl4b.
fn labeled(label: &str) -> Option<u32> {
	hex(label).or_else(|| number(label.strip_prefix("app/")?))
}

/// The kind of the deployment of an id, as its containers' labels say, none where none runs it; a
/// container labeled before its kind was is an app's.
pub(crate) fn kind(listed: &[Listed], id: u32) -> Option<Kind> {
	let mine = listed.iter().find(|l| l.labels.get(RUNS).and_then(|r| labeled(r)) == Some(id))?;
	match mine.labels.get(KIND).map(String::as_str) {
		Some("component") => Some(Kind::Component),
		// No kind label is an app's, a scaffold retired with platform RFC 8yl4b.
		Some(_) | None => Some(Kind::App),
	}
}

/// Whether a request from `peer` may reach the deployment of an id and a kind, a container held to
/// its own `reaching` and a component reached by a container alone, RFC y2xd3.
pub(crate) fn allowed(
	listed: &[Listed],
	named: Named,
	kind: Option<Kind>,
	peer: IpAddr,
	subnet: Subnet,
) -> Gate {
	let peer = peer.to_canonical();
	if !subnet.holds(peer) {
		// From loopback, the tunnel or the tailnet, an app as before and a component as nothing.
		return match kind {
			Some(Kind::App) | None => Gate::Pass,
			Some(Kind::Component) => Gate::Hidden,
		};
	}
	let ip = |l: &Listed| {
		let address = l.labels.get(ADDRESS)?;
		address.parse::<SocketAddr>().ok().map(|a| a.ip().to_canonical())
	};
	// A source is known only by a running container, never a label alone.
	let running = |l: &&Listed| l.task == Some(Task::Running) && l.labels.contains_key(RUNS);
	let source = listed.iter().filter(running).find(|l| ip(l) == Some(peer));
	let reaches = source
		.and_then(|s| s.labels.get(REACHING))
		.is_some_and(|reaching| reaching.split(',').any(|r| labeled(r) == Some(named.id)));
	match reaches {
		true => Gate::Pass,
		false => Gate::Refused,
	}
}

/// What the entry makes of who asks for a deployment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Gate {
	/// Let through.
	Pass,
	/// A container asking for what its `reaching` does not hold, or a source no running container
	/// of the binding holds.
	Refused,
	/// Answered as though nothing were deployed by the name.
	Hidden,
}

/// Where a named deployment is reached, as it is found at a request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Found {
	/// Running, at its address.
	Running(SocketAddr),
	/// Held, and not running now.
	Down,
	/// Nothing deployed by the name.
	Absent,
	/// A deployment whose `reaching` does not hold it asked for it.
	Refused,
}

/// What finds the deployment a name is bound to; implemented for [`Driver`].
pub(crate) trait Find: Send + Sync + 'static {
	/// The deployment, as it is now, as a request from `peer` may reach it.
	fn find(&self, named: Named, peer: IpAddr) -> impl Future<Output = Found> + Send;
}

/// The address each app was last found running at, and when.
#[derive(Debug, Default)]
struct Last(Mutex<BTreeMap<Named, (SocketAddr, Instant)>>);

impl Last {
	/// What containerd answered of a deployment kept, an app's address while it runs, nothing else,
	/// as a component's path stays closed while containerd cannot say who asks.
	fn found(&self, named: Named, kind: Option<Kind>, found: Found, at: Instant) {
		let mut last = self.0.lock().unwrap_or_else(PoisonError::into_inner);
		match (found, kind) {
			(Found::Running(address), Some(Kind::App)) => last.insert(named, (address, at)),
			(Found::Running(_), Some(Kind::Component) | None)
			| (Found::Down | Found::Absent | Found::Refused, _) => last.remove(&named),
		};
	}

	/// The address last found, where it was found within [`KEPT`] of `at`.
	fn recalled(&self, named: Named, at: Instant) -> Option<SocketAddr> {
		let last = self.0.lock().unwrap_or_else(PoisonError::into_inner);
		let (address, found) = last.get(&named)?;
		(at.saturating_duration_since(*found) <= KEPT).then_some(*address)
	}
}

/// What finds a deployment from containerd's labels, in its binding's namespace as the driver names
/// it, with no call to the driver, and what it last found.
struct Labels<C> {
	containerd: C,
	last: Last,
	subnet: Subnet,
}

/// The first binding past 7 decimal digits, whose decimal name could be another binding's in hex.
/// Below 8 digits no decimal name is a hex one, kept until no binding made before hex ids remains.
const DECIMAL: Binding = 10_000_000;

impl<C: Containerd> Labels<C> {
	/// The containers of a binding and their namespace, the one named in hex, or where that holds
	/// none and the binding is below [`DECIMAL`], the one named in decimal.
	async fn held(&self, binding: Binding) -> (String, Result<Vec<Listed>, Fault>) {
		let namespace = crate::listed::namespace(binding);
		match self.containerd.list(&namespace).await {
			// A scaffold for bindings made before hex ids, retired once none of them is on the machine.
			Ok(listed) if listed.is_empty() && binding < DECIMAL => {
				let decimal = crate::listed::decimal(binding);
				let listed = self.containerd.list(&decimal).await;
				(decimal, listed)
			}
			listed => (namespace, listed),
		}
	}
}

impl<C: Containerd + 'static> Find for Labels<C> {
	/// Read at each request, as the container kind reads them at a start; while containerd cannot
	/// be reached, the address last found, never once containerd has said it is gone.
	async fn find(&self, named: Named, peer: IpAddr) -> Found {
		let (namespace, listed) = self.held(named.binding).await;
		match listed {
			Ok(listed) => {
				let kind = kind(&listed, named.id);
				// The decimal name is an app's alone, retired with platform RFC 8yl4b.
				if named.written == Written::App && kind == Some(Kind::Component) {
					return Found::Absent;
				}
				match allowed(&listed, named, kind, peer, self.subnet) {
					Gate::Pass => {}
					Gate::Refused => return Found::Refused,
					Gate::Hidden => return Found::Absent,
				}
				let id = named.id;
				let runs = match kind {
					Some(Kind::Component) => DeploymentRuns::Component { component: String::new(), id },
					Some(Kind::App) | None => DeploymentRuns::App { id },
				};
				let found = match driver_machine_container::reached(&listed, &runs) {
					Reached::Running(address) => address.parse().map_or(Found::Down, Found::Running),
					Reached::Down => Found::Down,
					Reached::Absent => Found::Absent,
				};
				self.last.found(named, kind, found, Instant::now());
				found
			}
			// Who asks cannot be told now, so nothing a check would hold is let through.
			Err(Fault(why)) if self.subnet.holds(peer) => {
				eprintln!("entry {namespace}: {why}, the request refused");
				Found::Refused
			}
			Err(Fault(why)) => {
				let recalled = self.last.recalled(named, Instant::now());
				let from = if recalled.is_some() { ", the address last found taken" } else { "" };
				eprintln!("entry {namespace}: {why}{from}");
				recalled.map_or(Found::Down, Found::Running)
			}
		}
	}
}

/// What every request is served with, what finds a deployment, the client that reaches it and the
/// containers' subnet.
struct Entry<F> {
	find: Arc<F>,
	client: Client<HttpConnector, Body>,
	subnet: Subnet,
}

/// An answer of the entry's own, in plain text.
fn own(status: StatusCode, text: &'static str) -> Response {
	(status, [(header::CONTENT_TYPE, "text/plain; charset=utf-8")], text).into_response()
}

/// Every header naming one connection removed, those its `Connection` names among them.
fn unhopped(headers: &mut HeaderMap) {
	let named: Vec<HeaderName> = headers
		.get_all(header::CONNECTION)
		.iter()
		.filter_map(|v| v.to_str().ok())
		.flat_map(|v| v.split(','))
		.filter_map(|n| HeaderName::try_from(n.trim()).ok())
		.collect();
	for name in HOP.iter().chain(&named) {
		headers.remove(name);
	}
}

/// Every header describing forwarding or the client removed, so a container's chain is its own.
fn unproxied(headers: &mut HeaderMap) {
	let named: Vec<HeaderName> = headers.keys().filter(|n| proxied(n.as_str())).cloned().collect();
	for name in named {
		headers.remove(name);
	}
}

/// The host a request names, a container's by its `Host` alone, a proxy's by the first of its
/// `X-Forwarded-Host`, target's authority and `Host` naming a deployment, RFCs rxmd9 and y2xd3.
fn host(request: &Request, peer: IpAddr, subnet: Subnet) -> Option<String> {
	let text = |name| request.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_owned);
	// A container is nobody's proxy, so it is held to its reaching by the name it sent itself.
	if subnet.holds(peer) {
		return text(header::HOST);
	}
	// workerd writes the gateway's host into the first alone, and an edge writes its own name there.
	let given = [
		text(FORWARDED_HOST),
		request.uri().authority().map(|a| a.as_str().to_owned()),
		text(header::HOST),
	];
	let mut given = given.into_iter().flatten().peekable();
	let first = given.peek().cloned();
	given.find(|host| named(host).is_some()).or(first)
}

/// The request carried to the deployment at its address, as it came but for the headers of its
/// connection, a container's forwarding headers and those added, and the answer carried back.
async fn forwarded<F>(
	entry: &Entry<F>,
	address: SocketAddr,
	peer: SocketAddr,
	host: &str,
	request: Request,
) -> Response {
	let contained = entry.subnet.holds(peer.ip());
	let (mut parts, body) = request.into_parts();
	let mut target = parts.uri.into_parts();
	target.scheme = Some(Scheme::HTTP);
	target.authority = Authority::try_from(address.to_string()).ok();
	let Ok(uri) = Uri::from_parts(target) else {
		return own(StatusCode::BAD_REQUEST, "the request's target is not one to carry\n");
	};
	parts.uri = uri;
	parts.version = Version::HTTP_11;
	let headers = &mut parts.headers;
	unhopped(headers);
	if contained {
		unproxied(headers);
	}
	let before = headers.get(&FORWARDED_FOR).and_then(|v| v.to_str().ok());
	let peer = peer.ip().to_string();
	let chain = before.map_or_else(|| peer.clone(), |b| format!("{b}, {peer}"));
	let values = [
		(FORWARDED_FOR, HeaderValue::try_from(chain).ok()),
		(FORWARDED_PROTO, Some(HeaderValue::from_static("http"))),
		(FORWARDED_HOST, HeaderValue::try_from(host).ok()),
	];
	for (name, value) in values {
		if let Some(value) = value {
			headers.insert(name, value);
		}
	}
	match entry.client.request(Request::from_parts(parts, body)).await {
		Ok(answer) => {
			let (mut parts, body) = answer.into_parts();
			unhopped(&mut parts.headers);
			Response::from_parts(parts, Body::new(body))
		}
		Err(e) => {
			eprintln!("entry {address}: {e}");
			own(StatusCode::SERVICE_UNAVAILABLE, "the deployment did not answer\n")
		}
	}
}

/// Every request, whatever its method and path, handed to the deployment its host names, and one
/// line to stderr once its head is answered.
async fn entered<F: Find>(entry: &Entry<F>, peer: SocketAddr, request: Request) -> Response {
	// The challenge path of RFC vr5lw is not answered here yet, RFC n0o4l.
	let started = Instant::now();
	// A container's `Host` names its target, so more than one is answered 400, RFC 9112 section 3.2.
	let twice = entry.subnet.holds(peer.ip())
		&& request.headers().get_all(header::HOST).iter().nth(1).is_some();
	let host = host(&request, peer.ip(), entry.subnet);
	let named = host.as_deref().and_then(named);
	let (answer, name) = match (named, host) {
		_ if twice => (own(StatusCode::BAD_REQUEST, "a request has one host\n"), "-".to_owned()),
		(Some(named), Some(host)) => {
			let name = named.name();
			let answer = match entry.find.find(named, peer.ip()).await {
				Found::Running(address) => forwarded(entry, address, peer, &host, request).await,
				Found::Down => own(StatusCode::SERVICE_UNAVAILABLE, "the deployment is not running\n"),
				Found::Absent => own(StatusCode::NOT_FOUND, "nothing is deployed by this name\n"),
				Found::Refused => {
					own(StatusCode::FORBIDDEN, "the deployment asking does not reach this one\n")
				}
			};
			(answer, name)
		}
		(None, _) | (_, None) => {
			(own(StatusCode::NOT_FOUND, "the host names no deployment\n"), "-".to_owned())
		}
	};
	let took = started.elapsed().as_secs_f64() * 1000.0;
	eprintln!("entry {name} {} {took:.1}ms", answer.status().as_u16());
	answer
}

/// One connection served over HTTP/1.1 until it closes, or until it is told to stop, when the
/// request it has begun, or the first it is sent within [`FIRST`], is answered before it closes.
async fn connected<F: Find>(
	entry: Arc<Entry<F>>,
	stream: tokio::net::TcpStream,
	peer: SocketAddr,
	mut stopping: tokio::sync::watch::Receiver<bool>,
) {
	// A permit kept once any request has begun, so a stop waits for none on such a connection.
	let begun = Arc::new(tokio::sync::Notify::new());
	let began = Arc::clone(&begun);
	let service = hyper::service::service_fn(move |request: Request<hyper::body::Incoming>| {
		began.notify_one();
		let entry = Arc::clone(&entry);
		async move { Ok::<_, std::convert::Infallible>(entered(&entry, peer, request.map(Body::new)).await) }
	});
	// HTTP/1 alone, as a connection still reading which version it speaks is dropped at a stop.
	let connection =
		hyper::server::conn::http1::Builder::new().serve_connection(TokioIo::new(stream), service);
	let mut connection = std::pin::pin!(connection);
	let served = tokio::select! {
		served = connection.as_mut() => served,
		() = async { drop(stopping.wait_for(|stopped| *stopped).await) } => {
			let ended = tokio::select! {
				served = connection.as_mut() => Some(served),
				() = begun.notified() => None,
				() = tokio::time::sleep(FIRST) => None,
			};
			match ended {
				Some(served) => served,
				None => {
					connection.as_mut().graceful_shutdown();
					connection.await
				}
			}
		}
	};
	if let Err(e) = served {
		eprintln!("entry {peer}: {e}");
	}
}

/// The entry served on its listener until `stopped` is ready, then no connection accepted and
/// every one open answered and closed.
pub(crate) async fn serve<F: Find>(
	listener: tokio::net::TcpListener,
	find: Arc<F>,
	subnet: Subnet,
	stopped: impl Future<Output = ()> + Send + 'static,
) -> std::io::Result<()> {
	let mut connector = HttpConnector::new();
	connector.set_nodelay(true);
	connector.set_connect_timeout(Some(CONNECTING));
	let client = Client::builder(TokioExecutor::new()).build(connector);
	let entry = Arc::new(Entry { find, client, subnet });
	let (stop, stopping) = tokio::sync::watch::channel(false);
	// Each connection holds a receiver, so every one has closed once none is left.
	let (closed, open) = tokio::sync::watch::channel(());
	let mut stopped = std::pin::pin!(stopped);
	loop {
		let accepted = tokio::select! {
			accepted = listener.accept() => accepted,
			() = &mut stopped => break,
		};
		match accepted {
			Ok((stream, peer)) => {
				let (entry, stopping, open) = (Arc::clone(&entry), stopping.clone(), open.clone());
				tokio::spawn(async move {
					connected(entry, stream, peer, stopping).await;
					drop(open);
				});
			}
			// Out of descriptors or memory for a moment, as a connection closed before it is
			// taken is no fault of the entry's.
			Err(e) => {
				eprintln!("entry: {e}");
				tokio::time::sleep(Duration::from_millis(100)).await;
			}
		}
	}
	drop(listener);
	drop(open);
	let _ = stop.send(true);
	closed.closed().await;
	Ok(())
}

/// The listener systemd passed, its socket unit's, held across a restart so a connection waits
/// rather than being refused, or else one bound at `listen`, as `dev` and a test start it.
async fn listener(listen: SocketAddr) -> std::io::Result<(tokio::net::TcpListener, &'static str)> {
	match listenfd::ListenFd::from_env().take_tcp_listener(0)? {
		Some(passed) => {
			passed.set_nonblocking(true)?;
			Ok((tokio::net::TcpListener::from_std(passed)?, ", its socket unit's"))
		}
		None => Ok((tokio::net::TcpListener::bind(listen).await?, "")),
	}
}

/// SIGTERM, as systemd stops it, or SIGINT, as a terminal does.
async fn terminated() {
	use tokio::signal::unix::{SignalKind, signal};
	match signal(SignalKind::terminate()) {
		Ok(mut term) => {
			tokio::select! {
				_ = term.recv() => {}
				_ = tokio::signal::ctrl_c() => {}
			}
		}
		Err(e) => {
			eprintln!("entry: SIGTERM not watched, {e}");
			let _ = tokio::signal::ctrl_c().await;
		}
	}
}

/// The entry served at its address until the process is told to stop, then what it has begun
/// answered within [`DRAIN`].
pub(crate) async fn run(arguments: Arguments) -> ExitCode {
	let listen = arguments.listen;
	let (listener, whose) = match listener(listen).await {
		Ok(listener) => listener,
		Err(e) => {
			eprintln!("entry {listen}: {e}");
			return ExitCode::FAILURE;
		}
	};
	match listener.local_addr() {
		Ok(address) => eprintln!("entry on {address}{whose}"),
		Err(e) => eprintln!("entry on an address not read: {e}"),
	}
	let containerd = Socket { path: arguments.containerd };
	let find = Arc::new(Labels { containerd, last: Last::default(), subnet: arguments.subnet });
	let (stop, mut stopping) = tokio::sync::watch::channel(false);
	let stopped = async move {
		let _ = stopping.wait_for(|stopped| *stopped).await;
	};
	let mut serving = std::pin::pin!(serve(listener, find, arguments.subnet, stopped));
	let served = tokio::select! {
		served = &mut serving => Some(served),
		() = terminated() => None,
	};
	let served = match served {
		Some(served) => served,
		None => {
			eprintln!("entry stopping, answering what it has begun");
			let _ = stop.send(true);
			tokio::time::timeout(DRAIN, serving).await.unwrap_or_else(|_| {
				eprintln!("entry: requests still open after {}s, left", DRAIN.as_secs());
				Ok(())
			})
		}
	};
	match served {
		Ok(()) => ExitCode::SUCCESS,
		Err(e) => {
			eprintln!("entry: {e}");
			ExitCode::FAILURE
		}
	}
}

#[cfg(test)]
mod one_id;

#[cfg(test)]
mod tests;
