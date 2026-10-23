//! The command `bind`, a host bound to its control once by its binding's token, and what the
//! control answers written under the driver's state for the machine's tunnel and address, RFC
//! rxmd9.

use std::fmt;
use std::fs::{self, DirBuilder, OpenOptions, Permissions};
use std::io::{ErrorKind, Read as _, Write as _};
use std::net::Ipv4Addr;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use envelope::contracts::interface::bindings;
use envelope::contracts::{BindingBind, BindingBound, Error};
use envelope::{Answer, Encoded as _, Envelope};
use reqwest::header::{ACCEPT, CONTENT_TYPE};
use serde_json::Value;

/// How long the control may take to be reached, and to answer whole.
const CONNECT: Duration = Duration::from_secs(10);
const WHOLE: Duration = Duration::from_secs(30);

/// The directory under the driver's state a bind writes, which the machine's module reads.
const BOUND: &str = "bound";
/// The binding's token, read by the driver as every token file is, RFC 3d3nt.
const BINDING: &str = "binding";
/// The tunnel's token, absent where the control makes the host no tunnel.
const TUNNEL: &str = "tunnel";
/// The host's private address, written last, as the machine takes a bind again when it changes.
const ADDRESS: &str = "address";

/// What a bind is given, the control, the token's file and where the answer is written.
#[derive(Debug, Clone, clap::Args)]
pub(crate) struct Arguments {
	/// The control's address, `https://` and its host, the call's path added to it.
	#[arg(value_name = "control")]
	control: String,
	/// A file holding the binding's token, `<id>.<secret>`, read from stdin without it.
	#[arg(long = "token-file", value_name = "file")]
	token_file: Option<PathBuf>,
	/// The driver's state, under which what the control answers is written, root's alone.
	#[arg(long, value_name = "directory", default_value = crate::STATE)]
	state: PathBuf,
	/// The control reached over plain HTTP, as one on this computer or a test's is.
	#[arg(long)]
	insecure: bool,
}

/// What `bindings.bind` answered as the host holds it, the tunnel's token as its text.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Bound {
	binding: u32,
	address: Ipv4Addr,
	tunnel: Option<String>,
}

/// Why a host was not bound.
#[derive(Debug)]
enum Unbound {
	/// The control's address is not HTTPS, nor HTTP where `--insecure` allows it.
	Address,
	/// The token not read, or not one line of a token's characters.
	Token(String),
	/// The control not reached, or its answer not read whole.
	Unreached(String),
	/// The control refused the call.
	Refused(Error),
	/// The answer not as the call's is written.
	Malformed(String),
	/// A file not written.
	Unwritten(PathBuf, std::io::Error),
}

impl fmt::Display for Unbound {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Address => write!(f, "the control's address is https://, or http:// with --insecure"),
			Self::Token(why) => write!(f, "the token {why}"),
			Self::Unreached(why) => write!(f, "the control was not reached, {why}"),
			Self::Refused(e) => write!(f, "the control refused it, {}: {}", e.reason, e.message),
			Self::Malformed(why) => write!(f, "the control's answer was not read, {why}"),
			Self::Unwritten(path, e) => write!(f, "{} not written, {e}", path.display()),
		}
	}
}

/// An error and every cause beneath it, as one line.
fn chained(error: &dyn std::error::Error) -> String {
	let mut text = error.to_string();
	let mut cause = error.source();
	while let Some(next) = cause {
		text.push_str(&format!(", {next}"));
		cause = next.source();
	}
	text
}

/// The call's address, the control's with the operation's path.
fn endpoint(control: &str, insecure: bool) -> Result<String, Unbound> {
	let allowed = control.starts_with("https://") || (insecure && control.starts_with("http://"));
	allowed
		.then(|| format!("{}/bindings/bind", control.trim_end_matches('/')))
		.ok_or(Unbound::Address)
}

/// One line of a token's characters, none empty.
fn line(text: &str) -> bool {
	!text.is_empty() && text.bytes().all(|b| b.is_ascii_graphic())
}

