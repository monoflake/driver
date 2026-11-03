//! workerd's configuration for a deploy filling an `object_bucket` slot and for the storage
//! component, RFC ahcrp, and the module a bucket's binding is made by, run by node.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::collections::BTreeMap;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use common::{binding, declaring, functions, hash, unquoted};
use driver_machine_container::{Deployments, Sockets};
use driver_machine_function::{Bound, Bundle, Configure, SOCKET, Unpack, Worker};
use envelope::contracts::{
	AppBindings, DeploymentArtifact, DeploymentDeploy, DeploymentForm, DeploymentIsolation,
	DeploymentNetwork, DeploymentRuns,
};

/// A bundle declaring an `object_bucket` slot `images` and a database slot `records`.
fn slotted() -> Vec<u8> {
	declaring(
		r#"[{ "name": "images", "type": "object_bucket" }, { "name": "records", "type": "database" }]"#,
	)
}

/// A bundle declaring no slot, as the storage product's own may.
fn plain() -> Vec<u8> {
	declaring("[]")
}

fn served() -> BTreeMap<String, Vec<u8>> {
	BTreeMap::from([("slotted".to_owned(), slotted()), ("plain".to_owned(), plain())])
}

/// A deploy of the bundle at `address`, run as `runs`, its bindings as given.
fn deploying(
	address: &str,
	runs: DeploymentRuns,
	bindings: Option<AppBindings>,
) -> DeploymentDeploy {
	let built = hash(&served()[address]);
	DeploymentDeploy {
		runs,
		version: built,
		form: DeploymentForm::Modules,
		runtime: None,
		isolation: vec![DeploymentIsolation::Isolate],
		artifact: DeploymentArtifact { address: address.into(), hash: built, architecture: None },
		footing: "https://footing.invalid".into(),
		secrets: None,
		network: vec![DeploymentNetwork::Http],
		into: None,
		port: None,
		ingress: None,
		bindings,
		handed: None,
		reaching: None,
	}
}

/// Bindings filling `images` with bucket 7 and `records` with database 3.
fn filling() -> Option<AppBindings> {
	Some(AppBindings {
		app: None,
		database: Some(BTreeMap::from([("records".to_owned(), 3)])),
		bucket: Some(BTreeMap::from([("images".to_owned(), 7)])),
	})
}

fn app() -> DeploymentRuns {
	DeploymentRuns::App { id: 0x2a }
}

fn storage() -> DeploymentRuns {
	DeploymentRuns::Component { component: "storage".into(), id: 5 }
}

fn worker(input: &DeploymentDeploy) -> Worker {
	Worker::of(input, &Bundle::unpack(&served()[&input.artifact.address]).unwrap())
}

#[test]
fn an_app_filling_a_bucket_slot_is_given_its_service_and_a_wrapped_binding() {
	let worker = worker(&deploying("slotted", app(), filling()));
	assert!(worker.bindings.contains(&Bound::Bucket { name: "images".into() }));
	assert!(!worker.data && !worker.bindings.contains(&Bound::Object));
	let config = worker.capnp();
	let service = "(name = \"bucket-images\", external = (address = \
	               \"unix:/run/buckets/images.sock\", http = ()))";
	assert!(config.contains(service), "{config}");
	let binding = "(name = \"images\", wrapped = (moduleName = \"slots:bucket\", innerBindings = \
	               [(name = \"socket\", service = \"bucket-images\")]))";
	assert!(config.contains(binding), "{config}");
	assert!(config.contains("(modules = [(name = \"slots:bucket\", internal = true"), "{config}");
	assert!(config.contains("(modules = [(name = \"slots:database\", internal = true"), "{config}");
	// The bucket's id is the driver's to set, never written for the worker.
	assert!(!config.contains("= 7") && !config.contains("\"7\""), "{config}");
	assert!(!config.contains(&format!("(name = \"{SOCKET}\"")), "{config}");
	assert!(!config.contains("OBJECT"), "{config}");
	assert!(!config.contains("/run/storage") && !config.contains("/run/object"), "{config}");
}

#[tokio::test]
async fn an_app_with_a_bucket_slot_mounts_its_own_sockets_and_never_the_storage_ones() {
	let slots = scratch("app");
	let functions =
		driver_machine_function::Functions { slots: slots.clone(), ..functions(served()) };
	functions.deploy(&binding(), deploying("slotted", app(), filling())).await.unwrap();
	let other = DeploymentRuns::Component { component: "mail".into(), id: 6 };
	functions.deploy(&binding(), deploying("plain", other, None)).await.unwrap();
	let hosted = functions.containers.hosted.lock().unwrap();
	let [(_, slotted), (_, other)] = hosted.as_slice() else { panic!("hosted {}", hosted.len()) };
	let own = slots.join("apps/b1/0000002a");
	let sockets = vec![
		Sockets { directory: slots.join("b1"), at: "/run/slots".into(), writable: false },
		Sockets { directory: own.clone(), at: "/run/buckets".into(), writable: false },
	];
	assert_eq!(slotted.sockets, sockets);
	assert!(other.sockets.is_empty(), "{:?}", other.sockets);
	// Its own directory is made before its container starts, the storage ones never.
	assert_eq!(mode(&own), 0o755);
	assert!(!slots.join("storage").exists() && !slots.join("object").exists());
	std::fs::remove_dir_all(&slots).unwrap();
}

