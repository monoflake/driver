//! The entry, a request for a host handed to the deployment its name is bound to and carried
//! unread both ways, a process of its own reading containerd alone, RFCs vr5lw, n0o4l and rmll5.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::Router;
use axum::body::Body;
use axum::extract::{ConnectInfo, Request, State};
use axum::http::uri::{Authority, Scheme};
use axum::http::{HeaderMap, HeaderName, HeaderValue, StatusCode, Uri, Version, header};
use axum::response::{IntoResponse, Response};
use driver_machine_container::{Containerd, Fault, Reached, Socket};
use driver_machine_management::Binding;
use envelope::contracts::DeploymentRuns;
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::TokioExecutor;

/// The entry's port, ENTRY on a keypad, as the driver's is DRIVE.
const PORT: u16 = 36879;

/// Where the entry listens unless told, loopback alone, so only what is put in front of it reaches
/// it and nothing is opened by a default.
const LISTEN: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), PORT);

/// What the entry is started with, its address and containerd's socket, and nothing of the driver.
#[derive(Debug, Clone, clap::Args)]
pub(crate) struct Arguments {
	/// The address and port it listens on, plain HTTP, TLS the tunnel's in front of it now.
	#[arg(long, value_name = "address:port", default_value_t = LISTEN)]
	listen: SocketAddr,
	/// containerd's socket.
	#[arg(long, value_name = "socket", default_value = "/run/containerd/containerd.sock")]
	containerd: PathBuf,
}

/// How long a deployment's address is given to accept a connection before it is taken as down.
const CONNECTING: Duration = Duration::from_secs(5);

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

/// A deployment as a host names it, an app of a binding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Named {
	pub(crate) binding: Binding,
	pub(crate) app: u32,
}

/// A decimal number written as a name writes it, digits alone with no zero leading but zero's own,
/// so one deployment has one name.
fn number<T: std::str::FromStr>(text: &str) -> Option<T> {
	let canonical = !text.is_empty()
		&& text.bytes().all(|b| b.is_ascii_digit())
		&& (text == "0" || !text.starts_with('0'));
	canonical.then(|| text.parse().ok()).flatten()
}

/// The deployment a host names by its leftmost two labels, `app-<id>.b<binding>`, its port and
/// the rest of it passed over, none where those two labels are not so.
pub(crate) fn named(host: &str) -> Option<Named> {
	// A name is its deployment's address with no table, provisional for RFC n0o4l.
	let host = host.split(':').next().unwrap_or_default();
	let mut labels = host.split('.');
	let app = labels.next()?;
	let binding = labels.next()?;
	let (prefix, app) = (app.get(..4)?, app.get(4..)?);
	let (letter, binding) = (binding.get(..1)?, binding.get(1..)?);
	if !prefix.eq_ignore_ascii_case("app-") || !letter.eq_ignore_ascii_case("b") {
		return None;
	}
	Some(Named { binding: number(binding)?, app: number(app)? })
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
}

/// What finds the deployment a name is bound to; implemented for [`Driver`].
pub(crate) trait Find: Send + Sync + 'static {
	/// The deployment, as it is now.
	fn find(&self, named: Named) -> impl Future<Output = Found> + Send;
}

/// What finds a deployment from containerd's labels, in its binding's namespace as the driver names
/// it, with no call to the driver.
struct Labels<C>(C);

