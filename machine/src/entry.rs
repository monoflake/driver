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
	fn holds(self, ip: IpAddr) -> bool {
		match ip.to_canonical() {
			IpAddr::V4(v4) => u32::from(v4) & self.1 == self.0,
			IpAddr::V6(_) => false,
		}
	}
}

/// A subnet as `--subnet` takes it.
fn subnet(text: &str) -> Result<Subnet, String> {
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

/// What kind of deployment a name names.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Kind {
	/// `app-<id>`.
	App,
	/// `component-<id>`, its id in 8 lowercase hex digits, RFC y2xd3.
	Component,
}

/// A deployment as a host names it, an app or a component of a binding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Named {
	pub(crate) binding: Binding,
	pub(crate) kind: Kind,
	pub(crate) id: u32,
}

impl Named {
	/// What it runs, as the deployments interface names it.
	fn runs(self) -> DeploymentRuns {
		match self.kind {
			Kind::App => DeploymentRuns::App { id: self.id },
			Kind::Component => DeploymentRuns::Component { component: String::new(), id: self.id },
		}
	}

	/// What it runs as the container kind's label holds it.
	fn label(self) -> String {
		match self.kind {
			Kind::App => format!("app/{}", self.id),
			Kind::Component => format!("component/{:08x}", self.id),
		}
	}

