//! workerd's configuration for one deployment, written in Cap'n Proto's text as `workerd serve`
//! reads it, against workerd's own schema.
//! https://github.com/cloudflare/workerd/blob/main/src/workerd/server/workerd.capnp

use envelope::contracts::{DeploymentDeploy, DeploymentHanded, DeploymentNetwork, DeploymentRuns};

use crate::{
	Bound, Bundle, COMPUTE, Configure, DATA, FOOTING, Kind, MODULES, OBJECT, OBJECT_SOCKET, OBJECTS,
	PORT, SOCKET, STORAGE, STORED, Worker,
};

mod bucket;
mod database;

/// What the configuration opens with, its schema imported.
const OPENING: &str = concat!(
	"# workerd's configuration for one deployment, written by driver(machine)'s function kind.\n",
	"using Workerd = import \"/workerd/workerd.capnp\";\n",
);

/// What names the origins of what a worker reaches, each by its id, RFC y2xd3.
const REACHING: &str = "MONOFLAKE_REACHING";

/// The reserved names a handed value is bound under, RFC y2xd3.
const ROOT: &str = "MONOFLAKE_ROOT";
const KEY: &str = "MONOFLAKE_KEY";
const CERTIFICATE: &str = "MONOFLAKE_CERTIFICATE";
const SIGNING_KEY: &str = "MONOFLAKE_SIGNING_KEY";

/// Every name the driver binds a worker by of its own, which no slot may take.
pub const RESERVED: [&str; 7] = [FOOTING, REACHING, ROOT, KEY, CERTIFICATE, SIGNING_KEY, OBJECT];

/// What [`SOCKET`] reads in each listener of the storage component.
const PUBLIC: &str = "public";
const DATA_SOCKET: &str = "data";

/// The service its storage component reaches the binding's object kind through.
const OBJECT_SERVICE: &str = "object";

/// Whether a deployment is its binding's storage component, RFC ahcrp.
pub(crate) fn storage(runs: &DeploymentRuns) -> bool {
	match runs {
		DeploymentRuns::Component { component, .. } => component == STORAGE,
		DeploymentRuns::App { .. } => false,
	}
}

/// Whether a deployment is its binding's compute component, RFC 49qyg.
pub(crate) fn compute(runs: &DeploymentRuns) -> bool {
	matches!(runs, DeploymentRuns::Component { component, .. } if component == COMPUTE)
}

/// The service a worker reaches out through, the internet where it may, the private network where
/// it reaches deployments, and nothing where neither.
const OUTBOUND: &str = "outbound";

/// A value handed bound under its reserved name as hex text, a secret as a secret whose file the
/// container kind writes in hex, RFC y2xd3.
fn handed(value: &DeploymentHanded) -> Bound {
	let text = |name: &str, bytes: &[u8]| Bound::Text {
		name: name.to_owned(),
		text: bytes.iter().map(|b| format!("{b:02x}")).collect(),
	};
	let secret = |name: &str| Bound::Secret { name: name.to_owned() };
	match value {
		DeploymentHanded::Root { value } => text(ROOT, value),
		DeploymentHanded::Key { .. } => secret(KEY),
		DeploymentHanded::Certificate { value } => text(CERTIFICATE, value),
		DeploymentHanded::SigningKey { .. } => secret(SIGNING_KEY),
	}
}

/// A text as a Cap'n Proto string, quoted, its quotes, backslashes and control characters escaped.
fn quoted(text: &str) -> String {
	let mut written = String::from("\"");
	for c in text.chars() {
		match c {
			'"' => written.push_str("\\\""),
			'\\' => written.push_str("\\\\"),
			c if c.is_control() => {
				let mut bytes = [0; 4];
				for byte in c.encode_utf8(&mut bytes).bytes() {
					written.push_str(&format!("\\x{byte:02x}"));
				}
			}
			c => written.push(c),
		}
	}
	written.push('"');
	written
}

/// The field of `Workerd.Worker.Module` a module's type is given in.
fn field(kind: Kind) -> &'static str {
	match kind {
		Kind::Es => "esModule",
		Kind::CommonJs => "commonJsModule",
		Kind::Wasm => "wasm",
		Kind::Text => "text",
		Kind::Data => "data",
		Kind::Json => "json",
	}
}

