//! `Containers` holding each container's runtime binary from the Nix store's collector by a root,
//! made with the container, removed with it, and reconciled at a start.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use common::{
	Driver, ECHO_TWO, Held, binding, deploy, driver, echo, id_of, lines, of, reason, shell, spec_of,
};
use driver_machine_container::{Deployments, Restart, Spec, Task};
use envelope::contracts::{DeploymentDeploy, DeploymentRuns, DeploymentRuntime};

/// Longer than any reconciling here takes.
const LONG: Duration = Duration::from_secs(30);

/// A runtime binary at a store path of its own in the test's store.
fn in_store(driver: &Driver, name: &str) -> PathBuf {
	let binary = driver.roots.store.join(format!("0000-{name}")).join("bin").join(name);
	std::fs::create_dir_all(binary.parent().unwrap()).unwrap();
	std::fs::write(&binary, b"").unwrap();
	binary
}

/// The store path a binary of [`in_store`] lies in.
fn store_path(driver: &Driver, name: &str) -> PathBuf {
	driver.roots.store.join(format!("0000-{name}"))
}

/// A stand-in for nix-store at the test's state, logging what it is run with beside it, which
/// links as `--add-root` does or else fails as told.
fn nix_store(driver: &Driver, fails: bool) -> PathBuf {
	let script = driver.state.join("nix-store");
	let then = match fails {
		true => "echo 'error: refused' >&2; exit 1",
		false => "ln -sfn \"$4\" \"$2\"",
	};
	written(&script, then);
	script
}

/// A stand-in for nix-store that never exits, its process's id written beside it.
fn nix_store_waiting(driver: &Driver) -> PathBuf {
	let script = driver.state.join("nix-store");
	written(&script, "echo $$ > \"$0.pid\"; exec sleep 60");
	script
}

