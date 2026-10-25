//! A root of the Nix store's collector for each container's runtime binary, a link at
//! `<namespace>/<id>` in the roots' directory, so no binary a container names is ever collected.

use std::collections::BTreeMap;
use std::io::ErrorKind;
use std::path::{Component, Path, PathBuf};
use std::process::Stdio;

use crate::{Refused, Roots};

/// What asking for a container's root found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Rooted {
	/// Made now, holding the path given.
	Made(PathBuf),
	/// There already, holding the same path.
	Held,
	/// None, the binary lying outside the store.
	Outside,
}

fn failed(path: &Path, e: &std::io::Error) -> Refused {
	Refused::new("fault", format!("{}: {e}", path.display()))
}

/// Whether a name is one plain name of a directory's entry, so a link it names stays in its own.
fn plain(name: &str) -> bool {
	let mut components = Path::new(name).components();
	let one = matches!(components.next(), Some(Component::Normal(_))) && components.next().is_none();
	one && !name.starts_with('.') && !name.contains('/')
}

/// A container's link, refused where its namespace or id is not one plain name.
fn link(roots: &Roots, namespace: &str, id: &str) -> Result<PathBuf, Refused> {
	match plain(namespace) && plain(id) {
		true => Ok(roots.directory.join(namespace).join(id)),
		false => Err(Refused::new("fault", format!("{namespace} {id} names no root"))),
	}
}

/// The store path a path lies in, none where it lies outside the store.
fn store_path(store: &Path, path: &Path) -> Option<PathBuf> {
	match path.strip_prefix(store).ok()?.components().next()? {
		Component::Normal(name) => Some(store.join(name)),
		Component::Prefix(_) | Component::RootDir | Component::CurDir | Component::ParentDir => None,
	}
}

/// The store path a root of the binary holds, the one it is named in where that is plain whatever
/// it resolves to, as the shim runs it by that name, and else the one it resolves into.
async fn held(roots: &Roots, binary: &Path) -> Result<Option<PathBuf>, Refused> {
	let plainly = binary.components().all(|c| matches!(c, Component::RootDir | Component::Normal(_)));
	if let Some(named) = store_path(&roots.store, binary).filter(|_| plainly) {
		// A store path gone is a failure.
		return match tokio::fs::symlink_metadata(&named).await {
			Ok(_) => Ok(Some(named)),
			Err(e) => Err(failed(&named, &e)),
		};
	}
	match tokio::fs::canonicalize(binary).await {
		Ok(resolved) => Ok(store_path(&roots.store, &resolved)),
		// A binary named outside the store and not there is none of the store's.
		Err(_) => Ok(None),
	}
}

/// A link removed, none there being no failure, and anything but a link left and refused.
async fn unlinked(path: &Path) -> Result<(), Refused> {
	match tokio::fs::symlink_metadata(path).await {
		Ok(metadata) if metadata.file_type().is_symlink() => match tokio::fs::remove_file(path).await {
			Ok(()) => Ok(()),
			Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
			Err(e) => Err(failed(path, &e)),
		},
		Ok(_) => Err(Refused::new("fault", format!("{} is no link, left alone", path.display()))),
		Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
		Err(e) => Err(failed(path, &e)),
	}
}

/// The link made a root of the store path, by nix-store where it is given, which tells a
/// collection already running as Nix's own roots do, and else by hand and the path checked after.
async fn linked(roots: &Roots, path: &Path, target: &Path) -> Result<(), Refused> {
	let Some(nix) = &roots.nix else {
		unlinked(path).await?;
		tokio::fs::symlink(target, path).await.map_err(|e| failed(path, &e))?;
		// A collection that began before the link may still take the path, which is then a fault.
		return match tokio::fs::try_exists(target).await {
			Ok(true) => Ok(()),
			Ok(false) | Err(_) => {
				Err(Refused::new("fault", format!("{} was collected as it was rooted", target.display())))
			}
		};
	};
	let ran = tokio::process::Command::new(nix)
		.arg("--add-root")
		.arg(path)
		.arg("--realise")
		.arg(target)
		.stdin(Stdio::null())
		.stdout(Stdio::piped())
		.stderr(Stdio::piped())
		.kill_on_drop(true)
		.spawn()
		.map_err(|e| failed(nix, &e))?;
	// Killed once past its time, as dropping it kills it, so no root holds up a deploy or a start.
	let output = match tokio::time::timeout(roots.waited, ran.wait_with_output()).await {
		Ok(output) => output.map_err(|e| failed(nix, &e))?,
		Err(_) => {
			return Err(Refused::new(
				"fault",
				format!(
					"{} --add-root {} killed, not done within {} ms",
					nix.display(),
					path.display(),
					roots.waited.as_millis()
				),
			));
		}
	};
	match output.status.success() {
		true => Ok(()),
		false => Err(Refused::new(
			"fault",
			format!(
				"{} --add-root {}: {}",
				nix.display(),
				path.display(),
				String::from_utf8_lossy(&output.stderr).trim()
			),
		)),
	}
}