/// Entries of a list, each on a line of its own at the indentation given.
fn listed(entries: &[String], indent: &str) -> String {
	match entries {
		[] => "[]".to_owned(),
		_ => {
			let lines: Vec<String> = entries.iter().map(|e| format!("{indent}\t{e}")).collect();
			format!("[\n{}\n{indent}]", lines.join(",\n"))
		}
	}
}

impl Configure for Worker {
	fn of(input: &DeploymentDeploy, bundle: &Bundle) -> Self {
		let footing = Bound::Text { name: FOOTING.to_owned(), text: input.footing.clone() };
		let secrets =
			input.secrets.iter().flat_map(|s| s.keys()).map(|name| Bound::Secret { name: name.clone() });
		let slots = input
			.bindings
			.iter()
			.flat_map(|b| b.database.iter().flatten())
			.map(|(name, _)| Bound::Database { name: name.clone() });
		let buckets = input
			.bindings
			.iter()
			.flat_map(|b| b.bucket.iter().flatten())
			.map(|(name, _)| Bound::Bucket { name: name.clone() });
		let data = storage(&input.runs);
		let socket = Bound::Text { name: SOCKET.to_owned(), text: PUBLIC.to_owned() };
		let outbound = input.network.iter().any(|n| match n {
			DeploymentNetwork::Http | DeploymentNetwork::Tcp => true,
			DeploymentNetwork::Udp | DeploymentNetwork::Icmp => false,
		});
		Self {
			modules: bundle.modules.iter().map(|m| (m.name.clone(), m.kind)).collect(),
			compatibility_date: bundle.compatibility_date.clone(),
			compatibility_flags: bundle.compatibility_flags.clone(),
			bindings: std::iter::once(footing)
				.chain(input.handed.iter().flatten().map(handed))
				.chain(data.then_some(socket))
				.chain(compute(&input.runs).then_some(Bound::Environment { name: "ENTRY".to_owned() }))
				.chain(secrets)
				.chain(slots)
				.chain(buckets)
				.chain(data.then_some(Bound::Object))
				.collect(),
			port: PORT,
			data,
			outbound,
			reaches: input.reaching.as_deref().is_some_and(|r| !r.is_empty()),
		}
	}