/// A stand-in's script written and made runnable, logging what it is run with beside it.
fn written(script: &Path, then: &str) {
	use std::os::unix::fs::PermissionsExt;
	std::fs::write(script, format!("#!/bin/sh\necho \"$@\" >> \"$0.log\"\n{then}\n")).unwrap();
	std::fs::set_permissions(script, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// What a container's root holds, none where it has none.
fn root(driver: &Driver, namespace: &str, id: &str) -> Option<PathBuf> {
	std::fs::read_link(driver.roots.directory.join(namespace).join(id)).ok()
}

/// Every entry in the roots' directory and in each directory there, by its path below it.
fn entries(driver: &Driver) -> Vec<String> {
	let mut found = Vec::new();
	let Ok(namespaces) = std::fs::read_dir(&driver.roots.directory) else { return found };
	for namespace in namespaces {
		let namespace = namespace.unwrap().path();
		let name = namespace.file_name().unwrap().to_string_lossy().into_owned();
		found.push(name.clone());
		if namespace.is_dir() && !namespace.is_symlink() {
			for id in std::fs::read_dir(&namespace).unwrap() {
				found.push(format!("{name}/{}", id.unwrap().file_name().to_string_lossy()));
			}
		}
	}
	found.sort();
	found
}

/// A link made by hand in the roots' directory, as a root an earlier driver left.
fn linked(driver: &Driver, namespace: &str, id: &str, to: &Path) {
	let directory = driver.roots.directory.join(namespace);
	std::fs::create_dir_all(&directory).unwrap();
	std::os::unix::fs::symlink(to, directory.join(id)).unwrap();
}

#[tokio::test]
async fn a_container_made_is_given_a_root_of_the_binary_its_runtime_names() {
	let (mut driver, _) = driver("rooted", shell(), false);
	driver.runtimes.runc = in_store(&driver, "runc");
	driver.runtimes.crun = in_store(&driver, "crun");
	driver.deploy(&binding(), echo()).await.unwrap();
	let id = id_of(&driver, "00000001");
	assert_eq!(spec_of(&driver).binary, driver.runtimes.runc);
	assert_eq!(root(&driver, "b1", &id), Some(store_path(&driver, "runc")));
	let crun = DeploymentDeploy {
		runs: DeploymentRuns::App { id: 2 },
		runtime: Some(DeploymentRuntime::Crun),
		..echo()
	};
	driver.deploy(&binding(), crun).await.unwrap();
	let other = id_of(&driver, "00000002");
	assert_eq!(root(&driver, "b1", &other), Some(store_path(&driver, "crun")));
	assert_eq!(entries(&driver), ["b1".to_owned(), format!("b1/{id}"), format!("b1/{other}")]);
}

#[tokio::test]
async fn a_binary_linked_into_the_store_is_rooted_at_what_it_resolves_to() {
	let (mut driver, _) = driver("resolved", shell(), false);
	let binary = in_store(&driver, "runc");
	let named = driver.state.join("profile").join("runc");
	std::fs::create_dir_all(named.parent().unwrap()).unwrap();
	std::os::unix::fs::symlink(&binary, &named).unwrap();
	driver.runtimes.runc = named;
	driver.deploy(&binding(), echo()).await.unwrap();
	assert!(binary.starts_with(store_path(&driver, "runc")));
	assert_eq!(root(&driver, "b1", &id_of(&driver, "00000001")), Some(store_path(&driver, "runc")));
}

#[tokio::test]
async fn a_binary_outside_the_store_is_given_no_root_and_no_failure() {
	let (mut driver, _) = driver("outside", shell(), false);
	// One that is not there at all, as the fakes name, and one that is, beside the store.
	driver.deploy(&binding(), echo()).await.unwrap();
	let beside = driver.state.join("runc");
	std::fs::write(&beside, b"").unwrap();
	driver.runtimes.runc = beside;
	driver.deploy(&binding(), deploy("file:///echo-two.tar", ECHO_TWO)).await.unwrap();
	assert_eq!(entries(&driver), Vec::<String>::new());
	assert_eq!(driver.rooted(&["b1".into()], LONG).await, Vec::<String>::new());
	assert_eq!(entries(&driver), Vec::<String>::new());
}

#[tokio::test]
async fn a_container_removed_takes_its_root_and_an_emptied_namespace_its_directory() {
	let (mut driver, _) = driver("unrooted", shell(), false);
	driver.runtimes.runc = in_store(&driver, "runc");
	driver.deploy(&binding(), echo()).await.unwrap();
	let old = id_of(&driver, "00000001");
	// A new version made in its place takes the old one's root with the old one.
	driver.deploy(&binding(), deploy("file:///echo-two.tar", ECHO_TWO)).await.unwrap();
	let new = id_of(&driver, "00000001");
	assert_ne!(old, new);
	assert_eq!(entries(&driver), ["b1".to_owned(), format!("b1/{new}")]);
	driver.stop(&binding(), of()).await.unwrap();
	driver.delete(&binding(), of()).await.unwrap();
	assert_eq!(entries(&driver), Vec::<String>::new());
}

#[tokio::test]
async fn a_root_not_made_refuses_the_deploy_and_leaves_no_container() {
	let (mut driver, log) = driver("unrootable", shell(), false);
	driver.runtimes.runc = in_store(&driver, "runc");
	// The roots' directory is a file, so no directory can be made in it.
	std::fs::write(&driver.roots.directory, b"").unwrap();
	assert_eq!(reason(driver.deploy(&binding(), echo()).await.unwrap_err()), "fault");
	assert!(driver.containerd.held.lock().unwrap().is_empty());
	let log = lines(&log);
	assert!(log.iter().any(|l| l.starts_with("remove ")), "{log:?}");
	assert!(!log.iter().any(|l| l.starts_with("start ")), "{log:?}");
}

#[tokio::test]
async fn a_start_roots_what_was_made_before_and_removes_every_root_of_a_container_gone() {
	let (mut driver, _) = driver("reconciled", shell(), false);
	let binary = in_store(&driver, "runc");
	driver.runtimes.runc = binary.clone();
	driver.deploy(&binding(), echo()).await.unwrap();
	let id = id_of(&driver, "00000001");
	// Its root missing, as for a container made before roots were, and roots of containers gone.
	std::fs::remove_file(driver.roots.directory.join("b1").join(&id)).unwrap();
	linked(&driver, "b1", "gone-1", &binary);
	linked(&driver, "b9", "gone-2", &binary);
	// What no root is, which is left where it is.
	std::fs::write(driver.roots.directory.join("b1").join("notes"), b"").unwrap();
	let mut told = driver.rooted(&["b1".into()], LONG).await;
	told.sort();
	let notes = driver.roots.directory.join("b1").join("notes");
	assert_eq!(
		told,
		[
			format!("rooted b1 {id} at {}", store_path(&driver, "runc").display()),
			format!("roots {} is no link, left alone", notes.display()),
			"unrooted b1 gone-1".to_owned(),
			"unrooted b9 gone-2".to_owned(),
		]
	);
	assert_eq!(root(&driver, "b1", &id), Some(store_path(&driver, "runc")));
	assert_eq!(entries(&driver), ["b1".to_owned(), format!("b1/{id}"), "b1/notes".to_owned()]);
	// Once reconciled, a start again changes nothing.
	assert_eq!(
		driver.rooted(&["b1".into()], LONG).await,
		[format!("roots {} is no link, left alone", notes.display())]
	);
}

#[tokio::test]
async fn a_live_root_in_a_namespace_not_named_is_kept() {
	let (mut driver, _) = driver("root-unnamed", shell(), false);
	let binary = in_store(&driver, "runc");
	driver.runtimes.runc = binary.clone();
	driver.deploy(&binding(), echo()).await.unwrap();
	let id = id_of(&driver, "00000001");
	assert_eq!(driver.rooted(&[], LONG).await, Vec::<String>::new());
	assert!(binary.starts_with(store_path(&driver, "runc")));
	assert_eq!(root(&driver, "b1", &id), Some(store_path(&driver, "runc")));
}

#[tokio::test]
async fn a_namespace_whose_containers_are_not_listed_keeps_its_roots() {
	let (mut driver, _) = driver("unlisted", shell(), false);
	let binary = in_store(&driver, "runc");
	driver.runtimes.runc = binary.clone();
	linked(&driver, "b2", "kept", &binary);
	driver.containerd.unlistable.lock().unwrap().push("b2".into());
	let told = driver.rooted(&[], LONG).await;
	assert_eq!(told, ["roots b2 kept, its containers not listed, b2 is not listed"]);
	assert_eq!(root(&driver, "b2", "kept"), Some(binary));
}

#[tokio::test]
async fn a_container_whose_store_binary_is_gone_is_told_and_given_no_root() {
	let (mut driver, _) = driver("collected", shell(), false);
	let binary = in_store(&driver, "runc");
	driver.runtimes.runc = binary.clone();
	driver.deploy(&binding(), echo()).await.unwrap();
	let id = id_of(&driver, "00000001");
	// Collected before its root was made, as on a machine before this driver.
	std::fs::remove_file(driver.roots.directory.join("b1").join(&id)).unwrap();
	let collected = store_path(&driver, "runc");
	assert!(binary.starts_with(&collected));
	std::fs::remove_dir_all(&collected).unwrap();
	let told = driver.rooted(&["b1".into()], LONG).await;
	let [line] = told.as_slice() else { panic!("{told:?}") };
	assert!(line.starts_with(&format!("root b1 {id} not made, {}: ", collected.display())), "{line}");
	assert_eq!(entries(&driver), Vec::<String>::new());
}

#[tokio::test]
async fn a_root_whose_container_another_driver_makes_meanwhile_is_kept() {
	let (mut driver, _) = driver("arriving", shell(), false);
	let binary = in_store(&driver, "runc");
	driver.runtimes.runc = binary.clone();
	driver.deploy(&binding(), echo()).await.unwrap();
	let spec = spec_of(&driver);
	// Its root made, and its container listed only from the second list on, as conform's made it.
	linked(&driver, "b1", "late-1", &store_path(&driver, "runc"));
	let late = Spec { id: "late-1".into(), ..spec.clone() };
	let held = Held { labels: spec.labels, task: Some(Task::Running), spec: late };
	*driver.containerd.arriving.lock().unwrap() = Some((("b1".into(), "late-1".into()), held));
	assert_eq!(driver.rooted(&["b1".into()], LONG).await, Vec::<String>::new());
	assert_eq!(root(&driver, "b1", "late-1"), Some(store_path(&driver, "runc")));
}

#[tokio::test]
async fn nix_store_makes_the_root_where_it_is_given() {
	let (mut driver, _) = driver("nix-store", shell(), false);
	driver.runtimes.runc = in_store(&driver, "runc");
	let nix = nix_store(&driver, false);
	driver.roots.nix = Some(nix.clone());
	driver.deploy(&binding(), echo()).await.unwrap();
	let id = id_of(&driver, "00000001");
	let link = driver.roots.directory.join("b1").join(&id);
	let target = store_path(&driver, "runc");
	assert_eq!(root(&driver, "b1", &id), Some(target.clone()));
	let ran = std::fs::read_to_string(driver.state.join("nix-store.log")).unwrap();
	assert_eq!(ran, format!("--add-root {} --realise {}\n", link.display(), target.display()));
	// A root already holding the path is not made again.
	assert_eq!(driver.rooted(&["b1".into()], LONG).await, Vec::<String>::new());
	assert_eq!(std::fs::read_to_string(driver.state.join("nix-store.log")).unwrap(), ran);
}

#[tokio::test]
async fn a_root_nix_store_refuses_refuses_the_deploy_with_what_it_said() {
	let (mut driver, _) = driver("nix-store-refused", shell(), false);
	driver.runtimes.runc = in_store(&driver, "runc");
	driver.roots.nix = Some(nix_store(&driver, true));
	let refused = driver.deploy(&binding(), echo()).await.unwrap_err();
	assert_eq!(refused.reason, "fault");
	assert!(refused.message.unwrap().ends_with(": error: refused"));
	assert!(driver.containerd.held.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_binary_named_in_the_store_is_rooted_by_that_name_wherever_it_resolves() {
	let (mut driver, _) = driver("root-named", shell(), false);
	let outside = driver.state.join("runc");
	std::fs::write(&outside, b"").unwrap();
	let named = store_path(&driver, "wrapped").join("bin").join("runc");
	std::fs::create_dir_all(named.parent().unwrap()).unwrap();
	std::os::unix::fs::symlink(&outside, &named).unwrap();
	driver.runtimes.runc = named;
	driver.deploy(&binding(), echo()).await.unwrap();
	assert_eq!(
		root(&driver, "b1", &id_of(&driver, "00000001")),
		Some(store_path(&driver, "wrapped"))
	);
}

/// Whether a process has ended, gone or left a zombie, asked of ps for up to two seconds.
fn ended(pid: &str) -> bool {
	let until = Instant::now() + Duration::from_secs(2);
	loop {
		let ps = std::process::Command::new("ps").args(["-o", "stat=", "-p", pid]).output().unwrap();
		let stat = String::from_utf8_lossy(&ps.stdout).trim().to_owned();
		if stat.is_empty() || stat.starts_with('Z') {
			return true;
		}
		if Instant::now() >= until {
			return false;
		}
		std::thread::sleep(Duration::from_millis(50));
	}
}

#[tokio::test]
async fn a_nix_store_that_never_exits_is_killed_and_neither_a_deploy_nor_a_start_waits_on_it() {
	let (mut driver, _) = driver("nix-store-waiting", shell(), false);
	driver.runtimes.runc = in_store(&driver, "runc");
	driver.deploy(&binding(), echo()).await.unwrap();
	let id = id_of(&driver, "00000001");
	// Its root gone, so a start asks nix-store for it again.
	std::fs::remove_file(driver.roots.directory.join("b1").join(&id)).unwrap();
	driver.roots.nix = Some(nix_store_waiting(&driver));
	let began = Instant::now();
	let told = driver.rooted(&["b1".into()], LONG).await;
	assert!(began.elapsed() < Duration::from_secs(5), "{:?}", began.elapsed());
	let [line] = told.as_slice() else { panic!("{told:?}") };
	assert!(line.starts_with(&format!("root b1 {id} not made, ")), "{line}");
	assert!(line.ends_with("killed, not done within 500 ms"), "{line}");
	let pid = std::fs::read_to_string(driver.state.join("nix-store.pid")).unwrap();
	assert!(ended(pid.trim()), "nix-store {pid} still runs");
	// A deploy's turn is bounded the same, and refused.
	let other = DeploymentDeploy { runs: DeploymentRuns::App { id: 2 }, ..echo() };
	let began = Instant::now();
	assert_eq!(reason(driver.deploy(&binding(), other).await.unwrap_err()), "fault");
	assert!(began.elapsed() < Duration::from_secs(5), "{:?}", began.elapsed());
}

#[tokio::test]
async fn a_start_reconciles_no_longer_than_it_is_given_and_says_what_it_left() {
	let (driver, _) = driver("wedged", shell(), false);
	*driver.containerd.wedged.lock().unwrap() = true;
	let began = Instant::now();
	let told = driver.rooted(&["b1".into(), "b2".into()], Duration::from_millis(300)).await;
	assert!(began.elapsed() < Duration::from_secs(5), "{:?}", began.elapsed());
	assert_eq!(told, ["roots not reconciled within 300 ms, b1 b2 left for the next start"]);
}