/// The token a file or stdin holds, one line and at most one newline after it.
fn token(file: Option<&Path>) -> Result<String, Unbound> {
	let read = match file {
		Some(path) => fs::read_to_string(path),
		None => {
			let mut text = String::new();
			std::io::stdin().read_to_string(&mut text).map(|_| text)
		}
	};
	let text = read.map_err(|e| Unbound::Token(format!("was not read, {e}")))?;
	let text = text.strip_suffix('\n').unwrap_or(&text);
	(line(text) && text.contains('.'))
		.then(|| text.to_owned())
		.ok_or_else(|| Unbound::Token("is not one line, `<id>.<secret>`".into()))
}

/// What a success holds as the host takes it, the binding the token's own, the address one a host
/// may hold as its own and the tunnel's token one line of UTF-8.
fn held(bound: BindingBound, token: &str) -> Option<Bound> {
	let ours = token.split_once('.').is_some_and(|(id, _)| id == bound.binding.to_string());
	let address: Ipv4Addr = bound.address.parse().ok()?;
	let own = !(address.is_loopback() || address.is_unspecified() || address.is_multicast());
	let tunnel = match bound.tunnel {
		Some(bytes) => Some(String::from_utf8(bytes).ok().filter(|t| line(t))?),
		None => None,
	};
	(ours && own).then_some(Bound { binding: bound.binding, address, tunnel })
}

/// What the control answered, its status said where the body is not an envelope.
fn answered(status: u16, bytes: &[u8], token: &str) -> Result<Bound, Unbound> {
	let malformed = |why: &str| Unbound::Malformed(format!("{why}, its status {status}"));
	let json: Value = serde_json::from_slice(bytes).map_err(|_| malformed("not JSON"))?;
	let answer = Answer::<BindingBound>::from_json(&json)
		.map_err(|m| malformed(&format!("expected {}", m.expected)))?;
	match answer {
		Answer::Success(bound) => held(bound, token)
			.ok_or_else(|| malformed("its binding not the token's, or its address or tunnel unusable")),
		Answer::Error(e) => Err(Unbound::Refused(e)),
	}
}

/// The call made once, the token presented as a bearer, RFC 3d3nt, and followed through no
/// redirect, so the token goes nowhere but where it was sent.
async fn called(endpoint: &str, token: &str, insecure: bool) -> Result<Bound, Unbound> {
	let unreached = |e: reqwest::Error| Unbound::Unreached(chained(&e));
	let client = reqwest::Client::builder()
		.https_only(!insecure)
		.redirect(reqwest::redirect::Policy::none())
		.connect_timeout(CONNECT)
		.timeout(WHOLE)
		.build()
		.map_err(unreached)?;
	let response = client
		.post(endpoint)
		.bearer_auth(token)
		.header(CONTENT_TYPE, "application/json")
		.header(ACCEPT, "application/json")
		.body(
			Envelope { call: bindings::Call::Bind(BindingBind {}), capabilities: Vec::new() }
				.to_json()
				.to_string(),
		)
		.send()
		.await
		.map_err(unreached)?;
	let status = response.status().as_u16();
	answered(status, &response.bytes().await.map_err(unreached)?, token)
}

/// A file replaced whole by a rename, owner-only from the moment it exists.
fn replaced(path: &Path, text: &str) -> std::io::Result<()> {
	let new = path.with_extension("new");
	removed(&new)?;
	let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&new)?;
	file.write_all(text.as_bytes())?;
	file.sync_all()?;
	fs::rename(&new, path)
}

/// A file removed, one absent no failure.
fn removed(path: &Path) -> std::io::Result<()> {
	match fs::remove_file(path) {
		Err(e) if e.kind() != ErrorKind::NotFound => Err(e),
		Ok(()) | Err(_) => Ok(()),
	}
}

