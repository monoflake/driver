//! What the platform hands a deployment, each value lowercase hex under its reserved `MONOFLAKE_`
//! name, in its environment or among its secrets, and the origins of what it reaches, RFC y2xd3.

use std::collections::BTreeMap;

use envelope::contracts::{DeploymentHanded, DeploymentRuns};

use crate::Refused;

/// What a deployment is handed, as its container is given it.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Bound {
	/// Each value not secret, `NAME=hex`.
	pub(super) env: Vec<String>,
	/// Each secret, its hex by its name.
	pub(super) secrets: BTreeMap<String, Vec<u8>>,
}

/// A value's reserved name, its bytes, and whether it is a secret.
fn named(handed: &DeploymentHanded) -> (&'static str, &[u8], bool) {
	match handed {
		DeploymentHanded::Root { value } => ("MONOFLAKE_ROOT", value, false),
		DeploymentHanded::Key { value } => ("MONOFLAKE_KEY", value, true),
		DeploymentHanded::Certificate { value } => ("MONOFLAKE_CERTIFICATE", value, false),
		DeploymentHanded::SigningKey { value } => ("MONOFLAKE_SIGNING_KEY", value, true),
	}
}

fn hex(bytes: &[u8]) -> String {
	bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Every value handed bound by its name, `invalid` where one is handed twice.
pub(super) fn bound(handed: &[DeploymentHanded]) -> Result<Bound, Refused> {
	let mut bound = Bound::default();
	let mut seen = Vec::new();
	for value in handed {
		let (name, bytes, secret) = named(value);
		if seen.contains(&name) {
			return Err(Refused::new("invalid", format!("{name} is handed more than once")));
		}
		seen.push(name);
		match secret {
			true => {
				bound.secrets.insert(name.to_owned(), hex(bytes).into_bytes());
			}
			false => bound.env.push(format!("{name}={}", hex(bytes))),
		}
	}
	Ok(bound)
}

/// The name what it reaches is bound under.
const REACHING: &str = "MONOFLAKE_REACHING";

/// A deployment's name as the entry routes by it, its id in 8 hex digits whatever its kind and its
/// binding's namespace, `b<8 hex>`, or an old binding's `b<decimal>`.
pub(super) fn name(namespace: &str, runs: &DeploymentRuns) -> (u32, String) {
	match runs {
		DeploymentRuns::App { id } | DeploymentRuns::Component { id, .. } => {
			(*id, format!("{id:08x}.{namespace}"))
		}
	}
}

/// What it reaches as its environment holds it, a JSON object of each target's id in 8 hex digits
/// and its origin, the entry with the target's name as the host, none where it reaches nothing.
pub(super) fn reaching(namespace: &str, targets: &[DeploymentRuns], port: u16) -> Option<String> {
	if targets.is_empty() {
		return None;
	}
	let origins: serde_json::Map<String, serde_json::Value> = targets
		.iter()
		.map(|runs| name(namespace, runs))
		.map(|(id, name)| (format!("{id:08x}"), format!("http://{name}:{port}").into()))
		.collect();
	Some(format!("{REACHING}={}", serde_json::Value::Object(origins)))
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn bytes_are_hex_in_the_environment_and_a_secret_is_a_secret() {
		let handed = [
			DeploymentHanded::Root { value: vec![0x0a, 0xff] },
			DeploymentHanded::Key { value: b"key".to_vec() },
			DeploymentHanded::Certificate { value: vec![1] },
			DeploymentHanded::SigningKey { value: b"signing".to_vec() },
		];
		let bound = bound(&handed).unwrap();
		assert_eq!(bound.env, ["MONOFLAKE_ROOT=0aff", "MONOFLAKE_CERTIFICATE=01"]);
		let secrets: Vec<(&str, &[u8])> =
			bound.secrets.iter().map(|(n, v)| (n.as_str(), v.as_slice())).collect();
		assert_eq!(
			secrets,
			[("MONOFLAKE_KEY", &b"6b6579"[..]), ("MONOFLAKE_SIGNING_KEY", &b"7369676e696e67"[..])]
		);
	}

	#[test]
	fn what_is_reached_is_each_id_in_hex_and_the_entry_by_its_name() {
		assert_eq!(reaching("b1", &[], 4321), None);
		let targets = [
			DeploymentRuns::Component { component: "stand-in".into(), id: 0x1a2b_3c4d },
			DeploymentRuns::App { id: 9 },
		];
		assert_eq!(
			reaching("b1", &targets, 4321).unwrap(),
			concat!(
				r#"MONOFLAKE_REACHING={"00000009":"http://00000009.b1:4321","#,
				r#""1a2b3c4d":"http://1a2b3c4d.b1:4321"}"#
			)
		);
	}

	#[test]
	fn a_value_handed_twice_is_invalid() {
		let handed =
			[DeploymentHanded::Key { value: vec![1] }, DeploymentHanded::Key { value: vec![2] }];
		assert_eq!(bound(&handed).map_err(|r| r.reason), Err("invalid"));
		assert_eq!(bound(&[]).unwrap(), Bound::default());
	}
}
