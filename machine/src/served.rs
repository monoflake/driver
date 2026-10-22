//! The router, every call authenticated by its binding's token and answered in one envelope, and
//! one line to stderr for each, RFCs vr5lw, 3d3nt and ge55b.

use std::any::Any;
use std::collections::BTreeMap;
use std::process::ExitCode;
use std::sync::{Arc, PoisonError, RwLock};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{HeaderMap, Method, StatusCode, Uri, header};
use axum::response::{IntoResponse, Response};
use driver_machine_container::{
	Bridge, Btrfs, Containers, Deployments, Https, Refused, Runtimes, Socket,
};
use driver_machine_management::{Binding, Hold, Tokens, Unread};
use envelope::contracts::interface::{deployments, management};
use envelope::contracts::{DeploymentDeleted, Error, Failure};
use envelope::{Called, Encoded, Operation};

use crate::answer::{self, Form, Forms};
use crate::{Arguments, Driver, Listed, Manage};

/// The most a call's body may be, axum's own default bound.
const LARGEST: usize = 2 * 1024 * 1024;

/// The interfaces it serves, as a call names them.
const SERVED: &str = "management, deployments";

/// What a call was answered, its status, its bytes in their form, and how it ended for the log.
struct Served {
	status: StatusCode,
	bytes: Vec<u8>,
	form: Form,
	outcome: String,
}

impl Served {
	fn of<O: Encoded>(result: Result<O, Error>, form: Form) -> Self {
		let outcome = match &result {
			Ok(_) => "success".to_owned(),
			Err(e) => format!("error {} {}", named(e.failure), e.reason),
		};
		let (status, bytes) = answer::written(result, form);
		Self { status, bytes, form, outcome }
	}
}

/// A failure's name, as an answer writes it.
fn named(failure: Failure) -> &'static str {
	match failure {
		Failure::Rejected => "rejected",
		Failure::Unavailable => "unavailable",
		Failure::Unknown => "unknown",
	}
}

/// Every token file read again, each one not read said on stderr.
fn reload(driver: &Driver) {
	let unread = driver.tokens.write().unwrap_or_else(PoisonError::into_inner).reload(&driver.files);
	for file in unread {
		match file {
			Unread::Missing { file, error } => eprintln!("bindings {}: {error}", file.display()),
			Unread::Malformed { file, line, expected } => {
				eprintln!("bindings {}:{line}: expected {expected}", file.display());
			}
		}
	}
}

/// The time now in milliseconds since the epoch.
fn now() -> u64 {
	let elapsed = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
	u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX)
}

/// What a task panicked with, as text.
fn panicked(payload: &(dyn Any + Send)) -> String {
	payload
		.downcast_ref::<&str>()
		.map(|s| (*s).to_owned())
		.or_else(|| payload.downcast_ref::<String>().cloned())
		.unwrap_or_else(|| "the operation panicked".to_owned())
}

/// An operation run as a task of its own, so what it throws is answered `fault`, RFC ge55b.
async fn guarded<F>(form: Form, task: F) -> Served
where
	F: Future<Output = Served> + Send + 'static,
{
	match tokio::spawn(task).await {
		Ok(served) => served,
		Err(e) => {
			let message = if e.is_panic() { panicked(e.into_panic().as_ref()) } else { e.to_string() };
			Served::of::<DeploymentDeleted>(Err(answer::error(&[], "fault", Some(message))), form)
		}
	}
}

/// What an operation answers, its own reasons declared beside every operation's.
fn answered<P: Operation>(result: Result<P::Output, Refused>, form: Form) -> Served {
	Served::of(result.map_err(|r| answer::refused(P::REASONS, r)), form)
}

/// The call a body holds, its operation the one its path names.
fn read<C: Called>(form: Form, operation: &str, body: &[u8]) -> Result<C, Error> {
	let envelope = answer::call::<C>(form, body)?;
	if envelope.call.operation() == operation {
		Ok(envelope.call)
	} else {
		let named = envelope.call.operation();
		Err(answer::malformed(format!("the path names {operation} and the call {named}")))
	}
}

