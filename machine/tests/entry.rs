//! `driver-machine entry` started alone, as its own unit starts it, with no driver beside it,
//! RFC rmll5.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::process::{Command, Stdio};

/// The status a request for `/` by a host is answered.
fn status(at: SocketAddr, host: &str) -> u16 {
	let mut stream = TcpStream::connect(at).unwrap();
	write!(stream, "GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n").unwrap();
	let mut read = String::new();
	stream.read_to_string(&mut read).unwrap();
	read.split(' ').nth(1).unwrap().parse().unwrap()
}

#[test]
fn the_entry_runs_alone_and_a_deployment_containerd_cannot_say_is_unavailable() {
	let missing = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join("no-containerd.sock");
	let mut child = Command::new(env!("CARGO_BIN_EXE_driver-machine"))
		.args(["entry", "--listen", "127.0.0.1:0", "--subnet", "192.0.2.0/24", "--containerd"])
		.arg(&missing)
		.stderr(Stdio::piped())
		.spawn()
		.unwrap();
	let mut lines = BufReader::new(child.stderr.take().unwrap()).lines();
	let first = lines.next().unwrap().unwrap();
	let at: SocketAddr = first.trim_start_matches("entry on ").parse().unwrap();
	assert_eq!(status(at, "localhost"), 404);
	assert_eq!(status(at, "0a1b2c3d.b1.local"), 503);
	assert_eq!(status(at, "app-1.b1.local"), 503);
	let _ = child.kill();
	let _ = child.wait();
}
