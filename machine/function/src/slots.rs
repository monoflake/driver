//! What a deploy's bindings fill held to the slots its bundle declares, RFC 49qyg, and each slot's
//! name kept apart from every other name its worker is bound by, RFC rt6gi.

use std::collections::BTreeMap;

use driver_machine_container::Refused;
use envelope::contracts::{DeploymentDeploy, ManifestSlot, SlotType};

use crate::RESERVED;

fn invalid(message: String) -> Refused {
	Refused { reason: "invalid", message: Some(message) }
}

/// The map of `app-bindings` a slot of its type is filled under.
fn under(declared: SlotType) -> &'static str {
	match declared {
		SlotType::App => "app",
		SlotType::Database => "database",
		SlotType::FileBucket | SlotType::ObjectBucket => "bucket",
	}
}

/// A slot's type as its manifest writes it.
fn written(declared: SlotType) -> &'static str {
	match declared {
		SlotType::App => "app",
		SlotType::Database => "database",
		SlotType::FileBucket => "file_bucket",
		SlotType::ObjectBucket => "object_bucket",
	}
}

/// Each slot declared filled under its type and nothing else filled, and no slot named as a secret
/// given or held or as a name the driver binds, refused `invalid` naming the slot.
pub(crate) fn filled(
	input: &DeploymentDeploy,
	slots: &[ManifestSlot],
	held: &[String],
) -> Result<(), Refused> {
	let declared: BTreeMap<&str, SlotType> =
		slots.iter().map(|s| (s.name.as_str(), s.r#type)).collect();
	let bindings = input.bindings.as_ref();
	let maps = [
		("app", bindings.and_then(|b| b.app.as_ref())),
		("database", bindings.and_then(|b| b.database.as_ref())),
		("bucket", bindings.and_then(|b| b.bucket.as_ref())),
	];
	for (map, names) in maps {
		for name in names.into_iter().flat_map(BTreeMap::keys) {
			match declared.get(name.as_str()) {
				None => {
					let message =
						format!("the bindings fill the slot {name}, which the build does not declare");
					return Err(invalid(message));
				}
				Some(t) if under(*t) != map => {
					let t = written(*t);
					return Err(invalid(format!("the slot {name} is declared a {t}, filled under {map}")));
				}
				Some(_) => {}
			}
		}
	}
	for slot in slots {
		let name = slot.name.as_str();
		let map = under(slot.r#type);
		let filling = maps.iter().find(|(m, _)| *m == map).and_then(|(_, names)| *names);
		if !filling.is_some_and(|names| names.contains_key(name)) {
			let message =
				format!("the build declares the slot {name}, which the bindings leave unfilled");
			return Err(invalid(message));
		}
		let secret = input.secrets.as_ref().is_some_and(|s| s.contains_key(name));
		if secret || held.iter().any(|h| h == name) {
			return Err(invalid(format!("the slot {name} is named as a secret of the deployment")));
		}
		if RESERVED.contains(&name) {
			return Err(invalid(format!("the slot {name} is named as a name the driver binds")));
		}
	}
	Ok(())
}