/// A management call on its binding's list.
async fn managed(
	driver: Arc<Driver>,
	binding: Binding,
	call: management::Call,
	form: Form,
) -> Served {
	let mut lists = driver.lists.lock().await;
	let listed = lists.entry(binding).or_insert_with(Listed::default);
	match call {
		management::Call::Apply(input) => {
			let result = listed.apply(&input, now());
			if result.as_ref().is_ok_and(|held| held.generation == input.generation) {
				let mut tokens = driver.tokens.write().unwrap_or_else(PoisonError::into_inner);
				tokens.apply(binding, input.tokens.as_deref());
			}
			answered::<management::Apply>(result, form)
		}
		management::Call::SetPolicy(input) => {
			answered::<management::SetPolicy>(listed.set_policy(&input), form)
		}
		management::Call::Describe(_) => answered::<management::Describe>(listed.describe(now()), form),
		management::Call::End(input) => answered::<management::End>(listed.end(&input), form),
	}
}

/// A deployments call through the container kind, within what the machine made of its binding.
async fn deployed(
	driver: Arc<Driver>,
	binding: Binding,
	call: deployments::Call,
	form: Form,
) -> Served {
	let holding = driver.lists.lock().await.get(&binding).and_then(|l| l.made.clone());
	let containers = &driver.containers;
	let Some(made) = holding else {
		// A binding the machine made nothing of holds no capacity and has deployed nothing.
		let none = || Refused { reason: "not_found", message: None };
		return match call {
			deployments::Call::Deploy(_) => answered::<deployments::Deploy>(
				Err(Refused {
					reason: "beyond_host",
					message: Some("the binding holds no capacity".into()),
				}),
				form,
			),
			deployments::Call::Stop(_) => answered::<deployments::Stop>(Err(none()), form),
			deployments::Call::Resume(_) => answered::<deployments::Resume>(Err(none()), form),
			deployments::Call::Describe(_) => answered::<deployments::Describe>(Err(none()), form),
			deployments::Call::Delete(_) => {
				answered::<deployments::Delete>(Ok(DeploymentDeleted {}), form)
			}
		};
	};
	match call {
		deployments::Call::Deploy(i) => {
			answered::<deployments::Deploy>(containers.deploy(&made, i).await, form)
		}
		deployments::Call::Stop(i) => {
			answered::<deployments::Stop>(containers.stop(&made, i).await, form)
		}
		deployments::Call::Resume(i) => {
			answered::<deployments::Resume>(containers.resume(&made, i).await, form)
		}
		deployments::Call::Describe(i) => {
			answered::<deployments::Describe>(containers.describe(&made, i).await, form)
		}
		deployments::Call::Delete(i) => {
			answered::<deployments::Delete>(containers.delete(&made, i).await, form)
		}
	}
}

/// A refusal before any operation is reached, a denial or a call not as its interface writes it.
fn early(forms: Forms, error: Error) -> Served {
	Served::of::<DeploymentDeleted>(Err(error), forms.answer)
}

/// One call, authenticated first, so a call denied learns nothing of what it named.
async fn serve(
	driver: Arc<Driver>,
	method: Method,
	path: &str,
	headers: &HeaderMap,
	body: Body,
) -> Served {
	let forms = Forms::of(headers);
	let authorization = headers.get(header::AUTHORIZATION).and_then(|v| v.to_str().ok());
	let checked = driver.tokens.read().unwrap_or_else(PoisonError::into_inner).check(authorization);
	let Ok(binding) = checked else {
		return early(forms, answer::error(&[], "denied", None));
	};
	let parts = path.strip_prefix('/').and_then(|p| p.split_once('/'));
	let (Some((interface, operation)), Method::POST) = (parts, method) else {
		return early(forms, answer::malformed("a call is POST /{interface}/{operation}"));
	};
	let Some(form) = forms.body else {
		return early(
			forms,
			answer::malformed("a call's body is application/json or application/cbor"),
		);
	};
	let Ok(bytes) = axum::body::to_bytes(body, LARGEST).await else {
		return early(forms, answer::malformed(format!("a call's body is at most {LARGEST} bytes")));
	};
	let reply = forms.answer;
	match interface {
		"management" => match read::<management::Call>(form, operation, &bytes) {
			Ok(call) => guarded(reply, managed(driver, binding, call, reply)).await,
			Err(e) => early(forms, e),
		},
		"deployments" => match read::<deployments::Call>(form, operation, &bytes) {
			Ok(call) => guarded(reply, deployed(driver, binding, call, reply)).await,
			Err(e) => early(forms, e),
		},
		other => early(forms, answer::malformed(format!("no interface {other}, one of {SERVED}"))),
	}
}