/// A directory's permission bits.
fn mode(directory: &std::path::Path) -> u32 {
	std::fs::metadata(directory).unwrap().permissions().mode() & 0o777
}

#[tokio::test]
async fn a_file_bucket_slot_is_invalid_naming_the_slot_and_nothing_is_hosted() {
	let files = declaring(r#"[{ "name": "files", "type": "file_bucket" }]"#);
	let functions = functions(BTreeMap::from([("files".to_owned(), files.clone())]));
	let bucket = Some(BTreeMap::from([("files".to_owned(), 7)]));
	let bindings = Some(AppBindings { app: None, database: None, bucket });
	let built = hash(&files);
	let artifact = DeploymentArtifact { address: "files".into(), hash: built, architecture: None };
	let input = DeploymentDeploy { version: built, artifact, ..deploying("plain", app(), bindings) };
	let refusal = functions.deploy(&binding(), input).await.unwrap_err();
	assert_eq!(refusal.reason, "invalid");
	let message = refusal.message.unwrap_or_default();
	assert!(message.contains("slot files") && message.contains("no file bucket yet"), "{message}");
	assert!(functions.containers.hosted.lock().unwrap().is_empty());
}

#[test]
fn the_storage_component_is_two_workers_reaching_the_object_kind() {
	let worker = worker(&deploying("plain", storage(), None));
	assert!(worker.data);
	let socket = Bound::Text { name: SOCKET.into(), text: "public".into() };
	assert_eq!(worker.bindings[1], socket);
	assert!(worker.bindings.contains(&Bound::Object));
	let config = worker.capnp();
	for written in [
		"(name = \"main\", worker = .worker)",
		"(name = \"data\", worker = .dataWorker)",
		"(name = \"http\", address = \"*:8080\", http = (), service = \"main\")",
		"(name = \"data\", address = \"unix:/run/storage/data.sock\", http = (), service = \"data\")",
		"(name = \"object\", external = (address = \"unix:/run/object/object.sock\", http = ()))",
		"(name = \"OBJECT\", service = \"object\")",
		"const worker :Workerd.Worker = (",
		"const dataWorker :Workerd.Worker = (",
	] {
		assert!(config.contains(written), "{written} in {config}");
	}
	let (public, data) = config.split_at(config.find("const dataWorker").unwrap());
	assert!(public.contains(&format!("(name = \"{SOCKET}\", text = \"public\")")), "{config}");
	assert!(data.contains(&format!("(name = \"{SOCKET}\", text = \"data\")")), "{config}");
	assert!(!data.contains("\"public\")"), "{config}");
	assert!(data.contains("embed \"modules/index.js\""), "{config}");
}

/// A directory of this test's own below the system's temporary one, made empty.
fn scratch(name: &str) -> PathBuf {
	let directory = std::env::temp_dir().join(format!("function-{name}-{}", std::process::id()));
	let _ = std::fs::remove_dir_all(&directory);
	std::fs::create_dir_all(&directory).unwrap();
	directory
}

#[tokio::test]
async fn the_storage_component_mounts_the_object_socket_and_listens_in_a_closed_directory() {
	let slots = scratch("storage");
	let functions =
		driver_machine_function::Functions { slots: slots.clone(), ..functions(served()) };
	functions.deploy(&binding(), deploying("plain", storage(), None)).await.unwrap();
	let hosted = functions.containers.hosted.lock().unwrap();
	let [(_, hosted)] = hosted.as_slice() else { panic!("hosted {}", hosted.len()) };
	let sockets = vec![
		Sockets { directory: slots.join("object/b1"), at: "/run/object".into(), writable: false },
		Sockets { directory: slots.join("storage/b1"), at: "/run/storage".into(), writable: true },
	];
	assert_eq!(hosted.sockets, sockets);
	assert_eq!((mode(&slots.join("object/b1")), mode(&slots.join("storage/b1"))), (0o755, 0o700));
	std::fs::remove_dir_all(&slots).unwrap();
}

/// What node prints calling the bucket module's `method` with `arguments`, a JavaScript list,
/// against a fake fetch answering `answer`.
fn ran(method: &str, arguments: &str, answer: &str) -> serde_json::Value {
	let config = worker(&deploying("slotted", app(), filling())).capnp();
	let opening = "(name = \"slots:bucket\", internal = true, esModule = ";
	let at = config.find(opening).unwrap() + opening.len();
	let source = unquoted(&config[at..]);
	let script = format!(
		"const source = await new Response(process.stdin).text();
const made = (await import('data:text/javascript,' + encodeURIComponent(source))).default;
const asked = [];
const socket = {{ fetch: async (url, init) => {{
	asked.push({{ url, method: init.method, type: init.headers['content-type'], body: JSON.parse(init.body) }});
	return new Response({answer:?});
}} }};
let result;
try {{
	const data = await made({{ socket }}).{method}(...{arguments});
	result = {{ data: data instanceof Uint8Array ? {{ bytes: Array.from(data) }} : data }};
}} catch (error) {{ result = {{ thrown: error instanceof Error, message: error.message }}; }}
console.log(JSON.stringify({{ asked, result }}));"
	);
	let mut node = Command::new("node")
		.args(["--input-type=module", "--eval", &script])
		.stdin(Stdio::piped())
		.stdout(Stdio::piped())
		.spawn()
		.expect("node, as mise gives it");
	node.stdin.take().unwrap().write_all(source.as_bytes()).unwrap();
	let out = node.wait_with_output().unwrap();
	assert!(out.status.success(), "node failed");
	serde_json::from_slice(&out.stdout).unwrap()
}

fn success(data: &serde_json::Value) -> String {
	serde_json::json!({ "status": "success", "data": data }).to_string()
}

#[test]
fn write_posts_its_content_as_base64url_and_answers_the_object() {
	let object = serde_json::json!({ "object": "ab.png", "hash": "ab", "size": 4 });
	let out = ran("write", "[new Uint8Array([0xfb, 0xff, 0x00, 0x01]), 'png']", &success(&object));
	let asked = &out["asked"][0];
	assert_eq!(asked["url"], "http://bucket/storage/object_write");
	assert_eq!((&asked["method"], &asked["type"]), (&"POST".into(), &"application/json".into()));
	assert_eq!(asked["body"], serde_json::json!({ "content": "-_8AAQ", "extension": "png" }));
	assert_eq!(out["result"]["data"], object);
	// No bucket is sent, the driver setting it, and an extension not given is left out.
	let out = ran("write", "['hi']", &success(&object));
	assert_eq!(out["asked"][0]["body"], serde_json::json!({ "content": "aGk" }));
}

#[test]
fn read_answers_the_content_as_bytes() {
	let content = serde_json::json!({ "content": "-_8AAQ", "size": 9 });
	let out = ran("read", "['ab.png', { start: 1, length: 4 }]", &success(&content));
	let asked = &out["asked"][0];
	assert_eq!(asked["url"], "http://bucket/storage/object_read");
	let body = serde_json::json!({ "object": "ab.png", "range": { "start": 1, "length": 4 } });
	assert_eq!(asked["body"], body);
	assert_eq!(out["result"]["data"], serde_json::json!({ "bytes": [0xfb, 0xff, 0x00, 0x01] }));
	let whole = ran("read", "['ab.png']", &success(&content));
	assert_eq!(whole["asked"][0]["body"], serde_json::json!({ "object": "ab.png" }));
}

#[test]
fn describe_list_and_delete_post_their_operations() {
	let named = serde_json::json!({ "object": "ab.png" });
	for (method, operation) in [("describe", "object_describe"), ("delete", "object_delete")] {
		let out = ran(method, "['ab.png']", &success(&serde_json::json!({})));
		assert_eq!(out["asked"][0]["url"], format!("http://bucket/storage/{operation}"));
		assert_eq!(out["asked"][0]["body"], named);
		assert_eq!(out["result"]["data"], serde_json::json!({}));
	}
	let listed = serde_json::json!({ "objects": [], "next": "ab.png" });
	let out = ran("list", "['aa', 10]", &success(&listed));
	assert_eq!(out["asked"][0]["url"], "http://bucket/storage/object_list");
	assert_eq!(out["asked"][0]["body"], serde_json::json!({ "after": "aa", "limit": 10 }));
	assert_eq!(out["result"]["data"], listed);
	let out = ran("list", "[]", &success(&listed));
	assert_eq!(out["asked"][0]["body"], serde_json::json!({}));
}

#[test]
fn a_refusal_is_thrown_with_its_reason_and_message() {
	let refused = r#"{"status":"error","reason":"not_found","message":"no such object"}"#;
	let out = ran("read", "['ab.png']", refused);
	let thrown = serde_json::json!({ "thrown": true, "message": "not_found: no such object" });
	assert_eq!(out["result"], thrown);
}
