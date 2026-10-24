//! Each binding's list kept in a file of its own, `<state>/lists/<binding>.json`, written whole on
//! every change and read at start, as RFC 4elqc proposes and RFC n0o4l takes provisionally, what
//! was made of it found again on the disk.

use std::collections::BTreeMap;
use std::fs;
use std::io::Write as _;
use std::path::Path;

use driver_machine_management::Binding;
use envelope::contracts::{ManagementItem, ManagementState};
use envelope::{Encoded as _, Malformed};
use serde_json::{Value, json};

use crate::listed::found;
use crate::{Item, Listed};

/// A hash in lowercase hex.
fn hex(hash: &[u8; 32]) -> String {
	hash.iter().map(|b| format!("{b:02x}")).collect()
}

/// A hash from its hex, none where it is not 64 hex digits.
fn unhex(text: &str) -> Option<[u8; 32]> {
	let mut hash = [0u8; 32];
	if text.len() != 64 {
		return None;
	}
	for (byte, at) in hash.iter_mut().zip((0..64).step_by(2)) {
		*byte = u8::from_str_radix(text.get(at..at + 2)?, 16).ok()?;
	}
	Some(hash)
}

/// A list as its file holds it, each item in the contract's own JSON beside its state.
pub(crate) fn written(listed: &Listed) -> Value {
	let items: Vec<Value> = listed
		.items
		.iter()
		.map(|(id, item)| {
			let asked = ManagementItem {
				id: *id,
				capacity: item.capacity.clone(),
				credentials: item.credentials.clone(),
			};
			json!({ "item": asked.to_json(), "state": item.state.to_json(), "unasked": item.unasked })
		})
		.collect();
	let forgotten: Vec<String> = listed.forgotten.iter().map(hex).collect();
	json!({
		"generation": listed.generation,
		"policy": listed.policy,
		"grace": listed.grace,
		"items": items,
		"forgotten": forgotten,
	})
}

fn number(json: &Value, name: &str) -> Result<u64, String> {
	json.get(name).and_then(Value::as_u64).ok_or_else(|| format!("no number {name}"))
}

fn unread(why: &Malformed) -> String {
	format!("expected {}", why.expected)
}

/// The list a file holds, what the machine made of it found again from its items and the mount.
fn read_one(binding: Binding, json: &Value, mount: &Path) -> Result<Listed, String> {
	let mut listed = Listed::new(binding);
	listed.generation = number(json, "generation")?;
	listed.policy = number(json, "policy")?;
	listed.grace = u32::try_from(number(json, "grace")?).map_err(|e| format!("grace: {e}"))?;
	for kept in json.get("items").and_then(Value::as_array).ok_or("no list of items")? {
		let asked = ManagementItem::from_json(&kept["item"]).map_err(|why| unread(&why))?;
		let state = ManagementState::from_json(&kept["state"]).map_err(|why| unread(&why))?;
		let unasked = kept.get("unasked").and_then(Value::as_u64);
		let item = Item { capacity: asked.capacity, credentials: asked.credentials, state, unasked };
		listed.items.insert(asked.id, item);
	}
	for text in json.get("forgotten").and_then(Value::as_array).ok_or("no list forgotten")? {
		let hash = text.as_str().and_then(unhex).ok_or("a hash forgotten is 64 hex digits")?;
		listed.forgotten.insert(hash);
	}
	found(&mut listed, mount);
	Ok(listed)
}

/// The list written to its file through a new one renamed over it, so a crash leaves the old or the
/// new whole, each synced so a reboot finds it.
pub(crate) fn write(directory: &Path, listed: &Listed) -> Result<(), String> {
	let at = |path: &Path, e: std::io::Error| format!("{}: {e}", path.display());
	fs::create_dir_all(directory).map_err(|e| at(directory, e))?;
	let file = directory.join(format!("{}.json", listed.binding));
	let new = directory.join(format!("{}.json.new", listed.binding));
	let bytes = serde_json::to_vec_pretty(&written(listed)).map_err(|e| e.to_string())?;
	let mut out = fs::File::create(&new).map_err(|e| at(&new, e))?;
	out.write_all(&bytes).and_then(|()| out.sync_all()).map_err(|e| at(&new, e))?;
	fs::rename(&new, &file).map_err(|e| at(&file, e))?;
	fs::File::open(directory).and_then(|d| d.sync_all()).map_err(|e| at(directory, e))
}

/// Every list kept in the directory, by its binding, and each file not read and why; none kept
/// where the directory is not there yet. What was made on the workloads' mount is found there.
pub(crate) fn read(directory: &Path, mount: &Path) -> (BTreeMap<Binding, Listed>, Vec<String>) {
	let mut lists = BTreeMap::new();
	let mut unread = Vec::new();
	let Ok(entries) = fs::read_dir(directory) else { return (lists, unread) };
	for entry in entries.map_while(Result::ok) {
		let path = entry.path();
		let named = path.file_name().and_then(|n| n.to_str()).and_then(|n| n.strip_suffix(".json"));
		let Some(binding) = named.and_then(|n| n.parse::<Binding>().ok()) else { continue };
		let json = fs::read(&path)
			.map_err(|e| e.to_string())
			.and_then(|bytes| serde_json::from_slice::<Value>(&bytes).map_err(|e| e.to_string()));
		match json.and_then(|json| read_one(binding, &json, mount)) {
			Ok(listed) => {
				lists.insert(binding, listed);
			}
			Err(why) => unread.push(format!("{}: {why}", path.display())),
		}
	}
	(lists, unread)
}

#[cfg(test)]
mod tests {
	use std::path::PathBuf;
	use std::time::{SystemTime, UNIX_EPOCH};

	use envelope::contracts::{ManagementApply, ManagementItem, ManagementState};
	use envelope::{Bounded as _, Uint53};