	/// Its name, as a host gives it.
	fn name(self) -> String {
		match self.kind {
			Kind::App => format!("app-{}.b{}", self.id, self.binding),
			Kind::Component => format!("component-{:08x}.b{}", self.id, self.binding),
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

/// An id written as a component's is, 8 lowercase hex digits, so one component has one name.
fn hex(text: &str) -> Option<u32> {
	let written = text.len() == 8 && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
	written.then(|| u32::from_str_radix(text, 16).ok()).flatten()
}

/// The deployment a host names by its leftmost two labels, `app-<id>.b<binding>` or
/// `component-<id>.b<binding>`, the rest passed over, none where those two are not so.
pub(crate) fn named(host: &str) -> Option<Named> {
	// A name is its deployment's address with no table, provisional for RFC n0o4l.
	let host = host.split(':').next().unwrap_or_default();
	let mut labels = host.split('.');
	let deployment = labels.next()?;
	let binding = labels.next()?;
	let (kind, id) = [("app-", Kind::App), ("component-", Kind::Component)].into_iter().find_map(
		|(prefix, kind)| {
			let head = deployment.get(..prefix.len())?;
			head.eq_ignore_ascii_case(prefix).then(|| (kind, deployment.get(prefix.len()..)))
		},
	)?;
	let (letter, binding) = (binding.get(..1)?, binding.get(1..)?);
	if !letter.eq_ignore_ascii_case("b") {
		return None;
	}
	let id = id?;
	let id = match kind {
		Kind::App => number(id)?,
		Kind::Component => hex(id)?,
	};
	Some(Named { binding: number(binding)?, kind, id })
}

/// The labels the container kind writes on each container, read here as it writes them.
pub(crate) const RUNS: &str = "driver.runs";
pub(crate) const ADDRESS: &str = "driver.address";
pub(crate) const REACHING: &str = "driver.reaching";

/// Whether a request from `peer` may reach a deployment, a container held to its own `reaching`
/// and a component reached by a container alone, RFC y2xd3.
pub(crate) fn allowed(listed: &[Listed], named: Named, peer: IpAddr, subnet: Subnet) -> Gate {
	let peer = peer.to_canonical();
	if !subnet.holds(peer) {
		// From loopback, the tunnel or the tailnet, an app as before and a component as nothing.
		return match named.kind {
			Kind::App => Gate::Pass,
			Kind::Component => Gate::Hidden,
		};
	}
	let ip = |l: &Listed| {
		let address = l.labels.get(ADDRESS)?;
		address.parse::<SocketAddr>().ok().map(|a| a.ip().to_canonical())
	};
	// A source is known only by a running container, never a label alone.
	let running = |l: &&Listed| l.task == Some(Task::Running) && l.labels.contains_key(RUNS);
	let source = listed.iter().filter(running).find(|l| ip(l) == Some(peer));
	let target = named.label();
	let reaches = source
		.and_then(|s| s.labels.get(REACHING))
		.is_some_and(|reaching| reaching.split(',').any(|r| r == target));
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

/// The address each deployment was last found running at, and when.
#[derive(Debug, Default)]
struct Last(Mutex<BTreeMap<Named, (SocketAddr, Instant)>>);

impl Last {
	/// What containerd answered of a deployment kept, its address while it runs, nothing else.
	fn found(&self, named: Named, found: Found, at: Instant) {
		let mut last = self.0.lock().unwrap_or_else(PoisonError::into_inner);
		match found {
			Found::Running(address) => last.insert(named, (address, at)),
			Found::Down | Found::Absent | Found::Refused => last.remove(&named),
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

impl<C: Containerd + 'static> Find for Labels<C> {
	/// Read at each request, as the container kind reads them at a start; while containerd cannot
	/// be reached, the address last found, never once containerd has said it is gone.
	async fn find(&self, named: Named, peer: IpAddr) -> Found {
		let namespace = crate::listed::namespace(named.binding);
		let runs = named.runs();
		match self.containerd.list(&namespace).await {
			Ok(listed) => {
				match allowed(&listed, named, peer, self.subnet) {
					Gate::Pass => {}
					Gate::Refused => return Found::Refused,
					Gate::Hidden => return Found::Absent,
				}
				let found = match driver_machine_container::reached(&listed, &runs) {
					Reached::Running(address) => address.parse().map_or(Found::Down, Found::Running),
					Reached::Down => Found::Down,
					Reached::Absent => Found::Absent,
				};
				self.last.found(named, found, Instant::now());
				found
			}
			// Who asks cannot be told now, so nothing a check would hold is let through.
			Err(Fault(why)) if self.subnet.holds(peer) || named.kind == Kind::Component => {
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

/// What every request is served with, what finds a deployment and the client that reaches it.
struct Entry<F> {
	find: Arc<F>,
	client: Client<HttpConnector, Body>,
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

/// The host a request was sent to, the first of its `X-Forwarded-Host`, its target's authority and
/// its `Host` that names a deployment, else the first it has, RFC rxmd9.
fn host(request: &Request) -> Option<String> {
	// Trusted, as only loopback, the private address, the tunnel and a reacher reach it; a reacher
	// is held to its reaching by the host chosen here.
	let text = |name| request.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_owned);
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
/// connection and the forwarding headers added, and the answer carried back the same.
async fn forwarded<F>(
	entry: &Entry<F>,
	address: SocketAddr,
	peer: SocketAddr,
	host: &str,
	request: Request,
) -> Response {
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
	let host = host(&request);
	let named = host.as_deref().and_then(named);
	let (answer, name) = match (named, host) {
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
	stopped: impl Future<Output = ()> + Send + 'static,
) -> std::io::Result<()> {
	let mut connector = HttpConnector::new();
	connector.set_nodelay(true);
	connector.set_connect_timeout(Some(CONNECTING));
	let client = Client::builder(TokioExecutor::new()).build(connector);
	let entry = Arc::new(Entry { find, client });
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
	let mut serving = std::pin::pin!(serve(listener, find, stopped));
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
mod tests {
	use std::collections::BTreeMap;
	use std::io::{Read as _, Write as _};
	use std::net::{Ipv4Addr, SocketAddr, TcpStream};
	use std::sync::Arc;

	use axum::Router;
	use axum::body::Bytes;
	use axum::extract::Request;
	use axum::http::{HeaderMap, StatusCode};

	use std::time::{Duration, Instant};

	use super::{
		Find, Found, Gate, KEPT, Kind, Labels, Last, Named, allowed, host, named, serve, subnet,
	};
	use driver_machine_container::Listed;
	use driver_machine_container::{Containerd, Fault, Task};
	use std::net::IpAddr;

	/// Deployments found as the test says, none but those named.
	struct Stub(BTreeMap<Named, Found>);

	impl Find for Stub {
		async fn find(&self, named: Named, _: IpAddr) -> Found {
			self.0.get(&named).copied().unwrap_or(Found::Absent)
		}
	}

	const fn of(binding: u32, app: u32) -> Named {
		Named { binding, kind: Kind::App, id: app }
	}

	/// A container as the container kind labels it, what it runs, where and what it reaches, its
	/// task running.
	fn container(runs: &str, address: &str, reaching: &str) -> Listed {
		let mut labels = BTreeMap::from([
			("driver.runs".to_owned(), runs.to_owned()),
			("driver.address".to_owned(), address.to_owned()),
			("driver.version".to_owned(), "0".repeat(64)),
			("driver.runtime".to_owned(), "runc".to_owned()),
			("driver.port".to_owned(), "8080".to_owned()),
			("driver.user".to_owned(), "0:0".to_owned()),
		]);
		if !reaching.is_empty() {
			labels.insert("driver.reaching".to_owned(), reaching.to_owned());
		}
		Listed { id: runs.replace('/', "-"), labels, task: Some(Task::Running) }
	}

	fn app(id: u32) -> Named {
		of(1, id)
	}

	fn component(id: u32) -> Named {
		Named { binding: 1, kind: Kind::Component, id }
	}

	fn peer(ip: &str) -> IpAddr {
		ip.parse().unwrap()
	}

	#[test]
	fn a_container_reaches_through_the_entry_only_what_its_reaching_holds() {
		let target = component(0x1a2b_3c4d).label();
		let mut stopped = container("app/4", "192.0.2.8:8080", &target);
		stopped.task = Some(Task::Stopped(0));
		let listed = [
			container("app/1", "192.0.2.5:8080", &format!("{target},app/3")),
			container("app/2", "192.0.2.6:8080", ""),
			container(&target, "192.0.2.9:8080", ""),
			stopped,
		];
		let net = subnet("192.0.2.0/24").unwrap();
		let gate = |named, ip| allowed(&listed, named, peer(ip), net);
		assert_eq!(gate(component(0x1a2b_3c4d), "192.0.2.5"), Gate::Pass);
		assert_eq!(gate(app(3), "::ffff:192.0.2.5"), Gate::Pass);
		assert_eq!(gate(app(2), "192.0.2.5"), Gate::Refused, "not in its reaching");
		assert_eq!(gate(component(0x1a2b_3c4d), "192.0.2.6"), Gate::Refused, "reaching nothing");
		// One of the subnet no running container of the binding holds, as another binding's.
		assert_eq!(gate(component(0x1a2b_3c4d), "192.0.2.77"), Gate::Refused);
		assert_eq!(gate(component(0x1a2b_3c4d), "192.0.2.8"), Gate::Refused, "its task is not running");
		// From elsewhere, an app as before, a component as nothing deployed.
		assert_eq!(gate(app(2), "127.0.0.1"), Gate::Pass);
		assert_eq!(gate(app(2), "198.51.100.4"), Gate::Pass);
		assert_eq!(gate(component(0x1a2b_3c4d), "127.0.0.1"), Gate::Hidden);
	}

	/// containerd as the entry reads it, the containers given, or none to be had.
	struct Held(Option<Vec<Listed>>);

	impl Containerd for Held {
		async fn import(
			&self,
			_: &str,
			_: &std::path::Path,
		) -> Result<driver_machine_container::Image, Fault> {
			Err(Fault("not here".into()))
		}
		async fn prepare(
			&self,
			_: &str,
			_: &str,
			_: &driver_machine_container::Image,
		) -> Result<Vec<driver_machine_container::Mount>, Fault> {
			Err(Fault("not here".into()))
		}
		async fn snapshot_path(&self, _: &str, _: &str) -> Result<std::path::PathBuf, Fault> {
			Err(Fault("not here".into()))
		}
		async fn create(
			&self,
			_: &str,
			_: &driver_machine_container::Spec,
			_: &[driver_machine_container::Mount],
			_: &std::path::Path,
		) -> Result<(), Fault> {
			Err(Fault("not here".into()))
		}
		async fn start(&self, _: &str, _: &str) -> Result<u32, Fault> {
			Err(Fault("not here".into()))
		}
		async fn stop(&self, _: &str, _: &str, _: u64) -> Result<(), Fault> {
			Err(Fault("not here".into()))
		}
		async fn remove(&self, _: &str, _: &str) -> Result<(), Fault> {
			Err(Fault("not here".into()))
		}
		async fn list(&self, _: &str) -> Result<Vec<Listed>, Fault> {
			self.0.clone().ok_or_else(|| Fault("containerd is restarting".into()))
		}
	}

	fn labels(held: Option<Vec<Listed>>) -> Labels<Held> {
		Labels {
			containerd: Held(held),
			last: Last::default(),
			subnet: subnet("192.0.2.0/24").unwrap(),
		}
	}

	#[tokio::test]
	async fn the_entry_finds_a_target_for_a_reacher_alone_and_refuses_when_it_cannot_tell() {
		let target = component(0x1a2b_3c4d);
		let listed = vec![
			container("app/1", "192.0.2.5:8080", &target.label()),
			container("app/2", "192.0.2.6:8080", ""),
			container(&target.label(), "192.0.2.9:8080", ""),
		];
		let found = labels(Some(listed));
		let at: std::net::SocketAddr = "192.0.2.9:8080".parse().unwrap();
		assert_eq!(found.find(target, peer("192.0.2.5")).await, Found::Running(at));
		assert_eq!(found.find(target, peer("192.0.2.6")).await, Found::Refused);
		assert_eq!(found.find(target, peer("127.0.0.1")).await, Found::Absent);
		// containerd unlisted, a container's request and a component's are refused.
		let blind = labels(None);
		assert_eq!(blind.find(target, peer("192.0.2.5")).await, Found::Refused);
		assert_eq!(blind.find(target, peer("127.0.0.1")).await, Found::Refused);
		assert_eq!(blind.find(app(2), peer("192.0.2.5")).await, Found::Refused);
	}

	#[tokio::test]
	async fn a_request_refused_by_reaching_is_forbidden() {
		let at = entry(BTreeMap::from([(of(1, 1), Found::Refused)])).await;
		let (head, _) = sent(at, get("app-1.b1")).await;
		assert!(head.starts_with("HTTP/1.1 403 "), "{head}");
	}

	#[test]
	fn a_host_names_its_deployment_by_its_leftmost_two_labels() {
		assert_eq!(named("app-1.b1.local"), Some(of(1, 1)));
		assert_eq!(named("app-1.b1"), Some(of(1, 1)));
		assert_eq!(named("APP-42.B7.example.com:8080"), Some(of(7, 42)));
		assert_eq!(named("app-0.b0.x"), Some(of(0, 0)));
		let component = Named { binding: 1, kind: Kind::Component, id: 0x1a2b_3c4d };
		assert_eq!(named("component-1a2b3c4d.b1:36879"), Some(component));
		assert_eq!(named(&component.name()), Some(component));
		for bad in [
			"",
			"app-1",
			"app-.b1.x",
			"app-1.b.x",
			"app-01.b1.x",
			"app-1.b01.x",
			"app-+1.b1.x",
			"app-1.c1.x",
			"ap-1.b1.x",
			"component-.b1",
			"component-01.b1",
			"component-439041101.b1",
			"component-1A2B3C4D.b1",
			"component-1a2b3c4.b1",
			"comp-1.b1",
			"www.app-1.b1.x",
			"app-1.b99999999999.x",
			"127.0.0.1:36879",
			"[::1]:36879",
		] {
			assert_eq!(named(bad), None, "{bad}");
		}
	}

	#[test]
	fn the_first_forwarded_name_naming_a_deployment_is_taken() {
		let forwarded = Request::builder()
			.uri("http://10.200.0.1:36879/")
			.header("host", "10.200.0.1:36879")
			.header("x-forwarded-host", "app-1.b1.example.com")
			.body(axum::body::Body::empty())
			.unwrap();
		assert_eq!(host(&forwarded).as_deref().and_then(named), Some(of(1, 1)));
		let hosted = Request::builder()
			.uri("/")
			.header("host", "app-2.b3.local")
			.body(axum::body::Body::empty())
			.unwrap();
		assert_eq!(host(&hosted).as_deref().and_then(named), Some(of(3, 2)));
		let edged = Request::builder()
			.uri("/")
			.header("host", "app-4.b5")
			.header("x-forwarded-host", "tunnel.example.com")
			.body(axum::body::Body::empty())
			.unwrap();
		assert_eq!(host(&edged).as_deref().and_then(named), Some(of(5, 4)));
	}

	/// What the stub upstream was sent, written back as its body, and its own header and status.
	async fn echoed(request: Request) -> (StatusCode, HeaderMap, Bytes) {
		let (parts, body) = request.into_parts();
		let body = axum::body::to_bytes(body, 1 << 20).await.unwrap();
		let mut seen = format!("{} {}\n", parts.method, parts.uri);
		let mut names: Vec<_> = parts.headers.iter().collect();
		names.sort_by_key(|(n, _)| n.as_str());
		for (name, value) in names {
			seen.push_str(&format!("{name}: {}\n", value.to_str().unwrap_or("?")));
		}
		seen.push_str(&String::from_utf8_lossy(&body));
		let mut headers = HeaderMap::new();
		headers.insert("x-upstream", "hello".parse().unwrap());
		(StatusCode::CREATED, headers, Bytes::from(seen))
	}

	async fn listening() -> (tokio::net::TcpListener, SocketAddr) {
		let listener = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
		let address = listener.local_addr().unwrap();
		(listener, address)
	}

	/// The entry started on loopback over the deployments given, and its address.
	async fn entry(found: BTreeMap<Named, Found>) -> SocketAddr {
		let (listener, address) = listening().await;
		tokio::spawn(serve(listener, Arc::new(Stub(found)), std::future::pending()));
		address
	}

	/// A request written as given and read to its end on a thread that may block, its head and body.
	async fn sent(at: SocketAddr, request: String) -> (String, String) {
		let read = tokio::task::spawn_blocking(move || {
			let mut stream = TcpStream::connect(at).unwrap();
			stream.write_all(request.as_bytes()).unwrap();
			let mut read = String::new();
			stream.read_to_string(&mut read).unwrap();
			read
		})
		.await
		.unwrap();
		let (head, body) = read.split_once("\r\n\r\n").unwrap_or((&read, ""));
		(head.to_owned(), body.to_owned())
	}

	fn get(host: &str) -> String {
		format!("GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n")
	}

	#[tokio::test]
	async fn a_request_is_carried_to_its_deployment_and_its_answer_back() {
		let (listener, upstream) = listening().await;
		tokio::spawn(async move { axum::serve(listener, Router::new().fallback(echoed)).await });
		let at = entry(BTreeMap::from([(of(1, 1), Found::Running(upstream))])).await;
		let request = "POST /a/b?c=d&e HTTP/1.1\r\nHost: app-1.b1.local:8080\r\n\
			Connection: close, x-hop\r\nX-Hop: gone\r\nX-Forwarded-For: 192.0.2.1\r\n\
			X-Kept: kept\r\nContent-Length: 5\r\n\r\nhello";
		let (head, body) = sent(at, request.to_owned()).await;
		assert!(head.starts_with("HTTP/1.1 201 "), "{head}");
		assert!(head.to_lowercase().contains("x-upstream: hello"), "{head}");
		assert!(body.starts_with("POST /a/b?c=d&e\n"), "{body}");
		for line in [
			"host: app-1.b1.local:8080",
			"x-kept: kept",
			"x-forwarded-for: 192.0.2.1, 127.0.0.1",
			"x-forwarded-proto: http",
			"x-forwarded-host: app-1.b1.local:8080",
			"content-length: 5",
		] {
			assert!(body.lines().any(|l| l == line), "{line} not in {body}");
		}
		assert!(!body.contains("x-hop"), "{body}");
		assert!(body.ends_with("\nhello"), "{body}");
	}

	#[tokio::test]
	async fn a_host_naming_nothing_is_not_found_and_one_down_is_unavailable() {
		// An address nothing listens on, once the listener is dropped.
		let (closed, gone) = listening().await;
		drop(closed);
		let found = BTreeMap::from([(of(1, 2), Found::Down), (of(1, 3), Found::Running(gone))]);
		let at = entry(found).await;
		for (host, status) in [
			("localhost", 404),
			("app-1.b1.local", 404),
			("app-2.b1.local", 503),
			("app-3.b1.local", 503),
		] {
			let (head, _) = sent(at, get(host)).await;
			assert!(head.starts_with(&format!("HTTP/1.1 {status} ")), "{host} {head}");
		}
		let (head, _) = sent(at, "GET / HTTP/1.0\r\n\r\n".to_owned()).await;
		assert!(head.starts_with("HTTP/1.0 404 "), "{head}");
	}

	#[test]
	fn an_address_is_recalled_while_kept_and_never_once_containerd_says_it_is_gone() {
		let last = Last::default();
		let (at, address) = (Instant::now(), SocketAddr::from((Ipv4Addr::LOCALHOST, 8080)));
		assert_eq!(last.recalled(of(1, 1), at), None);
		last.found(of(1, 1), Found::Running(address), at);
		assert_eq!(last.recalled(of(1, 1), at + KEPT), Some(address));
		assert_eq!(last.recalled(of(1, 1), at + KEPT + Duration::from_millis(1)), None);
		assert_eq!(last.recalled(of(1, 2), at), None);
		for gone in [Found::Down, Found::Absent] {
			last.found(of(1, 1), Found::Running(address), at);
			last.found(of(1, 1), gone, at);
			assert_eq!(last.recalled(of(1, 1), at), None, "{gone:?}");
		}
	}

	#[tokio::test]
	async fn a_request_begun_before_the_stop_is_answered_and_then_the_entry_ends() {
		let (listener, upstream) = listening().await;
		let slow = Router::new().fallback(|| async {
			tokio::time::sleep(Duration::from_millis(300)).await;
			"slow"
		});
		tokio::spawn(async move { axum::serve(listener, slow).await });
		let (listener, at) = listening().await;
		let (stop, mut stopping) = tokio::sync::watch::channel(false);
		let stopped = async move {
			let _ = stopping.wait_for(|s| *s).await;
		};
		let found = Arc::new(Stub(BTreeMap::from([(of(1, 1), Found::Running(upstream))])));
		let serving = tokio::spawn(serve(listener, found, stopped));
		let asked = tokio::spawn(sent(at, get("app-1.b1")));
		tokio::time::sleep(Duration::from_millis(100)).await;
		stop.send(true).unwrap();
		let (head, body) = asked.await.unwrap();
		assert!(head.starts_with("HTTP/1.1 200 "), "{head}");
		assert_eq!(body, "slow");
		tokio::time::timeout(Duration::from_secs(2), serving).await.unwrap().unwrap().unwrap();
	}

	#[tokio::test]
	async fn a_connection_open_at_the_stop_is_answered_its_first_request() {
		let (listener, at) = listening().await;
		let (stop, mut stopping) = tokio::sync::watch::channel(false);
		let stopped = async move {
			let _ = stopping.wait_for(|s| *s).await;
		};
		let serving = tokio::spawn(serve(listener, Arc::new(Stub(BTreeMap::new())), stopped));
		let mut stream = TcpStream::connect(at).unwrap();
		tokio::time::sleep(Duration::from_millis(100)).await;
		stop.send(true).unwrap();
		tokio::time::sleep(Duration::from_millis(100)).await;
		let read = tokio::task::spawn_blocking(move || {
			stream.write_all(get("localhost").as_bytes()).unwrap();
			let mut read = String::new();
			stream.read_to_string(&mut read).unwrap();
			read
		})
		.await
		.unwrap();
		assert!(read.starts_with("HTTP/1.1 404 "), "{read}");
		tokio::time::timeout(Duration::from_secs(2), serving).await.unwrap().unwrap().unwrap();
	}
}
