//! The program started as a machine starts it, each binding's token in a file of its own, and
//! called over plain HTTP as a control calls it.

// What is here is all a test's, so the lints a test may break by are its helpers' as well.
#![cfg(test)]
#![allow(dead_code, reason = "each test file uses its own part of what is here")]

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::Value;

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// A binding's token, its secret 32 bytes of the binding's own character, the last zero bits.
pub fn token(binding: u32) -> String {
	let character = char::from(ALPHABET[usize::try_from(binding % 64).unwrap()]);
	format!("{binding}.{}A", character.to_string().repeat(42))
}

/// The program running, its address, every line it wrote to stderr, its directory, and how many
/// bindings it holds a token file of.
pub struct Started {
	child: Child,
	pub address: SocketAddr,
	lines: Receiver<String>,
	directory: PathBuf,
	bindings: u32,
}

impl Started {
	/// Started with a token file for each binding of 1 to `bindings`.
	pub fn with(name: &str, bindings: u32) -> Self {
		let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
		let directory = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
			.join(format!("driver-machine-{name}-{}-{nanos}", std::process::id()));
		std::fs::create_dir_all(&directory).unwrap();
		// The workloads' mount, and a btrfs keeping each subvolume as a marked directory of it.
		std::fs::create_dir_all(directory.join("data")).unwrap();
		std::fs::write(directory.join("data/.subvolume"), b"").unwrap();
		let btrfs = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("volume/tests/btrfs.sh");
		std::fs::copy(btrfs, directory.join("btrfs")).unwrap();
		let executable = std::os::unix::fs::PermissionsExt::from_mode(0o755);
		std::fs::set_permissions(directory.join("btrfs"), executable).unwrap();
		for binding in 1..=bindings {
			let file = directory.join(format!("binding-{binding}"));
			std::fs::write(&file, format!("{}\n", token(binding))).unwrap();
		}
		Self::in_directory(directory, bindings)
	}

	/// Stopped and started again on the same state and token files, as a restart of its service.
	pub fn restarted(mut self) -> Self {
		let _ = self.child.kill();
		let _ = self.child.wait();
		// The directory taken is the new one's, so dropping what it was removes none.
		let directory = std::mem::take(&mut self.directory);
		Self::in_directory(directory, self.bindings)
	}

	fn in_directory(directory: PathBuf, bindings: u32) -> Self {
		let mut command = Command::new(env!("CARGO_BIN_EXE_driver-machine"));
		for binding in 1..=bindings {
			command.arg("--bindings").arg(directory.join(format!("binding-{binding}")));
		}
		let at = |name: &str| directory.join(name);
		command
			.arg("--listen")
			.arg(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)).to_string())
			.args(["--state".as_ref(), at("state").as_os_str()])
			.args(["--containerd".as_ref(), at("containerd.sock").as_os_str()])
			.args(["--runc".as_ref(), at("runc").as_os_str()])
			.args(["--crun".as_ref(), at("crun").as_os_str()])
			.args(["--youki".as_ref(), at("youki").as_os_str()])
			.args(["--plugins".as_ref(), at("plugins").as_os_str()])
			.args(["--bridge", "tested", "--subnet", "unused", "--entry", "4321"])
			.args(["--mount".as_ref(), at("data").as_os_str()])
			.args(["--btrfs".as_ref(), at("btrfs").as_os_str()])
			.args(["--secrets".as_ref(), at("secrets").as_os_str()])
			.args(["--largest", "1048576"])
			.stderr(Stdio::piped());
		let mut child = command.spawn().unwrap();
		let (send, lines) = channel();
		let stderr = BufReader::new(child.stderr.take().unwrap());
		std::thread::spawn(move || {
			for line in stderr.lines().map_while(Result::ok) {
				if send.send(line).is_err() {
					break;
				}
			}
		});
		let address = SocketAddr::from((Ipv4Addr::LOCALHOST, 0));
		let mut started = Self { child, address, lines, directory, bindings };
		let listening = started.logged("listening on ");
		started.address = listening.trim_start_matches("listening on ").parse().unwrap();
		started
	}

	/// The mount the workloads' btrfs lies on.
	pub fn mount(&self) -> PathBuf {
		self.directory.join("data")
	}

	/// The first line written from now on that holds `wanted`, waited on for five seconds.
	pub fn logged(&self, wanted: &str) -> String {
		let until = Instant::now() + Duration::from_secs(5);
		loop {
			let left = until.saturating_duration_since(Instant::now());
			let line =
				self.lines.recv_timeout(left).unwrap_or_else(|_| panic!("no line holds {wanted:?}"));
			if line.contains(wanted) {
				return line;
			}
		}
	}

	/// A request sent as written, and its status, headers and body.
	pub fn request(&self, method: &str, path: &str, headers: &[(&str, &str)], body: &[u8]) -> Reply {
		let mut stream = TcpStream::connect(self.address).unwrap();
		let mut head = format!("{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n");
		for (name, value) in headers {
			head.push_str(&format!("{name}: {value}\r\n"));
		}
		head.push_str(&format!("Content-Length: {}\r\n\r\n", body.len()));
		stream.write_all(head.as_bytes()).unwrap();
		stream.write_all(body).unwrap();
		let mut read = Vec::new();
		stream.read_to_end(&mut read).unwrap();
		let split = read.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
		let head = String::from_utf8(read[..split].to_vec()).unwrap();
		let status = head.split(' ').nth(1).unwrap().parse().unwrap();
		Reply { status, head, body: read[split + 4..].to_vec() }
	}

	/// A call in JSON with a binding's token, its body the call of `interface` and `operation`.
	pub fn call(
		&self,
		binding: u32,
		interface: &str,
		operation: &str,
		input: &Value,
	) -> (u16, Value) {
		let body =
			serde_json::json!({ "interface": interface, "operation": operation, "input": input });
		let token = format!("Bearer {}", token(binding));
		let headers = [("Authorization", token.as_str()), ("Content-Type", "application/json")];
		let reply = self.request(
			"POST",
			&format!("/{interface}/{operation}"),
			&headers,
			&serde_json::to_vec(&body).unwrap(),
		);
		(reply.status, reply.json())
	}
}

