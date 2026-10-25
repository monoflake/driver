//! workerd's configuration for one deployment, written in Cap'n Proto's text as `workerd serve`
//! reads it, against workerd's own schema.
//! https://github.com/cloudflare/workerd/blob/main/src/workerd/server/workerd.capnp

use envelope::contracts::{DeploymentDeploy, DeploymentHanded, DeploymentNetwork};

use crate::{Bound, Bundle, Configure, FOOTING, Kind, MODULES, PORT, Worker};

/// What the configuration opens with, its schema imported.
const OPENING: &str = concat!(
	"# workerd's configuration for one deployment, written by driver(machine)'s function kind.\n",
	"using Workerd = import \"/workerd/workerd.capnp\";\n",
);

/// What names the origins of what a worker reaches, each by its id, RFC y2xd3.
const REACHING: &str = "MONOFLAKE_REACHING";

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
		DeploymentHanded::Root { value } => text("MONOFLAKE_ROOT", value),
		DeploymentHanded::Key { .. } => secret("MONOFLAKE_KEY"),
		DeploymentHanded::Certificate { value } => text("MONOFLAKE_CERTIFICATE", value),
		DeploymentHanded::SigningKey { .. } => secret("MONOFLAKE_SIGNING_KEY"),
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
		let secrets = input.secrets.keys().map(|name| Bound::Secret { name: name.clone() });
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
				.chain(secrets)
				.collect(),
			port: PORT,
			outbound,
			reaches: input.reaching.as_deref().is_some_and(|r| !r.is_empty()),
		}
	}

	fn capnp(&self) -> String {
		// The fence of its namespace narrows the private network to the deployments it reaches.
		let allowed: Vec<&str> = [(self.outbound, "\"public\""), (self.reaches, "\"private\"")]
			.into_iter()
			.filter_map(|(open, name)| open.then_some(name))
			.collect();
		let network = match self.outbound {
			true => format!("(allow = [{}], tlsOptions = (trustBrowserCas = true))", allowed.join(", ")),
			false => format!("(allow = [{}])", allowed.join(", ")),
		};
		let services = [
			"(name = \"main\", worker = .worker)".to_owned(),
			format!("(name = {}, network = {network})", quoted(OUTBOUND)),
		];
		let socket = format!(
			"[(name = \"http\", address = {}, http = (), service = \"main\")]",
			quoted(&format!("*:{}", self.port))
		);
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
				Bound::Secret { name } => {
					format!("(name = {}, text = embed {})", quoted(name), quoted(&format!("/{name}")))
				}
			})
			.collect();
		// What it reaches is read from workerd's environment, which the container kind sets as it
		// sets an image's, beside the values handed.
		if self.reaches {
			let platform = |b: &Bound| match b {
				Bound::Text { name, .. } | Bound::Secret { name } => name.starts_with("MONOFLAKE_"),
			};
			let at = self.bindings.iter().take_while(|b| platform(b)).count();
			let reaching = quoted(REACHING);
			bindings.insert(at, format!("(name = {reaching}, fromEnvironment = {reaching})"));
		}
		format!(
			"{OPENING}
const config :Workerd.Config = (
	services = {},
	sockets = {socket}
);

const worker :Workerd.Worker = (
	modules = {},
	compatibilityDate = {},
	compatibilityFlags = {},
	bindings = {},
	globalOutbound = {}
);
",
			listed(&services, "\t"),
			listed(&modules, "\t"),
			quoted(&self.compatibility_date),
			listed(&flags, "\t"),
			listed(&bindings, "\t"),
			quoted(OUTBOUND),
		)
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