/// Every request, whatever its method and path, answered and logged.
async fn route(
	State(driver): State<Arc<Driver>>,
	method: Method,
	uri: Uri,
	headers: HeaderMap,
	body: Body,
) -> Response {
	let started = Instant::now();
	let path = uri.path();
	let served = serve(driver, method, path, &headers, body).await;
	let mut parts = path.trim_start_matches('/').splitn(2, '/');
	let interface = parts.next().filter(|n| !n.is_empty()).unwrap_or("-");
	let operation = parts.next().filter(|n| !n.is_empty()).unwrap_or("-");
	let took = started.elapsed().as_secs_f64() * 1000.0;
	eprintln!("{interface} {operation} {} {took:.1}ms", served.outcome);
	(served.status, [(header::CONTENT_TYPE, served.form.media())], served.bytes).into_response()
}

/// The driver made from its arguments, its tokens read once.
fn started(arguments: Arguments) -> Driver {
	let state = arguments.state;
	let driver = Driver {
		files: arguments.bindings,
		tokens: RwLock::new(Tokens::default()),
		lists: tokio::sync::Mutex::new(BTreeMap::new()),
		containers: Containers {
			containerd: Socket { path: arguments.containerd },
			network: Bridge {
				plugins: arguments.plugins,
				name: arguments.bridge,
				subnet: arguments.subnet,
				state: state.join("network"),
			},
			quota: Btrfs { mount: arguments.mount, binary: arguments.btrfs },
			fetch: Https { local: arguments.local },
			runtimes: Runtimes { runc: arguments.runc, crun: arguments.crun, youki: arguments.youki },
			state: state.join("containers"),
			secrets: arguments.secrets,
			largest: arguments.largest,
		},
	};
	reload(&driver);
	driver
}

/// The token files read again on each SIGHUP, RFC 3d3nt.
fn reloaded(driver: Arc<Driver>) -> std::io::Result<()> {
	let mut hangups = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup())?;
	tokio::spawn(async move {
		while hangups.recv().await.is_some() {
			reload(&driver);
		}
	});
	Ok(())
}

/// The driver served at its address until the process is stopped.
pub(crate) async fn run(arguments: Arguments) -> ExitCode {
	// A panic is answered as a fault, so its own report is one line beside the calls'.
	std::panic::set_hook(Box::new(|info| {
		let at = info.location().map(|l| format!(" at {}:{}", l.file(), l.line())).unwrap_or_default();
		eprintln!("panicked{at}: {}", info.payload_as_str().unwrap_or("a panic"));
	}));
	let listen = arguments.listen;
	let driver = Arc::new(started(arguments));
	if let Err(e) = reloaded(Arc::clone(&driver)) {
		eprintln!("SIGHUP: {e}");
		return ExitCode::FAILURE;
	}
	let listener = match tokio::net::TcpListener::bind(listen).await {
		Ok(listener) => listener,
		Err(e) => {
			eprintln!("listen {listen}: {e}");
			return ExitCode::FAILURE;
		}
	};
	match listener.local_addr() {
		Ok(address) => eprintln!("listening on {address}"),
		Err(e) => eprintln!("listening, at an address not read: {e}"),
	}
	let router = Router::new().fallback(route).with_state(driver);
	match axum::serve(listener, router).await {
		Ok(()) => ExitCode::SUCCESS,
		Err(e) => {
			eprintln!("serve: {e}");
			ExitCode::FAILURE
		}
	}
}
