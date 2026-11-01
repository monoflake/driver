//! `driver-machine check` and `snapshot` started as the updater starts them, against the driver and
//! the entry themselves, systemctl a script, and a stand-in for what a test cannot make the driver
//! answer without containerd.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

mod common;

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use common::{Started, token};

const VERSION: &str = concat!("driver-machine/", env!("CARGO_PKG_VERSION"));

/// A directory of its own, removed when dropped.
struct Directory(PathBuf);

impl Directory {
	fn new(name: &str) -> Self {
		let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
		let path = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
			.join(format!("health-{name}-{}-{nanos}", std::process::id()));
		std::fs::create_dir_all(&path).unwrap();
		Self(path)
	}

	/// A systemctl that shows each line of `shows` in turn, the last again from then on.
	fn systemctl(&self, shows: &[&str]) -> PathBuf {
		let counted = self.0.join("count");
		std::fs::write(&counted, "0").unwrap();
		let mut cases = String::new();
		for (at, show) in shows.iter().enumerate() {
			cases.push_str(&format!("{at}) printf '%s\\n' '{}' ;;\n", show.replace(' ', "' '")));
		}
		let last = shows.last().unwrap().replace(' ', "' '");
		let script = format!(
			"#!/bin/sh\nc=$(cat {count})\necho $((c + 1)) > {count}\ncase $c in\n{cases}*) printf '%s\\n' '{last}' ;;\nesac\n",
			count = counted.display(),
		);
		let path = self.0.join("systemctl");
		let staged = self.0.join("systemctl.new");
		std::fs::write(&staged, script).unwrap();
		let executable = std::os::unix::fs::PermissionsExt::from_mode(0o755);
		std::fs::set_permissions(&staged, executable).unwrap();
		std::fs::rename(&staged, &path).unwrap();
		path
	}

	fn file(&self, name: &str, text: &str) -> PathBuf {
		let path = self.0.join(name);
		std::fs::write(&path, text).unwrap();
		path
	}
}

impl Drop for Directory {
	fn drop(&mut self) {
		let _ = std::fs::remove_dir_all(&self.0);
	}
}

const HEALTHY: &str = "ActiveState=active MainPID=7 NRestarts=0";

/// The entry alone, as its own unit starts it, and its address.
struct Entry {
	child: Child,
	address: SocketAddr,
	/// Its stderr held open, as a line written to one closed ends it.
	_lines: std::io::Lines<BufReader<std::process::ChildStderr>>,
}

impl Entry {
	fn started(directory: &Directory) -> Self {
		let mut child = Command::new(env!("CARGO_BIN_EXE_driver-machine"))
			.args(["entry", "--listen", "127.0.0.1:0", "--subnet", "192.0.2.0/24", "--containerd"])
			.arg(directory.0.join("no-containerd.sock"))
			.stderr(Stdio::piped())
			.spawn()
			.unwrap();
		let mut lines = BufReader::new(child.stderr.take().unwrap()).lines();
		let first = lines.next().unwrap().unwrap();
		let address = first.trim_start_matches("entry on ").parse().unwrap();
		Self { child, address, _lines: lines }
	}
}

impl Drop for Entry {
	fn drop(&mut self) {
		let _ = self.child.kill();
		let _ = self.child.wait();
	}
}

/// An address nothing listens at.
fn closed() -> SocketAddr {
	let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
	listener.local_addr().unwrap()
}

