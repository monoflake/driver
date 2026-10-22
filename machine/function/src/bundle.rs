//! A bundle read from its artifact, a tar archive of its modules and its metadata, RFC dg903.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Component, Path};

use driver_machine_container::Refused;
use serde_json::Value;

use crate::{Bundle, Kind, METADATA, Module, Unpack};

fn malformed(message: impl Into<String>) -> Refused {
	Refused { reason: "malformed", message: Some(message.into()) }
}

fn unread(e: &std::io::Error) -> Refused {
	malformed(format!("the artifact is no tar archive of modules, {e}"))
}

/// An entry's path as a module's name, its parts joined by `/`, never `..` or a root.
fn named(path: &Path) -> Result<String, Refused> {
	let mut parts = Vec::new();
	for component in path.components() {
		match component {
			Component::CurDir => {}
			Component::Normal(part) => {
				parts.push(part.to_str().ok_or_else(|| malformed("a module's name is UTF-8"))?.to_owned())
			}
			Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
				return Err(malformed(format!("{} lies outside the bundle", path.display())));
			}
		}
	}
	if parts.is_empty() {
		return Err(malformed("an entry of the bundle names nothing"));
	}
	Ok(parts.join("/"))
}

/// A module's type, by its name's extension.
fn kind(name: &str) -> Result<Kind, Refused> {
	match name.rsplit_once('.').map(|(_, extension)| extension) {
		Some("js" | "mjs") => Ok(Kind::Es),
		Some("cjs") => Ok(Kind::CommonJs),
		Some("wasm") => Ok(Kind::Wasm),
		Some("txt") => Ok(Kind::Text),
		Some("bin") => Ok(Kind::Data),
		Some("json") => Ok(Kind::Json),
		_ => Err(malformed(format!(
			"{name}: a module is named .js, .mjs, .cjs, .wasm, .txt, .bin or .json"
		))),
	}
}

fn module(name: String, bytes: Vec<u8>) -> Result<Module, Refused> {
	Ok(Module { kind: kind(&name)?, name, bytes })
}

/// Whether a date is written `YYYY-MM-DD`.
fn dated(date: &str) -> bool {
	date.len() == 10
		&& date
			.chars()
			.enumerate()
			.all(|(at, c)| if at == 4 || at == 7 { c == '-' } else { c.is_ascii_digit() })
}

/// Every file of the archive by its name, its directories passed over.
fn files(bytes: &[u8]) -> Result<BTreeMap<String, Vec<u8>>, Refused> {
	let mut archive = tar::Archive::new(bytes);
	let mut files = BTreeMap::new();
	for entry in archive.entries().map_err(|e| unread(&e))? {
		let mut entry = entry.map_err(|e| unread(&e))?;
		let kind = entry.header().entry_type();
		if kind.is_dir() || kind.is_pax_global_extensions() || kind.is_pax_local_extensions() {
			continue;
		}
		if !kind.is_file() {
			return Err(malformed("a bundle holds files and directories alone"));
		}
		let name = named(&entry.path().map_err(|e| unread(&e))?)?;
		let mut content = Vec::new();
		entry.read_to_end(&mut content).map_err(|e| unread(&e))?;
		if files.insert(name.clone(), content).is_some() {
			return Err(malformed(format!("the bundle holds {name} twice")));
		}
	}
	Ok(files)
}

impl Unpack for Bundle {
	fn unpack(bytes: &[u8]) -> Result<Self, Refused> {
		let mut files = files(bytes)?;
		let metadata =
			files.remove(METADATA).ok_or_else(|| malformed(format!("a bundle holds its {METADATA}")))?;
		let metadata: Value = serde_json::from_slice(&metadata)
			.map_err(|e| malformed(format!("{METADATA} is not JSON, {e}")))?;
		let main = metadata
			.get("main_module")
			.and_then(Value::as_str)
			.ok_or_else(|| malformed(format!("{METADATA} names its main_module")))?;
		let compatibility_date = metadata
			.get("compatibility_date")
			.and_then(Value::as_str)
			.filter(|d| dated(d))
			.ok_or_else(|| malformed(format!("{METADATA} names its compatibility_date, YYYY-MM-DD")))?
			.to_owned();
		let compatibility_flags = match metadata.get("compatibility_flags") {
			None => Vec::new(),
			Some(flags) => flags
				.as_array()
				.and_then(|f| f.iter().map(|f| f.as_str().map(str::to_owned)).collect())
				.ok_or_else(|| malformed(format!("{METADATA}'s compatibility_flags are strings")))?,
		};
		let first = files
			.remove(main)
			.ok_or_else(|| malformed(format!("the main module {main} is not in the bundle")))?;
		let mut modules = vec![module(main.to_owned(), first)?];
		for (name, bytes) in files {
			modules.push(module(name, bytes)?);
		}
		Ok(Self { modules, compatibility_date, compatibility_flags })
	}
}