/// A container's root of the store path its binary lies in, made where it lies in the store.
pub(super) async fn made(
	roots: &Roots,
	namespace: &str,
	id: &str,
	binary: &Path,
) -> Result<Rooted, Refused> {
	let path = link(roots, namespace, id)?;
	let Some(target) = held(roots, binary).await? else {
		return Ok(Rooted::Outside);
	};
	if tokio::fs::read_link(&path).await.is_ok_and(|t| t == target) {
		return Ok(Rooted::Held);
	}
	let directory = roots.directory.join(namespace);
	// Three tries, as a namespace emptied by a removal may lose its directory before the link.
	for _ in 0..3 {
		tokio::fs::create_dir_all(&directory).await.map_err(|e| failed(&directory, &e))?;
		match linked(roots, &path, &target).await {
			Ok(()) => return Ok(Rooted::Made(target)),
			Err(_) if !tokio::fs::try_exists(&directory).await.unwrap_or(true) => {}
			Err(refused) => return Err(refused),
		}
	}
	Err(Refused::new("fault", format!("{} was not made", path.display())))
}

/// A container's root removed, none there being no failure, and its namespace's directory once
/// it holds nothing.
pub(super) async fn remove(roots: &Roots, namespace: &str, id: &str) -> Result<(), Refused> {
	unlinked(&link(roots, namespace, id)?).await?;
	emptied(roots, namespace).await;
	Ok(())
}

/// A namespace's directory removed once it holds nothing.
pub(super) async fn emptied(roots: &Roots, namespace: &str) {
	// A namespace still holding a root keeps its directory, which is no failure.
	if plain(namespace) {
		let _ = tokio::fs::remove_dir(roots.directory.join(namespace)).await;
	}
}

/// The names in a directory, each told apart as a plain name or else a line saying it is left.
async fn names(directory: &Path, told: &mut Vec<String>) -> Vec<(String, std::fs::FileType)> {
	let mut entries = match tokio::fs::read_dir(directory).await {
		Ok(entries) => entries,
		Err(e) if e.kind() == ErrorKind::NotFound => return Vec::new(),
		Err(e) => {
			told.push(format!("roots {}: {e}", directory.display()));
			return Vec::new();
		}
	};
	let mut found = Vec::new();
	loop {
		match entries.next_entry().await {
			Ok(Some(entry)) => match (entry.file_name().into_string(), entry.file_type().await) {
				(Ok(name), Ok(kind)) if plain(&name) => found.push((name, kind)),
				(name, _) => {
					let name = name.unwrap_or_else(|n| n.to_string_lossy().into_owned());
					told.push(format!("roots {} left alone", directory.join(name).display()));
				}
			},
			Ok(None) => return found,
			Err(e) => {
				told.push(format!("roots {}: {e}", directory.display()));
				return found;
			}
		}
	}
}

/// Every root there is, its ids by its namespace, and a line for anything else found and left.
pub(super) async fn found(roots: &Roots) -> (BTreeMap<String, Vec<String>>, Vec<String>) {
	let mut told = Vec::new();
	let mut found: BTreeMap<String, Vec<String>> = BTreeMap::new();
	for (namespace, kind) in names(&roots.directory, &mut told).await {
		let directory = roots.directory.join(&namespace);
		if !kind.is_dir() {
			told.push(format!("roots {} is no namespace, left alone", directory.display()));
			continue;
		}
		let ids = found.entry(namespace).or_default();
		for (id, kind) in names(&directory, &mut told).await {
			match kind.is_symlink() {
				true => ids.push(id),
				false => {
					told.push(format!("roots {} is no link, left alone", directory.join(id).display()))
				}
			}
		}
	}
	(found, told)
}