/// A driver answering each `deployments describe` by the state `states` gives its id, and as
/// `served` names itself.
fn stand_in(served: &'static str, states: &'static [(u64, &'static str)]) -> SocketAddr {
	let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
	let address = listener.local_addr().unwrap();
	std::thread::spawn(move || {
		for stream in listener.incoming() {
			let mut stream = stream.unwrap();
			let mut read = Vec::new();
			let mut buffer = [0u8; 4096];
			let body = loop {
				let n = stream.read(&mut buffer).unwrap();
				read.extend_from_slice(&buffer[..n]);
				let Some(at) = read.windows(4).position(|w| w == b"\r\n\r\n") else { continue };
				let head = String::from_utf8_lossy(&read[..at]).to_ascii_lowercase();
				let length: usize = head
					.lines()
					.find_map(|l| l.strip_prefix("content-length: "))
					.map_or(0, |v| v.trim().parse().unwrap());
				if read.len() >= at + 4 + length {
					break read[at + 4..at + 4 + length].to_vec();
				}
			};
			let call: serde_json::Value = serde_json::from_slice(&body).unwrap();
			let answer = if call["interface"] == "management" {
				serde_json::json!({"status": "success", "data": {}})
			} else {
				let id = call["input"]["runs"]["id"].as_u64().unwrap();
				match states.iter().find(|(i, _)| *i == id) {
					Some((_, state)) => {
						serde_json::json!({"status": "success", "data": {"state": {"name": state}}})
					}
					None => serde_json::json!({"status": "error", "failure": "rejected", "reason": "not_found", "message": "none"}),
				}
			}
			.to_string();
			let reply = format!(
				"HTTP/1.1 200 OK\r\nServer: {served}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{answer}",
				answer.len()
			);
			let _ = stream.write_all(reply.as_bytes());
		}
	});
	address
}

/// `check` run with the given reach and bounds of a second each, its output whole.
fn check(
	directory: &Directory,
	systemctl: &Path,
	driver: SocketAddr,
	entry: SocketAddr,
	tokens: &[PathBuf],
	snapshot: Option<&Path>,
) -> Output {
	settled_check(directory, systemctl, driver, entry, tokens, snapshot, 1)
}

/// `check` with a settle of its own, which at zero reads each service exactly twice before level 2.
fn settled_check(
	directory: &Directory,
	systemctl: &Path,
	driver: SocketAddr,
	entry: SocketAddr,
	tokens: &[PathBuf],
	snapshot: Option<&Path>,
	settle: u64,
) -> Output {
	let mut command = Command::new(env!("CARGO_BIN_EXE_driver-machine"));
	command.arg("check");
	if let Some(snapshot) = snapshot {
		command.arg(snapshot);
	}
	for token in tokens {
		command.arg(format!("--bindings={}", token.display()));
	}
	command
		.arg(format!("--driver={driver}"))
		.arg(format!("--entry={entry}"))
		.arg(format!("--state={}", directory.0.join("state").display()))
		.arg(format!("--systemctl={}", systemctl.display()))
		.arg(format!("--settle={settle}"))
		.args(["--answering=1", "--matching=1"]);
	command.output().unwrap()
}

fn said(output: &Output) -> String {
	String::from_utf8_lossy(&output.stderr).into_owned()
}

/// The driver with a binding, the entry, and a binding's token in a file of its own.
fn whole(directory: &Directory) -> (Started, Entry, Vec<PathBuf>) {
	let driver = Started::with("health", 1);
	let entry = Entry::started(directory);
	let token = directory.file("binding", &format!("{}\n", token(1)));
	(driver, entry, vec![token])
}

#[test]
fn a_healthy_update_passes_and_with_no_snapshot_says_level_3_is_skipped() {
	let directory = Directory::new("healthy");
	let (driver, entry, tokens) = whole(&directory);
	let systemctl = directory.systemctl(&[HEALTHY]);
	let output = check(&directory, &systemctl, driver.address, entry.address, &tokens, None);
	let text = said(&output);
	assert!(output.status.success(), "{text}");
	assert!(text.contains("level 1 passed"), "{text}");
	assert!(text.contains("level 2 passed"), "{text}");
	assert!(text.contains("level 3 skipped, no snapshot"), "{text}");
	assert!(text.ends_with("check: passed\n"), "{text}");
}

#[test]
fn level_1_fails_on_a_service_not_active() {
	let directory = Directory::new("inactive");
	let (driver, entry, tokens) = whole(&directory);
	let systemctl = directory.systemctl(&["ActiveState=activating MainPID=0 NRestarts=1"]);
	let output = check(&directory, &systemctl, driver.address, entry.address, &tokens, None);
	let text = said(&output);
	assert_eq!(output.status.code(), Some(1), "{text}");
	assert!(text.contains("level 1, driver-machine.service is activating"), "{text}");
}

#[test]
fn level_1_fails_on_a_service_that_restarted_within_the_settle() {
	let directory = Directory::new("restarted");
	let (driver, entry, tokens) = whole(&directory);
	// Each read is of both services, so the third is the driver's second read.
	let systemctl =
		directory.systemctl(&[HEALTHY, HEALTHY, "ActiveState=active MainPID=9 NRestarts=1"]);
	let output = check(&directory, &systemctl, driver.address, entry.address, &tokens, None);
	let text = said(&output);
	assert_eq!(output.status.code(), Some(1), "{text}");
	assert!(text.contains("level 1, driver-machine.service restarted"), "{text}");
}

#[test]
fn level_1_fails_on_a_crash_during_the_later_levels() {
	let directory = Directory::new("late");
	let (driver, entry, tokens) = whole(&directory);
	// Both services read twice in a settle of nothing, so the fifth read is the last level's own.
	let mut shows = vec![HEALTHY; 4];
	shows.push("ActiveState=active MainPID=9 NRestarts=1");
	let systemctl = directory.systemctl(&shows);
	let output =
		settled_check(&directory, &systemctl, driver.address, entry.address, &tokens, None, 0);
	let text = said(&output);
	assert_eq!(output.status.code(), Some(1), "{text}");
	assert!(text.contains("level 2 passed"), "{text}");
	assert!(text.contains("level 1, driver-machine.service restarted"), "{text}");
}

#[test]
fn level_2_fails_where_the_driver_never_answers() {
	let directory = Directory::new("silent");
	let (_driver, entry, tokens) = whole(&directory);
	let systemctl = directory.systemctl(&[HEALTHY]);
	// A port that accepts and answers nothing, as a build that never answers.
	let silent = TcpListener::bind(("127.0.0.1", 0)).unwrap();
	let address = silent.local_addr().unwrap();
	let began = Instant::now();
	let output = check(&directory, &systemctl, address, entry.address, &tokens, None);
	let text = said(&output);
	assert_eq!(output.status.code(), Some(1), "{text}");
	assert!(text.contains("level 2, no answer"), "{text}");
	assert!(began.elapsed() < Duration::from_secs(30), "bounded");
	drop(silent);
}

#[test]
fn level_2_fails_where_the_driver_answers_as_another_version() {
	let directory = Directory::new("version");
	let entry = Entry::started(&directory);
	let systemctl = directory.systemctl(&[HEALTHY]);
	let token = directory.file("binding", &format!("{}\n", token(1)));
	let old = stand_in("driver-machine/0.0.1", &[]);
	let output = check(&directory, &systemctl, old, entry.address, &[token], None);
	let text = said(&output);
	assert_eq!(output.status.code(), Some(1), "{text}");
	assert!(text.contains("the driver answered as driver-machine/0.0.1"), "{text}");
}

#[test]
fn level_2_fails_where_the_entry_never_answers() {
	let directory = Directory::new("entry");
	let (driver, _entry, tokens) = whole(&directory);
	let systemctl = directory.systemctl(&[HEALTHY]);
	let output = check(&directory, &systemctl, driver.address, closed(), &tokens, None);
	let text = said(&output);
	assert_eq!(output.status.code(), Some(1), "{text}");
	assert!(text.contains("level 2, the entry did not answer"), "{text}");
}

#[test]
fn level_2_fails_where_a_live_token_is_denied() {
	let directory = Directory::new("denied");
	let (driver, entry, _) = whole(&directory);
	let systemctl = directory.systemctl(&[HEALTHY]);
	// A live token of a binding the driver was not started with is the driver denying a live one.
	let stranger = directory.file("stranger", &format!("{}\n", token(2)));
	let output = check(&directory, &systemctl, driver.address, entry.address, &[stranger], None);
	let text = said(&output);
	assert_eq!(output.status.code(), Some(1), "{text}");
	assert!(text.contains("level 2, describe answered 403"), "{text}");
}

#[test]
fn level_2_passes_on_a_denial_with_no_token_held() {
	let directory = Directory::new("bare");
	let (driver, entry, _) = whole(&directory);
	let systemctl = directory.systemctl(&[HEALTHY]);
	let output = check(&directory, &systemctl, driver.address, entry.address, &[], None);
	assert!(output.status.success(), "{}", said(&output));
}

const BASELINE: &str = r#"{"deployments":[
	{"binding":1,"id":10,"state":"running"},
	{"binding":1,"id":11,"state":"stopped"}
]}"#;

