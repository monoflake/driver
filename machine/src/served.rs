//! The router, every call authenticated by its binding's token and answered in one envelope, and
//! one line to stderr for each, RFCs vr5lw, 3d3nt and ge55b.

use std::any::Any;
use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::Path;
use std::process::ExitCode;
use std::sync::{Arc, PoisonError, RwLock, Weak};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{HeaderMap, Method, StatusCode, Uri, header};
use axum::response::{IntoResponse, Response};
use driver_machine_container::{
	Bridge, Btrfs, Containers, Deployments, Https, Refused, Restart as _, Runtimes, Socket,
};
use driver_machine_function::Functions;
use driver_machine_management::{Binding, Hold, Memory, Parse, Processor, Tokens, Unread};
use driver_machine_object::{MOST, Objects as _, Unwritten};
use envelope::contracts::interface::{deployments, management, object};
use envelope::contracts::{
	DeploymentDeleted, DeploymentForm, DeploymentRuns, DeploymentRuntime, Error, Failure,
	ManagementHeld, ObjectDeleted, ObjectDescribed, ObjectListed,
};
use envelope::{Called, Encoded, Operation};

use crate::answer::{self, Form, Forms};
use crate::{Arguments, Driver, Listed, Machine, Manage, kept};

/// The most a call's body may be, axum's own default bound.
const LARGEST: usize = 2 * 1024 * 1024;

/// The most an `object` call's body may be, a content at its bound in base64url beside the rest.
const LARGEST_OBJECT: usize = MOST.div_ceil(3) * 4 + LARGEST;

/// The interfaces it serves, as a call names them.
const SERVED: &str = "management, deployments, object";

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

/// A management call on its binding's list, the list kept again wherever the call changed it, and
/// a list that could not be kept answered `fault`.
async fn managed(
	driver: Arc<Driver>,
	binding: Binding,
	call: management::Call,
	form: Form,
) -> Served {
	// Every list is locked while its file is written, as through btrfs calls, RFC 4elqc item 7.
	let mut lists = driver.lists.lock().await;
	let listed = lists.entry(binding).or_insert_with(|| Listed::new(binding));
	let before = kept::written(listed);
	let served = match call {
		management::Call::Apply(input) => {
			let result = listed.apply(&input, &driver.machine, now());
			if result.as_ref().is_ok_and(|held| held.generation == input.generation) {
				let mut tokens = driver.tokens.write().unwrap_or_else(PoisonError::into_inner);
				listed.forgotten.extend(tokens.apply(binding, input.tokens.as_deref()));
			}
			answered::<management::Apply>(result, form)
		}
		management::Call::SetPolicy(input) => {
			answered::<management::SetPolicy>(listed.set_policy(&input), form)
		}
		management::Call::Describe(_) => answered::<management::Describe>(listed.describe(now()), form),
		management::Call::End(input) => answered::<management::End>(listed.end(&input), form),
	};
	if kept::written(listed) == before {
		return served;
	}
	match kept::write(&driver.kept, listed) {
		Ok(()) => served,
		Err(why) => {
			let message = Some(format!("the list could not be kept, {why}"));
			Served::of::<ManagementHeld>(Err(answer::error(&[], "fault", message)), form)
		}
	}
}

/// One deployment of a binding, by what it runs as a label writes it.
type Deployment = (Binding, String);

/// Each deployment's turn, so calls changing one deployment run one after another however long a
/// fetch takes, while no lock of every binding's is held through it.
struct Turns(std::sync::Mutex<BTreeMap<Deployment, Weak<tokio::sync::Mutex<()>>>>);

/// The turns of this process's one driver.
static TURNS: Turns = Turns(std::sync::Mutex::new(BTreeMap::new()));

impl Turns {
	/// The deployment's turn, awaited until every call taking it before is answered.
	async fn taken(&self, deployment: Deployment) -> tokio::sync::OwnedMutexGuard<()> {
		let turn = {
			let mut turns = self.0.lock().unwrap_or_else(PoisonError::into_inner);
			// A turn nobody holds or awaits is gone, so the map holds only those in use.
			turns.retain(|_, turn| turn.strong_count() > 0);
			match turns.get(&deployment).and_then(Weak::upgrade) {
				Some(turn) => turn,
				None => {
					let turn = Arc::new(tokio::sync::Mutex::new(()));
					turns.insert(deployment, Arc::downgrade(&turn));
					turn
				}
			}
		};
		turn.lock_owned().await
	}
}

/// The deployment a binding's call names.
fn deployment(binding: Binding, runs: &DeploymentRuns) -> Deployment {
	let runs = match runs {
		DeploymentRuns::App { id } => format!("app/{id}"),
		DeploymentRuns::Component { component } => format!("component/{component}"),
	};
	(binding, runs)
}