	fn capnp(&self) -> String {
		// The fence of its namespace narrows the private network to the deployments it reaches.
		let entry =
			self.bindings.iter().any(|b| matches!(b, Bound::Environment { name } if name == "ENTRY"));
		let allowed: Vec<&str> =
			[(self.outbound, "\"public\""), (self.reaches || entry, "\"private\"")]
				.into_iter()
				.filter_map(|(open, name)| open.then_some(name))
				.collect();
		let network = match self.outbound {
			true => format!("(allow = [{}], tlsOptions = (trustBrowserCas = true))", allowed.join(", ")),
			false => format!("(allow = [{}])", allowed.join(", ")),
		};
		let databased = self.bindings.iter().any(|b| matches!(b, Bound::Database { .. }));
		let buckets: Vec<&str> = self
			.bindings
			.iter()
			.filter_map(|b| match b {
				Bound::Bucket { name } => Some(name.as_str()),
				Bound::Environment { .. }
				| Bound::Text { .. }
				| Bound::Secret { .. }
				| Bound::Database { .. }
				| Bound::Object => None,
			})
			.collect();
		let mut services = vec!["(name = \"main\", worker = .worker)".to_owned()];
		if self.data {
			services.push(format!("(name = {}, worker = .dataWorker)", quoted(DATA_SOCKET)));
		}
		services.push(format!("(name = {}, network = {network})", quoted(OUTBOUND)));
		// A deployment filling no slot is configured as one before slots were.
		let mut extensions = Vec::new();
		if databased {
			services.push(database::service());
			extensions.push(database::extension());
		}
		services.extend(buckets.iter().map(|slot| bucket::service(slot)));
		if !buckets.is_empty() {
			extensions.push(bucket::extension());
		}
		if self.bindings.contains(&Bound::Object) {
			let address = quoted(&format!("unix:{OBJECTS}/{OBJECT_SOCKET}"));
			let name = quoted(OBJECT_SERVICE);
			services.push(format!("(name = {name}, external = (address = {address}, http = ()))"));
		}
		let extensions = match extensions.as_slice() {
			[] => String::new(),
			_ => format!(",\n\textensions = {}", listed(&extensions, "\t")),
		};
		let http = format!(
			"(name = \"http\", address = {}, http = (), service = \"main\")",
			quoted(&format!("*:{}", self.port))
		);
		let sockets = match self.data {
			true => {
				let address = quoted(&format!("unix:{STORED}/{DATA}"));
				let name = quoted(DATA_SOCKET);
				let data = format!("(name = {name}, address = {address}, http = (), service = {name})");
				listed(&[http, data], "\t")
			}
			false => format!("[{http}]"),
		};
		let modules: Vec<String> = self
			.modules
			.iter()
			.map(|(name, kind)| {
				let file = quoted(&format!("{MODULES}/{name}"));
				format!("(name = {}, {} = embed {file})", quoted(name), field(*kind))
			})
			.collect();
		let flags: Vec<String> = self.compatibility_flags.iter().map(|f| quoted(f)).collect();
		// A secret is embedded by its name alone, found where `--import-path` names its directory.
		let mut bindings: Vec<String> = self
			.bindings
			.iter()
			.map(|b| match b {
				Bound::Text { name, text } => format!("(name = {}, text = {})", quoted(name), quoted(text)),
				Bound::Environment { name } => {
					format!("(name = {}, fromEnvironment = {})", quoted(name), quoted(name))
				}
				Bound::Secret { name } => {
					format!("(name = {}, text = embed {})", quoted(name), quoted(&format!("/{name}")))
				}
				Bound::Database { name } => database::binding(name),
				Bound::Bucket { name } => bucket::binding(name),
				Bound::Object => {
					format!("(name = {}, service = {})", quoted(OBJECT), quoted(OBJECT_SERVICE))
				}
			})
			.collect();
		// What it reaches is read from workerd's environment, which the container kind sets as it
		// sets an image's, beside the values handed.
		if self.reaches {
			let platform = |b: &Bound| match b {
				Bound::Text { name, .. } | Bound::Secret { name } => name.starts_with("MONOFLAKE_"),
				Bound::Environment { .. }
				| Bound::Database { .. }
				| Bound::Bucket { .. }
				| Bound::Object => false,
			};
			let at = self.bindings.iter().take_while(|b| platform(b)).count();
			let reaching = quoted(REACHING);
			bindings.insert(at, format!("(name = {reaching}, fromEnvironment = {reaching})"));
		}
		let worker = |name: &str, bindings: &[String]| {
			format!(
				"
const {name} :Workerd.Worker = (
	modules = {},
	compatibilityDate = {},
	compatibilityFlags = {},
	bindings = {},
	globalOutbound = {}
);
",
				listed(&modules, "\t"),
				quoted(&self.compatibility_date),
				listed(&flags, "\t"),
				listed(bindings, "\t"),
				quoted(OUTBOUND),
			)
		};
		let mut written = format!(
			"{OPENING}
const config :Workerd.Config = (
	services = {},
	sockets = {sockets}{extensions}
);
{}",
			listed(&services, "\t"),
			worker("worker", &bindings),
		);
		// The data listener's worker differs from the public one by what its socket binding reads.
		if self.data {
			let public = format!("(name = {}, text = {})", quoted(SOCKET), quoted(PUBLIC));
			let data = format!("(name = {}, text = {})", quoted(SOCKET), quoted(DATA_SOCKET));
			let bindings: Vec<String> =
				bindings.into_iter().map(|b| if b == public { data.clone() } else { b }).collect();
			written.push_str(&worker("dataWorker", &bindings));
		}
		written
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_text_is_quoted_with_what_would_end_it_escaped() {
		assert_eq!(quoted("plain"), "\"plain\"");
		assert_eq!(quoted("a \"b\" \\c"), "\"a \\\"b\\\" \\\\c\"");
		assert_eq!(quoted("line\nnext\u{7f}"), "\"line\\x0anext\\x7f\"");
		assert_eq!(quoted("caf\u{e9}"), "\"caf\u{e9}\"");
	}
}