/// What the control answered written under `directory`, each file with no newline, a tunnel's
/// token not answered removed, and the address last.
fn written(directory: &Path, token: &str, bound: &Bound) -> Result<(), Unbound> {
	let unwritten = |path: &Path| {
		let path = path.to_owned();
		move |e| Unbound::Unwritten(path, e)
	};
	DirBuilder::new().recursive(true).mode(0o700).create(directory).map_err(unwritten(directory))?;
	fs::set_permissions(directory, Permissions::from_mode(0o700)).map_err(unwritten(directory))?;
	let address = bound.address.to_string();
	for (name, text) in
		[(BINDING, Some(token)), (TUNNEL, bound.tunnel.as_deref()), (ADDRESS, Some(&address))]
	{
		let path = directory.join(name);
		match text {
			Some(text) => replaced(&path, text),
			None => removed(&path),
		}
		.map_err(unwritten(&path))?;
	}
	fs::File::open(directory).and_then(|d| d.sync_all()).map_err(unwritten(directory))
}

/// The host bound, what the control answered written under `state`.
async fn bound(arguments: &Arguments) -> Result<Bound, Unbound> {
	let endpoint = endpoint(&arguments.control, arguments.insecure)?;
	let token = token(arguments.token_file.as_deref())?;
	let bound = called(&endpoint, &token, arguments.insecure).await?;
	written(&arguments.state.join(BOUND), &token, &bound)?;
	Ok(bound)
}

/// The host bound once, what was written said on stdout and a failure on stderr.
pub(crate) async fn run(arguments: Arguments) -> ExitCode {
	match bound(&arguments).await {
		Ok(bound) => {
			let directory = arguments.state.join(BOUND);
			let tunnel = if bound.tunnel.is_some() { "a tunnel" } else { "no tunnel" };
			let (binding, address, directory) = (bound.binding, bound.address, directory.display());
			println!(
				"bound binding {binding}, its private address {address} and {tunnel}, in {directory}"
			);
			ExitCode::SUCCESS
		}
		Err(e) => {
			eprintln!("bind: {e}");
			ExitCode::FAILURE
		}
	}
}

#[cfg(test)]
mod tests {
	use std::os::unix::fs::PermissionsExt as _;
	use std::path::{Path, PathBuf};
	use std::sync::Arc;
	use std::sync::atomic::{AtomicUsize, Ordering};

	use axum::Router;
	use axum::http::{HeaderMap, StatusCode, header};
	use driver_machine_management::{Hold as _, Tokens};
	use envelope::contracts::BindingBound;
	use envelope::{Answer, Encoded as _};
	use serde_json::{Value, json};

	use super::{ADDRESS, Arguments, BINDING, BOUND, TUNNEL, Unbound, bound};

	/// A control that answers each bind with `answer` and counts the calls it was given.
	struct Control {
		address: String,
		calls: Arc<AtomicUsize>,
	}

	/// A binding's token, its secret 32 bytes of zero but the character `filled` says.
	fn token(binding: u32, filled: char) -> String {
		format!("{binding}.{}A", filled.to_string().repeat(42))
	}

	/// A control on a port of its own, which takes `expected` alone as a bearer.
	async fn control(expected: String, status: StatusCode, answer: Value) -> Control {
		let calls = Arc::new(AtomicUsize::new(0));
		let counted = Arc::clone(&calls);
		let handler = move |headers: HeaderMap, body: String| async move {
			counted.fetch_add(1, Ordering::SeqCst);
			let given = headers.get(header::AUTHORIZATION).and_then(|v| v.to_str().ok());
			let call: Value = serde_json::from_str(&body).unwrap();
			assert_eq!(call["interface"], "bindings");
			assert_eq!(call["operation"], "bind");
			assert_eq!(call["input"], json!({}));
			if given != Some(format!("Bearer {expected}").as_str()) {
				let denied = json!({"status": "error", "failure": "rejected", "reason": "denied",
					"message": "the token is not one this control made"});
				return (StatusCode::FORBIDDEN, denied.to_string());
			}
			(status, answer.to_string())
		};
		let router = Router::new().route("/bindings/bind", axum::routing::post(handler));
		let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
		let address = format!("http://{}", listener.local_addr().unwrap());
		tokio::spawn(async move { axum::serve(listener, router).await });
		Control { address, calls }
	}