/// A deployments call within what the machine made of its binding, modules for workerd deployed by
/// the function kind and the rest by the container kind, which holds every form's containers.
async fn deployed(
	driver: Arc<Driver>,
	binding: Binding,
	call: deployments::Call,
	form: Form,
) -> Served {
	let changes = match &call {
		deployments::Call::Deploy(i) => Some(&i.runs),
		deployments::Call::Stop(i) | deployments::Call::Resume(i) | deployments::Call::Delete(i) => {
			Some(&i.runs)
		}
		deployments::Call::Describe(_) => None,
	};
	// A describe answers at once, and every other call waits on its deployment's turn.
	let _turn = match changes {
		Some(runs) => Some(TURNS.taken(deployment(binding, runs)).await),
		None => None,
	};
	let holding = driver.lists.lock().await.get(&binding).and_then(|l| l.made.clone());
	let functions = &driver.functions;
	let containers = &functions.containers;
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
			let workerd = matches!(i.runtime, None | Some(DeploymentRuntime::Workerd));
			let deployed = match (i.form, workerd) {
				(DeploymentForm::Modules, true) => functions.deploy(&made, i).await,
				(DeploymentForm::Modules, false)
				| (DeploymentForm::Component | DeploymentForm::Image, _) => containers.deploy(&made, i).await,
			};
			answered::<deployments::Deploy>(deployed, form)
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

/// What a bucket refused a write for, as `write` answers it.
fn unwritten(refusal: Unwritten) -> Refused {
	match refusal {
		Unwritten::TooLarge => Refused { reason: "too_large", message: None },
		Unwritten::StorageFull => Refused { reason: "storage_full", message: None },
		Unwritten::Fault(f) => faulted(f),
	}
}

/// What a bucket refused a read for, as `read` answers it.
fn unread(refusal: driver_machine_object::Unread) -> Refused {
	match refusal {
		driver_machine_object::Unread::NotFound => Refused { reason: "not_found", message: None },
		driver_machine_object::Unread::Fault(f) => faulted(f),
	}
}

/// What a bucket could not do, answered `fault`.
fn faulted(fault: driver_machine_object::Fault) -> Refused {
	Refused { reason: "fault", message: Some(fault.0) }
}

/// An object call on its binding's bucket, on a thread that may block, as SQLite and the file
/// system do.
async fn stored(driver: Arc<Driver>, binding: Binding, call: object::Call, form: Form) -> Served {
	let holding = driver.lists.lock().await.get(&binding).and_then(|l| l.bucket.clone());
	let Some(bucket) = holding else {
		// A binding the machine made no bucket of holds no object and has room for none.
		return match call {
			object::Call::Write(_) => answered::<object::Write>(
				Err(Refused {
					reason: "storage_full",
					message: Some("the binding holds no bucket".into()),
				}),
				form,
			),
			object::Call::Read(_) => {
				answered::<object::Read>(Err(Refused { reason: "not_found", message: None }), form)
			}
			object::Call::Describe(_) => {
				answered::<object::Describe>(Ok(ObjectDescribed { size: None }), form)
			}
			object::Call::Delete(_) => answered::<object::Delete>(Ok(ObjectDeleted {}), form),
			object::Call::List(_) => {
				answered::<object::List>(Ok(ObjectListed { objects: Vec::new(), next: None }), form)
			}
		};
	};
	let ran = tokio::task::spawn_blocking(move || match call {
		object::Call::Write(i) => answered::<object::Write>(bucket.write(&i).map_err(unwritten), form),
		object::Call::Read(i) => answered::<object::Read>(bucket.read(&i).map_err(unread), form),
		object::Call::Describe(i) => {
			answered::<object::Describe>(bucket.describe(&i).map_err(faulted), form)
		}
		object::Call::Delete(i) => answered::<object::Delete>(bucket.delete(&i).map_err(faulted), form),
		object::Call::List(i) => answered::<object::List>(bucket.list(&i).map_err(faulted), form),
	})
	.await;
	match ran {
		Ok(served) => served,
		// Thrown on, so `guarded` answers it as it answers any operation's panic.
		Err(e) if e.is_panic() => std::panic::resume_unwind(e.into_panic()),
		Err(e) => {
			Served::of::<ObjectDeleted>(Err(answer::error(&[], "fault", Some(e.to_string()))), form)
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
	let largest = if interface == "object" { LARGEST_OBJECT } else { LARGEST };
	let Ok(bytes) = axum::body::to_bytes(body, largest).await else {
		return early(forms, answer::malformed(format!("a call's body is at most {largest} bytes")));
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
		"object" => match read::<object::Call>(form, operation, &bytes) {
			Ok(call) => guarded(reply, stored(driver, binding, call, reply)).await,
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

/// The machine's cores and memory as the kernel writes them, none where they are not read, so no
/// list asking any fits; a `container` item's address is the one the driver listens at, RFC 4elqc.
fn machine(listen: SocketAddr) -> Machine {
	let read = |file: &str| std::fs::read_to_string(Path::new("/").join(file)).ok();
	let cores = read(Processor::FILE).and_then(|t| Processor::parse(&t).ok()).map(|p| p.cores.len());
	let millicores = cores.and_then(|n| u64::try_from(n).ok()).map_or(0, |n| n.saturating_mul(1000));
	let memory = read(Memory::FILE).and_then(|t| Memory::parse(&t).ok()).map_or(0, |m| m.total);
	if millicores == 0 || memory == 0 {
		eprintln!("the machine's cores and memory were not read, so no container item fits");
	}
	Machine { millicores, memory, address: listen.to_string() }
}

/// The driver made from its arguments, each binding's kept list read and its forgotten tokens
/// forgotten again before the token files are read once.
fn started(arguments: Arguments) -> Driver {
	let state = arguments.state;
	let kept = state.join("lists");
	let (lists, unread) = kept::read(&kept);
	for why in unread {
		eprintln!("lists {why}");
	}
	let mut tokens = Tokens::default();
	for listed in lists.values() {
		tokens.forget(&listed.forgotten.iter().copied().collect::<Vec<_>>());
	}
	let driver = Driver {
		files: arguments.bindings,
		tokens: RwLock::new(tokens),
		machine: machine(arguments.listen),
		lists: tokio::sync::Mutex::new(lists),
		kept,
		functions: Functions {
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
			workerd: arguments.workerd,
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

/// Every container a reboot ended started again, each found from containerd's labels rather than
/// kept here, as the container kind writes there all it keeps of a deployment.
async fn restarted(driver: Arc<Driver>) {
	let made: Vec<_> = driver.lists.lock().await.values().filter_map(|l| l.made.clone()).collect();
	for binding in made {
		match driver.functions.containers.restarted(&binding).await {
			Ok(started) => {
				for id in started {
					eprintln!("restarted {} {id}", binding.namespace);
				}
			}
			Err(e) => {
				let message = e.message.unwrap_or_default();
				eprintln!("restart {}: {} {message}", binding.namespace, e.reason);
			}
		}
	}
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
	tokio::spawn(restarted(Arc::clone(&driver)));
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

#[cfg(test)]
mod tests {
	use std::pin::pin;
	use std::task::{Context, Poll, Waker};

	use envelope::contracts::interface::deployments;
	use envelope::contracts::{DeploymentOf, DeploymentRuns};

	use super::{TURNS, deployed, deployment, started};
	use crate::Arguments;
	use crate::answer::Form;

	/// A driver of nothing, reaching no containerd.
	fn driver() -> super::Driver {
		let nowhere = std::path::PathBuf::from("/nonexistent");
		started(Arguments {
			listen: crate::LISTEN,
			bindings: Vec::new(),
			state: nowhere.clone(),
			containerd: nowhere.clone(),
			runc: nowhere.clone(),
			crun: nowhere.clone(),
			youki: nowhere.clone(),
			plugins: nowhere.clone(),
			bridge: "bridge".into(),
			subnet: "10.88.0.0/16".into(),
			mount: nowhere.clone(),
			btrfs: nowhere.clone(),
			local: None,
			secrets: nowhere.clone(),
			largest: 1,
			workerd: nowhere,
		})
	}

	#[tokio::test]
	async fn a_call_on_a_deployment_waits_for_the_one_before_on_it_to_be_answered() {
		let driver = std::sync::Arc::new(driver());
		let runs = DeploymentRuns::App { id: 7 };
		let held = TURNS.taken(deployment(7, &runs)).await;
		let stop = deployments::Call::Stop(DeploymentOf { runs: runs.clone() });
		let mut waiting = pin!(deployed(driver.clone(), 7, stop, Form::Json));
		let mut context = Context::from_waker(Waker::noop());
		assert!(waiting.as_mut().poll(&mut context).is_pending(), "it ran while the turn was held");
		// Another deployment of the binding, or the same of another binding, is not held back.
		let other = deployments::Call::Stop(DeploymentOf { runs: DeploymentRuns::App { id: 8 } });
		let apart = pin!(deployed(driver.clone(), 7, other, Form::Json)).poll(&mut context);
		assert!(matches!(apart, Poll::Ready(_)));
		let elsewhere = deployments::Call::Stop(DeploymentOf { runs });
		let apart = pin!(deployed(driver.clone(), 9, elsewhere, Form::Json)).poll(&mut context);
		assert!(matches!(apart, Poll::Ready(_)));
		drop(held);
		assert_eq!(waiting.await.outcome, "error rejected not_found");
	}
}
