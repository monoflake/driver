//! The router, every call authenticated by its binding's token and answered in one envelope, and
//! one line to stderr for each, RFCs vr5lw, 3d3nt and ge55b.

use std::any::Any;
use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::{Arc, PoisonError, RwLock, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{HeaderMap, Method, StatusCode, Uri, header};
use axum::response::{IntoResponse, Response};
use driver_machine_container::{
	Bridge, Btrfs, Containers, Deployments, Https, Refused, Restart as _, Roots, Runtimes, STORE,
	Socket, Unmake as _,
};
use driver_machine_database::{Statements as _, Unexecuted};
use driver_machine_function::Functions;
use driver_machine_management::{Binding, Hold, Memory, Parse, Processor, Tokens, Unread};
use driver_machine_object::{MOST, Objects as _, Unwritten};
use driver_machine_volume::{Quotas as _, Volume, Volumes as _, qgroup};
use envelope::contracts::interface::{database, deployments, management, object};
use envelope::contracts::{
	DatabaseExecuted, DeploymentDeleted, DeploymentForm, DeploymentRuns, DeploymentRuntime, Error,
	Failure, ManagementHeld, ObjectDeleted, ObjectDescribed, ObjectListed,
};
use envelope::{Called, Encoded, Operation};

mod bucket;
mod fence;
mod forward;
mod slot;

use crate::answer::{self, Form, Forms};
use crate::{Arguments, Driver, Listed, Machine, Make, Manage, kept};

/// The most a call's body may be, axum's own default bound.
const LARGEST: usize = 2 * 1024 * 1024;

/// The most an `object` call's body may be, a content at its bound in base64url beside the rest.
const LARGEST_OBJECT: usize = MOST.div_ceil(3) * 4 + LARGEST;

/// The interfaces it serves, as a call names them.
const SERVED: &str = "management, deployments, object, database";

/// Whose a call is, the binding its token names on the listener or the one its socket is, with
/// the one interface that socket serves.
#[derive(Debug, Clone, Copy)]
enum Caller {
	Token,
	Slot(Binding, &'static str, Option<u32>),
}

/// How long a call of nix-store making a root is waited on, a deploy's or a start's, before it is
/// killed.
const ROOTED: Duration = Duration::from_secs(30);

/// How long a start reconciles the roots before it listens, what is left reconciled at the next.
const ROOTING: Duration = Duration::from_secs(60);

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

impl Make for Driver {
	fn free(&self) -> Result<u64, String> {
		self.volumes.free().map_err(|f| f.0)
	}

	fn volume(&self, under: &str, volume: Volume, size: u64) -> Result<PathBuf, String> {
		self.volumes.make(under, volume, size).map_err(|f| f.0)
	}

	fn unvolume(&self, under: &str, volume: Volume) -> Result<(), String> {
		self.volumes.remove(under, volume).map_err(|f| f.0)
	}

	fn emptied(&self, binding: &driver_machine_container::Binding, item: u32) -> Result<(), String> {
		let emptied = self.functions.containers.emptied(binding, item);
		match tokio::runtime::Handle::current().block_on(emptied) {
			Ok(removed) => {
				for id in removed {
					eprintln!("removed {} {id}", binding.namespace);
				}
				Ok(())
			}
			Err(e) => Err(format!("{} {}", e.reason, e.message.unwrap_or_default())),
		}
	}

	fn released(&self, binding: Binding) {
		let qgroup = qgroup(binding);
		if let Err(f) = self.volumes.destroy(&qgroup) {
			eprintln!("the qgroup {qgroup} stays, {}", f.0);
		}
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
	let mut lists = driver.lists.lock().await;
	// Every list is locked through btrfs and containerd and while its file is written, RFC 4elqc
	// item 7, on a thread that may block.
	let served = tokio::task::block_in_place(|| {
		let listed = lists.entry(binding).or_insert_with(|| Listed::new(binding));
		let make = &*driver;
		let before = kept::written(listed);
		let served = match call {
			management::Call::Apply(input) => {
				let result = listed.apply(&input, &driver.machine, make, now());
				if result.as_ref().is_ok_and(|held| held.generation == input.generation) {
					let mut tokens = driver.tokens.write().unwrap_or_else(PoisonError::into_inner);
					listed.forgotten.extend(tokens.apply(binding, input.tokens.as_deref()));
				}
				answered::<management::Apply>(result, form)
			}
			management::Call::SetPolicy(input) => {
				answered::<management::SetPolicy>(listed.set_policy(&input), form)
			}
			management::Call::Describe(_) => {
				answered::<management::Describe>(listed.describe(make, now()), form)
			}
			management::Call::End(input) => answered::<management::End>(listed.end(&input, make), form),
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
	});
	// The sockets follow the database and bucket whatever the call made or unmade of them.
	let listed = lists.get(&binding);
	let namespace = listed.map_or_else(|| crate::listed::namespace(binding), Listed::namespaced);
	slot::kept(&driver, binding, &namespace, listed.map(slot::held).unwrap_or_default());
	served
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

/// The deployment a binding's call names, by its id in 8 hex digits whatever its kind, RFC b8f35.
fn deployment(binding: Binding, runs: &DeploymentRuns) -> Deployment {
	match runs {
		DeploymentRuns::App { id } | DeploymentRuns::Component { id, .. } => {
			(binding, format!("{id:08x}"))
		}
	}
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
	let listed = driver.lists.lock().await.get(&binding).map(|l| (l.made.clone(), slot::held(l)));
	let (holding, held) = listed.unwrap_or_default();
	let slots = &driver.functions.slots;
	// A slot is held to what the binding holds before anything else of the deploy is asked.
	if let deployments::Call::Deploy(i) = &call
		&& let Err(refused) = slot::filled(i.bindings.as_ref(), held, i.form)
	{
		return answered::<deployments::Deploy>(Err(refused), form);
	}
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
			deployments::Call::Delete(i) => {
				bucket::deleted(slots, &crate::listed::namespace(binding), &i.runs);
				answered::<deployments::Delete>(Ok(DeploymentDeleted {}), form)
			}
		};
	};
	match call {
		deployments::Call::Deploy(i) => {
			let workerd = matches!(i.runtime, None | Some(DeploymentRuntime::Workerd));
			let filling = (i.runs.clone(), i.bindings.as_ref().and_then(|b| b.bucket.clone()));
			let deployed = match (i.form, workerd) {
				(DeploymentForm::Modules, true) => functions.deploy(&made, i).await,
				(DeploymentForm::Modules, false)
				| (DeploymentForm::Component | DeploymentForm::Image, _) => containers.deploy(&made, i).await,
			};
			// Each slot's socket is made once the deploy is answered, RFC ahcrp.
			if deployed.is_ok() {
				bucket::deployed(slots, &made.namespace, &filling.0, filling.1.as_ref());
			}
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
			let runs = i.runs.clone();
			let deleted = containers.delete(&made, i).await;
			if deleted.is_ok() {
				bucket::deleted(slots, &made.namespace, &runs);
			}
			answered::<deployments::Delete>(deleted, form)
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

/// A call's status is answered once the stores record calls, thread fifth's steps 3 and 4.
fn unrecorded<O: Operation>(form: Form) -> Served {
	let message = "a machine records no call's steps until thread fifth's steps 3 and 4";
	answered::<O>(Err(Refused { reason: "fault", message: Some(message.into()) }), form)
}

/// An object call on its binding's bucket, on a thread that may block, as SQLite and the file
/// system do.
async fn stored(driver: Arc<Driver>, binding: Binding, call: object::Call, form: Form) -> Served {
	let holding = driver.lists.lock().await.get(&binding).and_then(|l| l.bucket.clone());
	let holding = holding.map(|(_, bucket)| bucket);
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
			object::Call::Status(_) => unrecorded::<object::Status>(form),
		};
	};
	let ran = tokio::task::spawn_blocking(move || match call {
		object::Call::Write(i) => answered::<object::Write>(bucket.write(&i).map_err(unwritten), form),
		object::Call::Read(i) => answered::<object::Read>(bucket.read(&i).map_err(unread), form),
		object::Call::Describe(i) => {
			answered::<object::Describe>(bucket.describe(&i).map_err(faulted), form)
		}
		object::Call::Delete(i) => answered::<object::Delete>(bucket.delete(&i).map_err(faulted), form),
		object::Call::Status(_) => unrecorded::<object::Status>(form),
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

/// What a database refused a batch for, keeping its words as the message.
fn unexecuted(refusal: Unexecuted) -> Refused {
	let (reason, message) = match refusal {
		Unexecuted::Expired => return Refused { reason: "expired", message: None },
		Unexecuted::Malformed(words) => ("malformed", words),
		Unexecuted::Invalid(words) => ("invalid", words),
		Unexecuted::Constraint(words) => ("constraint", words),
		Unexecuted::BeyondLimit(words) => ("beyond_limit", words),
		Unexecuted::BeyondRange(words) => ("beyond_range", words),
		Unexecuted::StorageFull => return Refused { reason: "storage_full", message: None },
		Unexecuted::Overloaded(words) => ("overloaded", words),
		Unexecuted::Fault(f) => ("fault", f.0),
	};
	Refused { reason, message: Some(message) }
}

/// A database call on its binding's database, SQLite running on a thread that may block.
async fn queried(
	driver: Arc<Driver>,
	binding: Binding,
	item: Option<u32>,
	call: database::Call,
	form: Form,
) -> Served {
	let input = match call {
		database::Call::Execute(input) => input,
		database::Call::Status(input) => {
			let holding = driver
				.lists
				.lock()
				.await
				.get(&binding)
				.and_then(|l| item.and_then(|id| l.databases.get(&id)).cloned());
			let Some(database) = holding else {
				return answered::<database::Status>(
					Err(Refused { reason: "not_found", message: None }),
					form,
				);
			};
			let ran = tokio::task::spawn_blocking(move || {
				use driver_machine_database::DatabaseStatusAnswer;
				let answer =
					database.status(&input.id).map_err(unexecuted).and_then(|answer| match answer {
						DatabaseStatusAnswer::Found(steps) => Ok(steps),
						DatabaseStatusAnswer::NotFound => Err(Refused { reason: "not_found", message: None }),
						DatabaseStatusAnswer::Forgotten => Err(Refused { reason: "forgotten", message: None }),
					});
				answered::<database::Status>(answer, form)
			})
			.await;
			return match ran {
				Ok(served) => served,
				Err(e) if e.is_panic() => std::panic::resume_unwind(e.into_panic()),
				Err(e) => answered::<database::Status>(
					Err(Refused { reason: "fault", message: Some(e.to_string()) }),
					form,
				),
			};
		}
		database::Call::Rewind(_) => {
			return answered::<database::Rewind>(
				Err(Refused {
					reason: "fault",
					message: Some(
						"a machine serves execute alone until plan item machine-rewind-by-wal".into(),
					),
				}),
				form,
			);
		}
	};
	let holding = driver
		.lists
		.lock()
		.await
		.get(&binding)
		.and_then(|l| item.and_then(|id| l.databases.get(&id)).cloned());
	let Some(database) = holding else {
		return answered::<database::Execute>(
			Err(Refused {
				reason: "storage_full",
				message: Some("the binding holds no database".into()),
			}),
			form,
		);
	};
	let ran = tokio::task::spawn_blocking(move || {
		answered::<database::Execute>(database.execute(&input).map_err(unexecuted), form)
	})
	.await;
	match ran {
		Ok(served) => served,
		Err(e) if e.is_panic() => std::panic::resume_unwind(e.into_panic()),
		Err(e) => {
			Served::of::<DatabaseExecuted>(Err(answer::error(&[], "fault", Some(e.to_string()))), form)
		}
	}
}

/// A refusal before any operation is reached, a denial or a call not as its interface writes it.
fn early(forms: Forms, error: Error) -> Served {
	Served::of::<DeploymentDeleted>(Err(error), forms.answer)
}

/// A body refused before it is read, read and dropped up to a call's bound, so the connection is
/// closed with nothing left unread and its caller reads the refusal rather than a reset.
async fn drained(body: Body) {
	// A body past the bound is the caller's to have sent, and its connection may then be reset.
	let _ = axum::body::to_bytes(body, LARGEST).await;
}

/// One call, its binding the socket's or else authenticated first, so a call denied learns nothing
/// of what it named.
async fn serve(
	driver: Arc<Driver>,
	caller: Caller,
	method: Method,
	path: &str,
	headers: &HeaderMap,
	body: Body,
) -> Served {
	let forms = Forms::of(headers);
	let binding = match caller {
		Caller::Slot(binding, _, _) => binding,
		Caller::Token => {
			let authorization = headers.get(header::AUTHORIZATION).and_then(|v| v.to_str().ok());
			let checked =
				driver.tokens.read().unwrap_or_else(PoisonError::into_inner).check(authorization);
			let Ok(binding) = checked else {
				drained(body).await;
				return early(forms, answer::error(&[], "denied", None));
			};
			binding
		}
	};
	let (listened, interfaces) = match caller {
		Caller::Token => (true, SERVED),
		Caller::Slot(_, one, _) => (false, one),
	};
	let reached = |name: &str| listened || interfaces == name;
	let parts = path.strip_prefix('/').and_then(|p| p.split_once('/'));
	let (Some((interface, operation)), Method::POST) = (parts, method) else {
		drained(body).await;
		return early(forms, answer::malformed("a call is POST /{interface}/{operation}"));
	};
	let Some(form) = forms.body else {
		drained(body).await;
		return early(
			forms,
			answer::malformed("a call's body is application/json or application/cbor"),
		);
	};
	let largest = if interface == "object" && reached("object") { LARGEST_OBJECT } else { LARGEST };
	let Ok(bytes) = axum::body::to_bytes(body, largest).await else {
		let message = Some(format!("a call's body is at most {largest} bytes"));
		if interface == "database" && operation == "execute" {
			return early(forms, answer::error(database::Execute::REASONS, "beyond_limit", message));
		}
		return early(forms, answer::error(&[], "malformed", message));
	};
	let reply = forms.answer;
	match interface {
		"management" if listened => match read::<management::Call>(form, operation, &bytes) {
			Ok(call) => guarded(reply, managed(driver, binding, call, reply)).await,
			Err(e) => early(forms, e),
		},
		"deployments" if listened => match read::<deployments::Call>(form, operation, &bytes) {
			Ok(call) => guarded(reply, deployed(driver, binding, call, reply)).await,
			Err(e) => early(forms, e),
		},
		"object" if reached("object") => match read::<object::Call>(form, operation, &bytes) {
			Ok(call) => guarded(reply, stored(driver, binding, call, reply)).await,
			Err(e) => early(forms, e),
		},
		"database" if reached("database") => match read::<database::Call>(form, operation, &bytes) {
			Ok(call) => {
				let item = match caller {
					Caller::Slot(_, _, item) => item,
					Caller::Token => None,
				};
				guarded(reply, queried(driver, binding, item, call, reply)).await
			}
			Err(e) => early(forms, e),
		},
		other => early(forms, answer::malformed(format!("no interface {other}, one of {interfaces}"))),
	}
}

/// Every request on the listener, whatever its method and path, answered and logged.
async fn route(
	State(driver): State<Arc<Driver>>,
	method: Method,
	uri: Uri,
	headers: HeaderMap,
	body: Body,
) -> Response {
	routed(driver, Caller::Token, method, uri, headers, body).await
}

/// A request of either caller answered and logged.
async fn routed(
	driver: Arc<Driver>,
	caller: Caller,
	method: Method,
	uri: Uri,
	headers: HeaderMap,
	body: Body,
) -> Response {
	let started = Instant::now();
	let path = uri.path();
	let served = serve(driver, caller, method, path, &headers, body).await;
	let mut parts = path.trim_start_matches('/').splitn(2, '/');
	let interface = parts.next().filter(|n| !n.is_empty()).unwrap_or("-");
	let operation = parts.next().filter(|n| !n.is_empty()).unwrap_or("-");
	let took = started.elapsed().as_secs_f64() * 1000.0;
	eprintln!("{interface} {operation} {} {took:.1}ms", served.outcome);
	let headers =
		[(header::CONTENT_TYPE, served.form.media()), (header::SERVER, crate::health::SERVED_AS)];
	(served.status, headers, served.bytes).into_response()
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
	let volumes = Btrfs { mount: arguments.mount, binary: arguments.btrfs };
	let (lists, unread) = kept::read(&kept, &volumes.mount);
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
		volumes: volumes.clone(),
		functions: Functions {
			containers: Containers {
				containerd: Socket { path: arguments.containerd },
				network: Bridge {
					plugins: arguments.plugins,
					name: arguments.bridge,
					subnet: arguments.subnet,
					state: state.join("network"),
					entry: arguments.entry,
				},
				quota: volumes,
				fetch: Https { local: arguments.local, plain: arguments.plain },
				runtimes: Runtimes { runc: arguments.runc, crun: arguments.crun, youki: arguments.youki },
				roots: Roots {
					directory: arguments.roots,
					store: PathBuf::from(STORE),
					nix: arguments.nix_store,
					waited: ROOTED,
				},
				state: state.join("containers"),
				secrets: arguments.secrets,
				largest: arguments.largest,
			},
			workerd: arguments.workerd,
			slots: state.join("slots"),
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

/// Every container's runtime binary held by a root and every stale root removed, awaited for at
/// most [`ROOTING`] before the driver listens, so no deploy or removal of its own runs beside it.
async fn rooted(driver: &Driver) {
	let lists = driver.lists.lock().await;
	let namespaces: Vec<String> =
		lists.values().filter_map(|l| l.made.as_ref()).map(|b| b.namespace.clone()).collect();
	drop(lists);
	for line in driver.functions.containers.rooted(&namespaces, ROOTING).await {
		eprintln!("{line}");
	}
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
	rooted(&driver).await;
	let lists = driver.lists.lock().await;
	for (binding, listed) in lists.iter() {
		let namespace = listed.namespaced();
		slot::kept(&driver, *binding, &namespace, slot::held(listed));
		bucket::restored(&driver.functions.slots, &namespace);
	}
	drop(lists);
	tokio::spawn(restarted(Arc::clone(&driver)));
	tokio::spawn(fence::kept(Arc::clone(&driver)));
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
mod tests;