	/// A directory of its own for one test, the token written in it.
	fn directory(name: &str, token: &str) -> PathBuf {
		let path = std::env::temp_dir().join(format!("bind-{name}-{}", std::process::id()));
		let _ = std::fs::remove_dir_all(&path);
		std::fs::create_dir_all(&path).unwrap();
		std::fs::write(path.join("token"), format!("{token}\n")).unwrap();
		path
	}

	fn arguments(control: &Control, directory: &Path) -> Arguments {
		Arguments {
			control: control.address.clone(),
			token_file: Some(directory.join("token")),
			state: directory.join("state"),
			insecure: true,
		}
	}

	/// A success as the control writes it, the tunnel's token its text's UTF-8.
	fn success(binding: u32, address: &str, tunnel: Option<&[u8]>) -> Value {
		let bound =
			BindingBound { binding, address: address.to_owned(), tunnel: tunnel.map(<[u8]>::to_vec) };
		Answer::Success(bound).to_json()
	}

	fn mode(path: &Path) -> u32 {
		std::fs::metadata(path).unwrap().permissions().mode() & 0o777
	}

	#[tokio::test]
	async fn a_good_token_is_bound_its_files_the_owners_alone_and_its_token_one_the_driver_takes() {
		let token = token(1, 'A');
		let directory = directory("good", &token);
		let control =
			control(token.clone(), StatusCode::OK, success(1, "10.200.0.7", Some(b"tunnel-1"))).await;
		let bound = bound(&arguments(&control, &directory)).await.unwrap();
		assert_eq!(bound.address.to_string(), "10.200.0.7");
		let written = directory.join("state").join(BOUND);
		assert_eq!(mode(&written), 0o700);
		for (name, text) in [(BINDING, token.as_str()), (ADDRESS, "10.200.0.7"), (TUNNEL, "tunnel-1")] {
			assert_eq!(std::fs::read_to_string(written.join(name)).unwrap(), text);
			assert_eq!(mode(&written.join(name)), 0o600, "{name} is not the owner's alone");
		}
		assert_eq!(std::fs::read_dir(&written).unwrap().count(), 3, "a file beside the three");
		// The binding's file is read as the driver reads its token files, and the token accepted.
		let mut tokens = Tokens::default();
		assert!(tokens.reload(&[written.join(BINDING)]).is_empty());
		assert_eq!(tokens.check(Some(&format!("Bearer {token}"))), Ok(1));
		assert_eq!(control.calls.load(Ordering::SeqCst), 1);
	}

	#[tokio::test]
	async fn a_refused_token_writes_nothing() {
		let directory = directory("refused", &token(1, 'Q'));
		let made = token(1, 'A');
		let control = control(made, StatusCode::OK, success(1, "10.200.0.7", Some(b"tunnel-1"))).await;
		let refused = bound(&arguments(&control, &directory)).await.unwrap_err();
		assert!(matches!(&refused, Unbound::Refused(e) if e.reason == "denied"), "{refused}");
		assert!(!directory.join("state").exists());
	}

	#[tokio::test]
	async fn a_second_bind_replaces_the_first() {
		let token = token(1, 'A');
		let directory = directory("second", &token);
		let first =
			control(token.clone(), StatusCode::OK, success(1, "10.200.0.7", Some(b"tunnel-1"))).await;
		bound(&arguments(&first, &directory)).await.unwrap();
		let second =
			control(token.clone(), StatusCode::OK, success(1, "10.200.0.8", Some(b"tunnel-2"))).await;
		bound(&arguments(&second, &directory)).await.unwrap();
		let written = directory.join("state").join(BOUND);
		assert_eq!(std::fs::read_to_string(written.join(TUNNEL)).unwrap(), "tunnel-2");
		assert_eq!(std::fs::read_to_string(written.join(ADDRESS)).unwrap(), "10.200.0.8");
		assert_eq!(mode(&written.join(TUNNEL)), 0o600);
		assert_eq!(std::fs::read_dir(&written).unwrap().count(), 3, "a file beside the three");
	}

