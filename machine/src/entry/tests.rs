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
	Find, Found, Gate, KEPT, Kind, Labels, Last, Named, Subnet, allowed, host, named, serve, subnet,
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

/// The containers' subnet every test but a container's own runs the entry with.
fn containers() -> Subnet {
	subnet("192.0.2.0/24").unwrap()
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
	Labels { containerd: Held(held), last: Last::default(), subnet: containers() }
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
	let host = |request| host(request, peer("127.0.0.1"), containers());
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
	tokio::spawn(serve(listener, Arc::new(Stub(found)), containers(), std::future::pending()));
	address
}

/// The entry started on loopback with loopback as the containers' subnet, so every request a
/// test sends is a container's, over the containers given.
async fn contained(listed: Vec<Listed>) -> SocketAddr {
	let (listener, address) = listening().await;
	let loopback = subnet("127.0.0.0/8").unwrap();
	let found = Labels { containerd: Held(Some(listed)), last: Last::default(), subnet: loopback };
	tokio::spawn(serve(listener, Arc::new(found), loopback, std::future::pending()));
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
	for (host, status) in
		[("localhost", 404), ("app-1.b1.local", 404), ("app-2.b1.local", 503), ("app-3.b1.local", 503)]
	{
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
	let serving = tokio::spawn(serve(listener, found, containers(), stopped));
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
	let stub = Arc::new(Stub(BTreeMap::new()));
	let serving = tokio::spawn(serve(listener, stub, containers(), stopped));
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

/// The entry's answer to a container asking for what its reaching does not hold.
const REFUSED: &str = "the deployment asking does not reach this one\n";

/// The entry over app 1 at 127.0.0.1 reaching app 2 alone, app 2 an upstream echoing on `::1`
/// and app 3 never dialed, so every request a test sends is app 1's by its address alone.
async fn reacher() -> SocketAddr {
	let listener = tokio::net::TcpListener::bind((std::net::Ipv6Addr::LOCALHOST, 0)).await.unwrap();
	let upstream = listener.local_addr().unwrap().to_string();
	tokio::spawn(async move { axum::serve(listener, Router::new().fallback(echoed)).await });
	contained(vec![
		container("app/2", &upstream, ""),
		container("app/3", "127.0.0.3:1", ""),
		container("app/1", "127.0.0.1:1", "app/2"),
	])
	.await
}

/// A request for `target` with its `Host` and an `X-Forwarded-Host` where one is given.
fn asked(target: &str, host: &str, forwarded: Option<&str>) -> String {
	let forwarded = forwarded.map(|f| format!("X-Forwarded-Host: {f}\r\n")).unwrap_or_default();
	format!("GET {target} HTTP/1.1\r\nHost: {host}\r\n{forwarded}Connection: close\r\n\r\n")
}

#[tokio::test]
async fn a_container_asking_by_host_for_what_it_does_not_reach_is_refused() {
	let (head, body) = sent(reacher().await, asked("/", "app-3.b1", None)).await;
	assert!(head.starts_with("HTTP/1.1 403 "), "{head}");
	assert_eq!(body, REFUSED);
}

#[tokio::test]
async fn a_container_is_answered_for_its_host_and_its_forwarded_host_is_ignored() {
	let (head, body) = sent(reacher().await, asked("/", "app-2.b1", Some("app-3.b1"))).await;
	assert!(head.starts_with("HTTP/1.1 201 "), "{head}");
	for line in ["host: app-2.b1", "x-forwarded-host: app-2.b1"] {
		assert!(body.lines().any(|l| l == line), "{line} not in {body}");
	}
}

#[tokio::test]
async fn a_container_cannot_forward_its_way_past_its_reaching() {
	let (head, body) = sent(reacher().await, asked("/", "app-3.b1", Some("app-2.b1"))).await;
	assert!(head.starts_with("HTTP/1.1 403 "), "{head}");
	assert_eq!(body, REFUSED);
}

#[tokio::test]
async fn a_container_cannot_name_past_its_host_by_an_absolute_target() {
	let (head, body) = sent(reacher().await, asked("http://app-2.b1/", "app-3.b1", None)).await;
	assert!(head.starts_with("HTTP/1.1 403 "), "{head}");
	assert_eq!(body, REFUSED);
}

#[tokio::test]
async fn a_proxy_on_loopback_is_still_named_by_its_forwarded_host() {
	let (listener, upstream) = listening().await;
	tokio::spawn(async move { axum::serve(listener, Router::new().fallback(echoed)).await });
	let at = entry(BTreeMap::from([(of(1, 1), Found::Running(upstream))])).await;
	let request = asked("/", "127.0.0.1:36879", Some("app-1.b1.example.com"));
	let (head, body) = sent(at, request).await;
	assert!(head.starts_with("HTTP/1.1 201 "), "{head}");
	let line = "x-forwarded-host: app-1.b1.example.com";
	assert!(body.lines().any(|l| l == line), "{line} not in {body}");
}

#[tokio::test]
async fn a_containers_own_forwarding_headers_never_reach_its_target() {
	let request = "GET / HTTP/1.1\r\nHost: app-2.b1\r\nX-Forwarded-For: 203.0.113.9\r\n\
		Forwarded: for=203.0.113.9\r\nX-Real-IP: 203.0.113.9\r\nX-Forwarded-Proto: https\r\n\
		X-Forwarded-Port: 443\r\nVia: 1.1 planted\r\nConnection: close\r\n\r\n";
	let (head, body) = sent(reacher().await, request.to_owned()).await;
	assert!(head.starts_with("HTTP/1.1 201 "), "{head}");
	for line in ["x-forwarded-for: 127.0.0.1", "x-forwarded-proto: http"] {
		assert!(body.lines().any(|l| l == line), "{line} not in {body}");
	}
	assert!(!body.contains("203.0.113.9"), "{body}");
	for name in ["forwarded:", "x-real-ip:", "x-forwarded-port:", "via:"] {
		assert!(!body.lines().any(|l| l.starts_with(name)), "{name} in {body}");
	}
}

#[tokio::test]
async fn a_containers_edge_and_client_headers_never_reach_its_target() {
	let request = "GET / HTTP/1.1\r\nHost: app-2.b1\r\nCF-Connecting-IPv6: 2001:db8::9\r\n\
		CF-Visitor: planted\r\nCF-Ray: planted\r\nCDN-Loop: planted\r\nTrue-Client-IP: planted\r\n\
		X-Forwarded: planted\r\nX-Original-Forwarded-For: planted\r\n\
		X-Cluster-Client-IP: planted\r\nClient-IP: planted\r\nFastly-Client-IP: planted\r\n\
		X_Forwarded_For: planted\r\nCf_Ray: planted\r\nX-Kept: kept\r\nConnection: close\r\n\r\n";
	let (head, body) = sent(reacher().await, request.to_owned()).await;
	assert!(head.starts_with("HTTP/1.1 201 "), "{head}");
	assert!(!body.contains("planted") && !body.contains("2001:db8"), "{body}");
	assert!(body.lines().any(|l| l == "x-kept: kept"), "{body}");
	assert!(body.lines().any(|l| l == "x-forwarded-for: 127.0.0.1"), "{body}");
}

#[test]
fn a_header_describing_forwarding_or_the_client_is_known_by_family_name_and_underscore() {
	for name in [
		"cf-connecting-ipv6",
		"cf-ipcountry",
		"cdn-loop",
		"true-client-ip",
		"x-forwarded",
		"x-forwarded-for",
		"x-original-forwarded-host",
		"x-cluster-client-ip",
		"client-ip",
		"fastly-client-ip",
		"x_forwarded_for",
		"CF_Visitor",
		"Via",
	] {
		assert!(super::proxied(name), "{name}");
	}
	for name in ["host", "x-kept", "cfx", "client-hints", "user-agent", "x-real"] {
		assert!(!super::proxied(name), "{name}");
	}
}

#[tokio::test]
async fn a_container_sending_two_hosts_is_answered_bad_request() {
	let request = "GET / HTTP/1.1\r\nHost: app-2.b1\r\nHost: app-3.b1\r\nConnection: close\r\n\r\n";
	let (head, body) = sent(reacher().await, request.to_owned()).await;
	assert!(head.starts_with("HTTP/1.1 400 "), "{head}");
	assert_eq!(body, "a request has one host\n");
}

#[tokio::test]
async fn a_proxys_chain_is_kept_and_extended() {
	let (listener, upstream) = listening().await;
	tokio::spawn(async move { axum::serve(listener, Router::new().fallback(echoed)).await });
	let at = entry(BTreeMap::from([(of(1, 1), Found::Running(upstream))])).await;
	let request = "GET / HTTP/1.1\r\nHost: app-1.b1\r\nX-Forwarded-For: 203.0.113.9\r\n\
		Forwarded: for=203.0.113.9\r\nX-Real-IP: 203.0.113.9\r\nConnection: close\r\n\r\n";
	let (head, body) = sent(at, request.to_owned()).await;
	assert!(head.starts_with("HTTP/1.1 201 "), "{head}");
	for line in [
		"x-forwarded-for: 203.0.113.9, 127.0.0.1",
		"forwarded: for=203.0.113.9",
		"x-real-ip: 203.0.113.9",
	] {
		assert!(body.lines().any(|l| l == line), "{line} not in {body}");
	}
}