impl Drop for Started {
	fn drop(&mut self) {
		let _ = self.child.kill();
		let _ = self.child.wait();
		if !self.directory.as_os_str().is_empty() {
			let _ = std::fs::remove_dir_all(&self.directory);
		}
	}
}

/// What a request was answered.
pub struct Reply {
	pub status: u16,
	pub head: String,
	pub body: Vec<u8>,
}

impl Reply {
	pub fn json(&self) -> Value {
		serde_json::from_slice(&self.body).unwrap()
	}

	/// Whether its head names the content type.
	pub fn typed(&self, media: &str) -> bool {
		self.head.lines().any(|l| l.eq_ignore_ascii_case(&format!("content-type: {media}")))
	}
}

/// A sample of `../platform/tests/kinds/` read as it stands, by its path from this repository.
pub fn sample(path: &str) -> Value {
	let file = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join(path);
	serde_json::from_slice(&std::fs::read(file).unwrap()).unwrap()
}

/// Whether an expected value is `{"$absent": null}`.
pub fn absent(expected: &Value) -> bool {
	expected.as_object().is_some_and(|o| o.contains_key("$absent"))
}

/// Whether a value is as a sample expects it, `{"$any": null}` any value, `{"$absent": null}` a
/// key left out, an object at least the keys it writes, as platform's runner reads one, RFC p8e8k.
pub fn matches(expected: &Value, actual: &Value) -> bool {
	match (expected, actual) {
		(Value::Object(e), _) if e.contains_key("$any") => true,
		(Value::Object(e), Value::Object(a)) => e.iter().all(|(k, v)| match a.get(k) {
			Some(w) => matches(v, w),
			None => absent(v),
		}),
		(Value::Array(e), Value::Array(a)) => {
			e.len() == a.len() && e.iter().zip(a).all(|(v, w)| matches(v, w))
		}
		_ => expected == actual,
	}
}

/// Whether an answer is as a step expects, its output or its failure and reason.
pub fn answered(expect: &Value, answer: &Value) -> bool {
	match expect.get("output") {
		Some(output) => answer["status"] == "success" && matches(output, &answer["data"]),
		None => {
			answer["status"] == "error"
				&& answer["failure"] == expect["failure"]
				&& answer["reason"] == expect["reason"]
		}
	}
}