#[test]
fn level_3_passes_where_every_deployment_matches() {
	let directory = Directory::new("matches");
	let entry = Entry::started(&directory);
	let systemctl = directory.systemctl(&[HEALTHY]);
	let token = directory.file("binding", &format!("{}\n", token(1)));
	let snapshot = directory.file("snapshot", BASELINE);
	let driver = stand_in(VERSION, &[(10, "running"), (11, "stopped"), (12, "making")]);
	let output = check(&directory, &systemctl, driver, entry.address, &[token], Some(&snapshot));
	let text = said(&output);
	assert!(output.status.success(), "{text}");
	assert!(text.contains("level 3 passed, 2 deployments"), "{text}");
}

#[test]
fn level_3_fails_where_a_deployment_is_lost_or_its_state_moved() {
	let lost: &[(u64, &str)] = &[(11, "stopped")];
	let moved: &[(u64, &str)] = &[(10, "running"), (11, "running")];
	for (name, states, wanted) in [
		("lost", lost, "0000000a of binding 1 was running and is absent"),
		("moved", moved, "0000000b of binding 1 was stopped and is running"),
	] {
		let directory = Directory::new(name);
		let entry = Entry::started(&directory);
		let systemctl = directory.systemctl(&[HEALTHY]);
		let token = directory.file("binding", &format!("{}\n", token(1)));
		let snapshot = directory.file("snapshot", BASELINE);
		let driver = stand_in(VERSION, states);
		let output = check(&directory, &systemctl, driver, entry.address, &[token], Some(&snapshot));
		let text = said(&output);
		assert_eq!(output.status.code(), Some(1), "{text}");
		assert!(text.contains(&format!("level 3, deployment {wanted}")), "{text}");
	}
}