impl<C: Containerd + 'static> Find for Labels<C> {
	/// Read at each request, as the container kind reads them at a start.
	async fn find(&self, named: Named) -> Found {
		let namespace = crate::listed::namespace(named.binding);
		let runs = DeploymentRuns::App { id: named.app };
		match self.0.list(&namespace).await {
			Ok(listed) => match driver_machine_container::reached(&listed, &runs) {
				Reached::Running(address) => address.parse().map_or(Found::Down, Found::Running),
				Reached::Down => Found::Down,
				Reached::Absent => Found::Absent,
			},
			Err(Fault(why)) => {
				eprintln!("entry {namespace}: {why}");
				Found::Down
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

/// The host a request was sent to, its target's authority or else its `Host`.
fn host(request: &Request) -> Option<String> {
	match request.uri().authority() {
		Some(authority) => Some(authority.as_str().to_owned()),
		None => request.headers().get(header::HOST)?.to_str().ok().map(str::to_owned),
	}
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
async fn entered<F: Find>(
	State(entry): State<Arc<Entry<F>>>,
	ConnectInfo(peer): ConnectInfo<SocketAddr>,
	request: Request,
) -> Response {
	// The challenge path of RFC vr5lw is not answered here yet, RFC n0o4l.
	let started = Instant::now();
	let host = host(&request);
	let named = host.as_deref().and_then(named);
	let (answer, name) = match (named, host) {
		(Some(named), Some(host)) => {
			let name = format!("app-{}.b{}", named.app, named.binding);
			let answer = match entry.find.find(named).await {
				Found::Running(address) => forwarded(&entry, address, peer, &host, request).await,
				Found::Down => own(StatusCode::SERVICE_UNAVAILABLE, "the deployment is not running\n"),
				Found::Absent => own(StatusCode::NOT_FOUND, "nothing is deployed by this name\n"),
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

/// The entry served on its listener until the process is stopped.
pub(crate) async fn serve<F: Find>(
	listener: tokio::net::TcpListener,
	find: Arc<F>,
) -> std::io::Result<()> {
	let mut connector = HttpConnector::new();
	connector.set_nodelay(true);
	connector.set_connect_timeout(Some(CONNECTING));
	let client = Client::builder(TokioExecutor::new()).build(connector);
	let router = Router::new().fallback(entered::<F>).with_state(Arc::new(Entry { find, client }));
	axum::serve(listener, router.into_make_service_with_connect_info::<SocketAddr>()).await
}

/// The entry served at its address until the process is stopped.
pub(crate) async fn run(arguments: Arguments) -> ExitCode {
	let listen = arguments.listen;
	let listener = match tokio::net::TcpListener::bind(listen).await {
		Ok(listener) => listener,
		Err(e) => {
			eprintln!("entry {listen}: {e}");
			return ExitCode::FAILURE;
		}
	};
	match listener.local_addr() {
		Ok(address) => eprintln!("entry on {address}"),
		Err(e) => eprintln!("entry on an address not read: {e}"),
	}
	let find = Arc::new(Labels(Socket { path: arguments.containerd }));
	match serve(listener, find).await {
		Ok(()) => ExitCode::SUCCESS,
		Err(e) => {
			eprintln!("entry: {e}");
			ExitCode::FAILURE
		}
	}
}

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

	use super::{Find, Found, Named, named, serve};

	/// Deployments found as the test says, none but those named.
	struct Stub(BTreeMap<Named, Found>);

	impl Find for Stub {
		async fn find(&self, named: Named) -> Found {
			self.0.get(&named).copied().unwrap_or(Found::Absent)
		}
	}

	const fn of(binding: u32, app: u32) -> Named {
		Named { binding, app }
	}

	#[test]
	fn a_host_names_its_deployment_by_its_leftmost_two_labels() {
		assert_eq!(named("app-1.b1.local"), Some(of(1, 1)));
		assert_eq!(named("app-1.b1"), Some(of(1, 1)));
		assert_eq!(named("APP-42.B7.example.com:8080"), Some(of(7, 42)));
		assert_eq!(named("app-0.b0.x"), Some(of(0, 0)));
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
			"www.app-1.b1.x",
			"app-1.b99999999999.x",
			"127.0.0.1:36879",
			"[::1]:36879",
		] {
			assert_eq!(named(bad), None, "{bad}");
		}
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
		tokio::spawn(serve(listener, Arc::new(Stub(found))));
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
}