	#[tokio::test]
	async fn a_bind_answered_no_tunnel_writes_no_tunnel_s_file() {
		let token = token(1, 'A');
		let directory = directory("tunnelless", &token);
		let control = control(token.clone(), StatusCode::OK, success(1, "10.200.0.1", None)).await;
		bound(&arguments(&control, &directory)).await.unwrap();
		let written = directory.join("state").join(BOUND);
		let mut names: Vec<_> =
			std::fs::read_dir(&written).unwrap().map(|e| e.unwrap().file_name()).collect();
		names.sort();
		assert_eq!(names, [ADDRESS, BINDING]);
	}

	#[tokio::test]
	async fn a_bind_answered_no_tunnel_removes_the_one_before_and_writes_the_rest() {
		let token = token(1, 'A');
		let directory = directory("untunneled", &token);
		let first = control(token.clone(), StatusCode::OK, success(1, "10.200.0.1", Some(b"t"))).await;
		bound(&arguments(&first, &directory)).await.unwrap();
		let second = control(token.clone(), StatusCode::OK, success(1, "10.200.0.1", None)).await;
		assert_eq!(bound(&arguments(&second, &directory)).await.unwrap().tunnel, None);
		let written = directory.join("state").join(BOUND);
		assert!(!written.join(TUNNEL).exists(), "the tunnel's token before was kept");
		assert_eq!(std::fs::read_to_string(written.join(ADDRESS)).unwrap(), "10.200.0.1");
		assert_eq!(std::fs::read_to_string(written.join(BINDING)).unwrap(), token);
	}

	#[tokio::test]
	async fn an_unavailable_control_is_refused_as_it_answered() {
		let token = token(1, 'A');
		let directory = directory("unavailable", &token);
		let unreachable = json!({"status": "error", "failure": "unavailable",
			"reason": "unreachable", "message": "the tunnel could not be made"});
		let control = control(token, StatusCode::SERVICE_UNAVAILABLE, unreachable).await;
		let refused = bound(&arguments(&control, &directory)).await.unwrap_err();
		assert!(matches!(&refused, Unbound::Refused(e) if e.reason == "unreachable"), "{refused}");
		// Told once and tried no more, the operator's to run again.
		assert_eq!(control.calls.load(Ordering::SeqCst), 1);
		assert!(refused.to_string().contains("unreachable"), "{refused}");
		assert!(!directory.join("state").exists());
	}

	#[tokio::test]
	async fn an_answer_not_as_written_writes_nothing() {
		let token = token(1, 'A');
		let directory = directory("malformed", &token);
		for answer in [
			success(1, "127.0.0.1", Some(b"tunnel-1")),
			success(1, "10.200.0.7", Some(b"two\nlines")),
			success(1, "10.200.0.7", Some(&[0xff, 0xfe])),
			success(2, "10.200.0.7", Some(b"tunnel-1")),
			success(1, "fd00::1", None),
			json!({"status": "success", "data": {"binding": 1, "tunnel": "dHVubmVs"}}),
			json!({"status": "success", "data": {"binding": 1, "address": "10.200.0.1", "tunnel": "!!"}}),
			json!({"bound": true}),
		] {
			let control = control(token.clone(), StatusCode::OK, answer).await;
			let refused = bound(&arguments(&control, &directory)).await.unwrap_err();
			assert!(matches!(refused, Unbound::Malformed(_)), "{refused}");
		}
		assert!(!directory.join("state").exists());
	}

	#[tokio::test]
	async fn plain_http_is_refused_before_any_call_unless_insecure() {
		let token = token(1, 'A');
		let directory = directory("plain", &token);
		let control = control(token, StatusCode::OK, success(1, "10.200.0.7", Some(b"tunnel-1"))).await;
		let plain = Arguments { insecure: false, ..arguments(&control, &directory) };
		assert!(matches!(bound(&plain).await, Err(Unbound::Address)));
		assert_eq!(control.calls.load(Ordering::SeqCst), 0);
		assert!(!directory.join("state").exists());
	}
}