#[test]
fn a_snapshot_that_cannot_be_read_fails_before_anything_is_waited_on() {
	let directory = Directory::new("unread");
	let snapshot = directory.file("snapshot", "{");
	let systemctl = directory.systemctl(&[HEALTHY]);
	let output = check(&directory, &systemctl, closed(), closed(), &[], Some(&snapshot));
	let text = said(&output);
	assert_eq!(output.status.code(), Some(1), "{text}");
	assert!(text.contains("level 3"), "{text}");
}

fn snapshot(directory: &Directory, state: &Path, file: &Path) -> Output {
	Command::new(env!("CARGO_BIN_EXE_driver-machine"))
		.arg("snapshot")
		.arg(file)
		.arg(format!("--state={}", state.display()))
		.arg(format!("--containerd={}", directory.0.join("no-containerd.sock").display()))
		.arg(format!("--driver={}", closed()))
		.output()
		.unwrap()
}

#[test]
fn a_snapshot_of_nothing_kept_writes_an_empty_baseline_check_reads() {
	let directory = Directory::new("nothing");
	let file = directory.0.join("snapshot");
	let output = snapshot(&directory, &directory.0.join("state"), &file);
	assert!(output.status.success(), "{}", said(&output));
	assert_eq!(std::fs::read_to_string(file).unwrap(), r#"{"deployments":[]}"#);
}

#[test]
fn a_snapshot_containerd_cannot_answer_exits_1_and_writes_nothing() {
	let directory = Directory::new("unreached");
	let state = directory.0.join("state");
	std::fs::create_dir_all(state.join("lists")).unwrap();
	std::fs::write(
		state.join("lists/1.json"),
		r#"{"generation":1,"policy":0,"grace":1,"items":[],"forgotten":[],"namespace":"b00000001"}"#,
	)
	.unwrap();
	let file = directory.0.join("snapshot");
	let output = snapshot(&directory, &state, &file);
	assert_eq!(output.status.code(), Some(1), "{}", said(&output));
	assert!(!file.exists());
}

/// How the updater tells a version with no snapshot from one whose snapshot failed, usage's exit.
#[test]
fn a_command_a_version_does_not_know_exits_2() {
	let output = Command::new(env!("CARGO_BIN_EXE_driver-machine"))
		.args(["no-such-command", "/nonexistent"])
		.output()
		.unwrap();
	assert_eq!(output.status.code(), Some(2), "{}", said(&output));
}

#[test]
fn every_answer_names_the_version_even_a_denial() {
	let driver = Started::with("named", 1);
	let reply = driver.request("POST", "/management/describe", &[], b"");
	assert_eq!(reply.status, 403);
	let wanted = format!("server: {VERSION}");
	assert!(reply.head.lines().any(|l| l.eq_ignore_ascii_case(&wanted)), "{}", reply.head);
}