	use super::{read, write, written};
	use crate::listed::tests::{Mount, container, machine, object};
	use crate::{Listed, Manage as _};

	/// A directory of its own under the system's temporary one, removed when dropped.
	struct Directory(PathBuf);

	impl Directory {
		fn new(name: &str) -> Self {
			let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
			let path = std::env::temp_dir().join(format!("kept-{name}-{}-{nanos}", std::process::id()));
			Self(path)
		}
	}

	impl Drop for Directory {
		fn drop(&mut self) {
			let _ = std::fs::remove_dir_all(&self.0);
		}
	}

	fn applied(
		listed: &mut Listed,
		mount: &Mount,
		generation: u64,
		items: Vec<ManagementItem>,
		now: u64,
	) {
		let input = ManagementApply {
			generation: Uint53::new(generation).unwrap(),
			items,
			tokens: None,
			adopted: None,
		};
		listed.apply(&input, &machine(), mount, now).unwrap();
	}

	#[test]
	fn a_list_written_is_read_back_whole_and_what_was_made_with_it() {
		let directory = Directory::new("whole");
		let mount = Mount::new("kept-whole");
		let mut listed = Listed::new(7);
		applied(&mut listed, &mount, 1, vec![container(1, 500), container(2, 250)], 1000);
		// The second unasked, so its time is kept too, and a token forgotten.
		applied(&mut listed, &mount, 2, vec![container(1, 500)], 2000);
		listed.forgotten.insert([9; 32]);
		write(&directory.0, &listed).unwrap();
		let (lists, unread) = read(&directory.0, &mount.path);
		assert_eq!(unread, Vec::<String>::new());
		let back = &lists[&7];
		assert_eq!(written(back), written(&listed));
		assert_eq!(back.items, listed.items);
		assert_eq!(back.items[&2].unasked, Some(2000));
		let made = back.made.as_ref().unwrap();
		assert_eq!((made.namespace.as_str(), made.qgroup.as_str()), ("b7", "1/7"));
		assert_eq!(back.made, listed.made);
		assert_eq!(made.capacities.keys().copied().collect::<Vec<_>>(), vec![1, 2]);
	}

	#[test]
	fn a_list_written_again_replaces_the_one_before_and_leaves_no_other_file() {
		let directory = Directory::new("again");
		let mount = Mount::new("kept-again");
		let mut listed = Listed::new(3);
		applied(&mut listed, &mount, 1, vec![container(1, 100)], 0);
		write(&directory.0, &listed).unwrap();
		applied(&mut listed, &mount, 2, vec![container(1, 200)], 0);
		write(&directory.0, &listed).unwrap();
		let names: Vec<_> = std::fs::read_dir(&directory.0)
			.unwrap()
			.map(|e| e.unwrap().file_name().into_string().unwrap())
			.collect();
		assert_eq!(names, vec!["3.json".to_owned()]);
		let (lists, _) = read(&directory.0, &mount.path);
		assert_eq!(lists[&3].generation, 2);
		assert_eq!(lists[&3].made.as_ref().unwrap().capacities[&1].millicores, 200);
	}

	#[test]
	fn a_bucket_made_is_opened_again_from_the_mount_its_list_names() {
		let directory = Directory::new("bucket");
		let mount = Mount::new("kept-bucket");
		let mut listed = Listed::new(4);
		applied(&mut listed, &mount, 1, vec![object(1, 1024)], 0);
		write(&directory.0, &listed).unwrap();
		drop(listed);
		let (lists, unread) = read(&directory.0, &mount.path);
		assert_eq!(unread, Vec::<String>::new());
		let (item, _) = lists[&4].bucket.as_ref().unwrap();
		assert_eq!(*item, 1);
		let (lists, _) = read(&directory.0, &mount.path.join("elsewhere"));
		assert!(lists[&4].bucket.is_none(), "no bucket is made where the mount holds none");
		let state = &lists[&4].items[&1].state;
		assert!(matches!(state, ManagementState::Failed { reason, .. } if reason == "fault"));
	}

	#[test]
	fn a_file_not_a_list_is_told_and_the_rest_are_read() {
		let directory = Directory::new("unread");
		let mount = Mount::new("kept-unread");
		let listed = Listed::new(1);
		write(&directory.0, &listed).unwrap();
		std::fs::write(directory.0.join("2.json"), b"{\"generation\": 1}").unwrap();
		std::fs::write(directory.0.join("notes.txt"), b"not a list").unwrap();
		let (lists, unread) = read(&directory.0, &mount.path);
		assert_eq!(lists.keys().copied().collect::<Vec<_>>(), vec![1]);
		assert!(lists[&1].made.is_none());
		assert!(matches!(&unread[..], [why] if why.contains("2.json")), "{unread:?}");
	}

	#[test]
	fn no_directory_is_no_list_and_no_failure() {
		let directory = Directory::new("none");
		let mount = Mount::new("kept-none");
		let (lists, unread) = read(&directory.0, &mount.path);
		assert!(lists.is_empty() && unread.is_empty());
	}

	#[test]
	fn a_list_asking_more_than_the_machine_holds_is_beyond_it_and_nothing_is_kept() {
		let mount = Mount::new("kept-beyond");
		let mut listed = Listed::new(5);
		let input = ManagementApply {
			generation: Uint53::new(1).unwrap(),
			items: vec![container(1, 3000), container(2, 2000)],
			tokens: None,
			adopted: None,
		};
		let refused = listed.apply(&input, &machine(), &mount, 0).unwrap_err();
		assert_eq!(refused.reason, "beyond_host");
		assert!(listed.items.is_empty() && listed.made.is_none());
		assert_eq!(listed.generation, 0);
	}
}
