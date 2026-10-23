//! A binding's list held by generation, its grace and each item asked or unasked, as
//! `model/contracts/kinds/management.res` and its samples have it, RFC vr5lw, and what each item is
//! made of on the machine, RFC 4elqc's proposal as RFC 54q45 takes it.

use std::collections::{BTreeMap, BTreeSet};
use std::mem::discriminant;
use std::path::Path;
use std::sync::Arc;

use driver_machine_container::{Capacity, Refused};
use driver_machine_management::Binding;
use driver_machine_object::{Bucket, MOST, Open as _};
use driver_machine_volume::{BUCKETS, VOLUMES, Volume, place};
use envelope::contracts::{
	ManagementApply, ManagementCapacity, ManagementDescribed, ManagementEnd, ManagementEnded,
	ManagementHeld, ManagementHolding, ManagementItem, ManagementPolicy, ManagementState,
};
use envelope::{Bounded, Uint53};

use crate::{Item, Listed, Machine, Make, Manage};

/// The grace of a binding that set none, a week in seconds.
const WEEK: u32 = 604_800;

/// The longest grace, a year of 365 days in seconds.
const YEAR: u32 = 31_536_000;

impl Listed {
	/// A binding's list before anything is applied.
	pub(crate) const fn new(binding: Binding) -> Self {
		Self {
			binding,
			generation: 0,
			policy: 0,
			grace: WEEK,
			items: BTreeMap::new(),
			forgotten: BTreeSet::new(),
			made: None,
			bucket: None,
		}
	}
}

/// A binding's containerd namespace, `b<binding>`, as RFC 4elqc proposes, which the entry reads.
pub(crate) fn namespace(binding: Binding) -> String {
	format!("b{binding}")
}

/// What the machine makes of a binding, its namespace and its qgroup `1/<binding>`, as RFC 4elqc
/// proposes.
fn named(binding: Binding) -> driver_machine_container::Binding {
	driver_machine_container::Binding {
		namespace: namespace(binding),
		qgroup: driver_machine_volume::qgroup(binding),
		capacities: BTreeMap::new(),
	}
}

/// What a bucket's volume holds past its capacity, one content written beside the one it
/// replaces, and the index, RFC 4elqc.
fn room() -> u64 {
	u64::try_from(MOST).unwrap_or(u64::MAX)
}

fn failed(reason: &str, message: impl Into<String>) -> ManagementState {
	ManagementState::Failed { reason: reason.to_owned(), message: Some(message.into()) }
}

/// What the machine made of a list kept, found again from the disk at start, each `container` item
/// a container of capacity and the `object` item's bucket opened; an item made that is not found is
/// failed, so the next list makes it again.
pub(crate) fn found(listed: &mut Listed, mount: &Path) {
	let binding = listed.binding;
	let mut made = named(binding);
	for (id, item) in &mut listed.items {
		if !matches!(item.state, ManagementState::Made { .. }) {
			continue;
		}
		let volume = Volume { binding, item: *id };
		match &item.capacity {
			ManagementCapacity::Container { millicores, memory } => {
				made.capacities.insert(*id, Capacity { millicores: *millicores, memory: memory.get() });
			}
			ManagementCapacity::Volume { .. } => {
				if !place(mount, VOLUMES, volume).is_dir() {
					item.state = failed("fault", "its volume was not found again at start");
				}
			}
			ManagementCapacity::Object { size } => {
				let at = place(mount, BUCKETS, volume);
				// Opening makes a bucket where none is, so one gone is told rather than made empty.
				let opened = if at.is_dir() {
					Bucket::open(&at, Some(size.get())).map_err(|f| f.0)
				} else {
					Err("it was not found".to_owned())
				};
				match opened {
					Ok(bucket) => listed.bucket = Some((*id, Arc::new(bucket))),
					Err(why) => {
						item.state = failed("fault", format!("its bucket was not opened again, {why}"))
					}
				}
			}
			ManagementCapacity::Database { .. } => {}
		}
	}
	listed.made = (!made.capacities.is_empty()).then_some(made);
}

fn refused(reason: &'static str, message: impl Into<String>) -> Refused {
	Refused { reason, message: Some(message.into()) }
}

/// A generation or a time as the contract writes it, one past 2^53 a fault of the driver's.
fn uint53(value: u64) -> Result<Uint53, Refused> {
	Uint53::new(value).ok_or_else(|| refused("fault", format!("{value} is past 2^53")))
}

fn held(value: u64) -> Result<ManagementHeld, Refused> {
	Ok(ManagementHeld { generation: uint53(value)? })
}

/// A list naming each item once, each holding one credential, or two while one replaces the other.
fn valid(items: &[ManagementItem]) -> Result<(), Refused> {
	let mut seen = BTreeSet::new();
	for item in items {
		if !seen.insert(item.id) {
			return Err(refused("invalid", format!("the list names item {} twice", item.id)));
		}
		if !(1..=2).contains(&item.credentials.len()) {
			return Err(refused(
				"invalid",
				format!("item {} holds one credential, or two while one replaces the other", item.id),
			));
		}
	}
	Ok(())
}

/// The bytes a `volume` or an `object` item holds, none for the other kinds.
fn space(capacity: &ManagementCapacity) -> Option<u64> {
	match capacity {
		ManagementCapacity::Volume { size } | ManagementCapacity::Object { size } => Some(size.get()),
		ManagementCapacity::Container { .. } | ManagementCapacity::Database { .. } => None,
	}
}

impl Listed {
	/// Whether an item asked is held as it is, so nothing of it is made again; one failed is made
	/// again with every list.
	fn kept(&self, item: &ManagementItem) -> bool {
		self.items.get(&item.id).is_some_and(|held| {
			held.capacity == item.capacity && !matches!(held.state, ManagementState::Failed { .. })
		})
	}

	/// A list whose `container` items ask at most the machine's cores and memory, and whose
	/// `volume` and `object` items ask, past what is made of them, at most the free space of the
	/// workloads' btrfs, the bound RFC 4elqc proposes; what other bindings hold not yet counted.
	fn bounded(
		&self,
		items: &[ManagementItem],
		machine: &Machine,
		make: &impl Make,
	) -> Result<(), Refused> {
		let (mut millicores, mut memory, mut wanted) = (0u64, 0u64, 0u64);
		for item in items {
			if let ManagementCapacity::Container { millicores: cores, memory: asked } = &item.capacity {
				millicores = millicores.saturating_add(u64::from(*cores));
				memory = memory.saturating_add(asked.get());
			}
			let made = self.items.get(&item.id).filter(|held| {
				discriminant(&held.capacity) == discriminant(&item.capacity)
					&& matches!(held.state, ManagementState::Made { .. })
			});
			let asked = space(&item.capacity).unwrap_or(0);
			let had = made.and_then(|held| space(&held.capacity)).unwrap_or(0);
			wanted = wanted.saturating_add(asked.saturating_sub(had));
		}
		if millicores > machine.millicores || memory > machine.memory {
			let (cores, bytes) = (machine.millicores, machine.memory);
			return Err(refused(
				"beyond_host",
				format!(
					"the list asks {millicores} millicores and {memory} bytes, the machine {cores} and {bytes}"
				),
			));
		}
		if wanted > 0 {
			let free = make.free().map_err(|why| refused("fault", why))?;
			if wanted > free {
				return Err(refused(
					"beyond_host",
					format!("the list asks {wanted} bytes more of btrfs, which has {free} free"),
				));
			}
		}
		Ok(())
	}

	/// An item made on the machine, its state; a failure is the item's own, never the list's.
	fn made(
		&mut self,
		item: &ManagementItem,
		machine: &Machine,
		make: &impl Make,
	) -> ManagementState {
		let binding = self.binding;
		let volume = Volume { binding, item: item.id };
		match &item.capacity {
			// The container kind applies the share as it creates each container.
			ManagementCapacity::Container { millicores, memory } => {
				let made = self.made.get_or_insert_with(|| named(binding));
				made.capacities.insert(item.id, Capacity { millicores: *millicores, memory: memory.get() });
				ManagementState::Made { address: machine.address.clone() }
			}
			ManagementCapacity::Volume { size } => match make.volume(VOLUMES, volume, size.get()) {
				Ok(at) => ManagementState::Made { address: at.display().to_string() },
				Err(why) => failed("fault", why),
			},
			ManagementCapacity::Object { size } => self.bucketed(item.id, size.get(), machine, make),
			// Refused before anything of the list is made, in `apply`.
			ManagementCapacity::Database { .. } => todo!("4elqc"),
		}
	}

	/// The binding's one bucket made of an `object` item, a volume past its capacity by
	/// [`room`], every `object` call of the binding's token reaching it, RFC 4elqc.
	fn bucketed(
		&mut self,
		id: u32,
		size: u64,
		machine: &Machine,
		make: &impl Make,
	) -> ManagementState {
		if let Some((other, _)) = &self.bucket
			&& *other != id
		{
			let message = format!(
				"the binding holds one bucket, item {other}'s, until a call names its bucket, RFC 4elqc"
			);
			return failed("beyond_host", message);
		}
		let volume = Volume { binding: self.binding, item: id };
		let at = match make.volume(BUCKETS, volume, size.saturating_add(room())) {
			Ok(at) => at,
			Err(why) => return failed("fault", why),
		};
		match &self.bucket {
			Some((_, bucket)) => bucket.resize(Some(size)),
			None => match Bucket::open(&at, Some(size)) {
				Ok(bucket) => self.bucket = Some((id, Arc::new(bucket))),
				Err(f) => return failed("fault", f.0),
			},
		}
		ManagementState::Made { address: machine.address.clone() }
	}

	/// What the machine made of an item removed, its volume or bucket, or its containers and
	/// capacity; the item stays where any of it fails, so a call after removes it.
	fn unmade(&mut self, id: u32, make: &impl Make) -> Result<(), Refused> {
		let Some(item) = self.items.get(&id) else { return Ok(()) };
		let volume = Volume { binding: self.binding, item: id };
		let fault = |why: String| refused("fault", why);
		match &item.capacity {
			ManagementCapacity::Container { .. } => {
				if let Some(made) = self.made.as_mut() {
					make.emptied(made, id).map_err(fault)?;
					made.capacities.remove(&id);
					if made.capacities.is_empty() {
						self.made = None;
					}
				}
			}
			ManagementCapacity::Volume { .. } => make.unvolume(VOLUMES, volume).map_err(fault)?,
			ManagementCapacity::Object { .. } => {
				if self.bucket.as_ref().is_some_and(|(held, _)| *held == id) {
					self.bucket = None;
				}
				make.unvolume(BUCKETS, volume).map_err(fault)?;
			}
			ManagementCapacity::Database { .. } => {}
		}
		Ok(())
	}

	/// Each item removed and what was made of it, and the binding's qgroup once it holds none.
	fn removed(&mut self, ids: &[u32], make: &impl Make) -> Result<(), Refused> {
		for id in ids {
			self.unmade(*id, make)?;
			self.items.remove(id);
		}
		if !ids.is_empty() && self.items.is_empty() {
			make.released(self.binding);
		}
		Ok(())
	}

	/// Every item unasked past its grace removed; nothing sweeps but a call yet, where a timer
	/// would, RFC 4elqc item 4.
	fn swept(&mut self, now: u64, make: &impl Make) -> Result<(), Refused> {
		let grace = u64::from(self.grace).saturating_mul(1000);
		let past: Vec<u32> = self
			.items
			.iter()
			.filter(|(_, item)| item.unasked.is_some_and(|since| now >= since.saturating_add(grace)))
			.map(|(id, _)| *id)
			.collect();
		self.removed(&past, make)
	}
}

impl Manage for Listed {
	fn apply(
		&mut self,
		input: &ManagementApply,
		machine: &Machine,
		make: &impl Make,
		now: u64,
	) -> Result<ManagementHeld, Refused> {
		valid(&input.items)?;
		if input.generation.get() < self.generation {
			return held(self.generation);
		}
		self.bounded(&input.items, machine, make)?;
		let making: Vec<&ManagementItem> = input.items.iter().filter(|i| !self.kept(i)).collect();
		// A database waits for its block, RFC 4elqc, and nothing of the list is made before it.
		if making.iter().any(|i| matches!(i.capacity, ManagementCapacity::Database { .. })) {
			todo!("4elqc");
		}
		for item in making {
			let other = self.items.get(&item.id).map(|held| discriminant(&held.capacity));
			if other.is_some_and(|kind| kind != discriminant(&item.capacity)) {
				self.unmade(item.id, make)?;
			}
			let state = self.made(item, machine, make);
			self.items.insert(
				item.id,
				Item { capacity: item.capacity.clone(), credentials: Vec::new(), state, unasked: None },
			);
		}
		let asked: BTreeMap<u32, &ManagementItem> = input.items.iter().map(|i| (i.id, i)).collect();
		for (id, item) in &mut self.items {
			match asked.get(id) {
				Some(wanted) => {
					item.credentials.clone_from(&wanted.credentials);
					item.unasked = None;
				}
				None => item.unasked = item.unasked.or(Some(now)),
			}
		}
		self.generation = input.generation.get();
		self.swept(now, make)?;
		held(self.generation)
	}

	fn set_policy(&mut self, input: &ManagementPolicy) -> Result<ManagementHeld, Refused> {
		if input.grace > YEAR {
			return Err(refused("invalid", format!("a grace is at most a year, {YEAR} seconds")));
		}
		if input.generation.get() >= self.policy {
			self.policy = input.generation.get();
			self.grace = input.grace;
		}
		held(self.policy)
	}

	fn describe(&mut self, make: &impl Make, now: u64) -> Result<ManagementDescribed, Refused> {
		self.swept(now, make)?;
		let holding = |(id, item): (&u32, &Item)| -> Result<ManagementHolding, Refused> {
			let state = match (item.unasked, &item.state) {
				(Some(since), ManagementState::Made { address }) => {
					ManagementState::Unasked { since: uint53(since)?, address: Some(address.clone()) }
				}
				(Some(since), _) => ManagementState::Unasked { since: uint53(since)?, address: None },
				(None, state) => state.clone(),
			};
			Ok(ManagementHolding { id: *id, capacity: item.capacity.clone(), state })
		};
		Ok(ManagementDescribed {
			generation: uint53(self.generation)?,
			policy: uint53(self.policy)?,
			grace: self.grace,
			items: self.items.iter().map(holding).collect::<Result<_, _>>()?,
		})
	}

	fn end(&mut self, input: &ManagementEnd, make: &impl Make) -> Result<ManagementEnded, Refused> {
		match self.items.get(&input.id) {
			None => Ok(ManagementEnded {}),
			Some(item) if item.unasked.is_none() => {
				Err(refused("still_asked", format!("the list still asks item {}", input.id)))
			}
			Some(_) => {
				self.removed(&[input.id], make)?;
				Ok(ManagementEnded {})
			}
		}
	}
}

#[cfg(test)]
pub(crate) mod tests {
	use std::cell::RefCell;
	use std::path::PathBuf;
	use std::time::{SystemTime, UNIX_EPOCH};

	use driver_machine_object::Objects as _;
	use driver_machine_volume::{BUCKETS, VOLUMES, Volume, place};
	use envelope::contracts::{
		ManagementApply, ManagementCapacity, ManagementEnd, ManagementItem, ManagementPolicy,
		ManagementState, ObjectRead, ObjectWrite,
	};
	use envelope::{Bounded as _, Uint53};

	use crate::{Listed, Machine, Make, Manage as _};

	/// A mount of its own under the system's temporary directory, each volume a directory of it,
	/// and what else was asked written down; removed when dropped.
	pub(crate) struct Mount {
		pub(crate) path: PathBuf,
		pub(crate) free: u64,
		pub(crate) asked: RefCell<Vec<String>>,
	}

	impl Mount {
		pub(crate) fn new(name: &str) -> Self {
			let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
			let path = std::env::temp_dir().join(format!("listed-{name}-{}-{nanos}", std::process::id()));
			std::fs::create_dir_all(&path).unwrap();
			Self { path, free: 1 << 30, asked: RefCell::default() }
		}
	}

	impl Drop for Mount {
		fn drop(&mut self) {
			let _ = std::fs::remove_dir_all(&self.path);
		}
	}

	impl Make for Mount {
		fn free(&self) -> Result<u64, String> {
			Ok(self.free)
		}

		fn volume(&self, under: &str, volume: Volume, size: u64) -> Result<PathBuf, String> {
			let at = place(&self.path, under, volume);
			std::fs::create_dir_all(&at).map_err(|e| e.to_string())?;
			self.asked.borrow_mut().push(format!("volume {under} {} {size}", volume.item));
			Ok(at)
		}

		fn unvolume(&self, under: &str, volume: Volume) -> Result<(), String> {
			let at = place(&self.path, under, volume);
			if at.exists() {
				std::fs::remove_dir_all(&at).map_err(|e| e.to_string())?;
			}
			self.asked.borrow_mut().push(format!("unvolume {under} {}", volume.item));
			Ok(())
		}

		fn emptied(
			&self,
			binding: &driver_machine_container::Binding,
			item: u32,
		) -> Result<(), String> {
			self.asked.borrow_mut().push(format!("emptied {} {item}", binding.namespace));
			Ok(())
		}

		fn released(&self, binding: u32) {
			self.asked.borrow_mut().push(format!("released {binding}"));
		}
	}

	pub(crate) fn machine() -> Machine {
		Machine { millicores: 4000, memory: 1 << 32, address: "localhost:37483".into() }
	}

	pub(crate) fn item(id: u32, capacity: ManagementCapacity) -> ManagementItem {
		ManagementItem { id, capacity, credentials: vec![[id.to_le_bytes()[0]; 32]] }
	}

	pub(crate) fn sized(size: u64) -> Uint53 {
		Uint53::new(size).unwrap()
	}

	pub(crate) fn object(id: u32, size: u64) -> ManagementItem {
		item(id, ManagementCapacity::Object { size: sized(size) })
	}

	pub(crate) fn volume(id: u32, size: u64) -> ManagementItem {
		item(id, ManagementCapacity::Volume { size: sized(size) })
	}

	pub(crate) fn container(id: u32, millicores: u32) -> ManagementItem {
		item(id, ManagementCapacity::Container { millicores, memory: sized(1 << 28) })
	}

	fn apply(
		listed: &mut Listed,
		mount: &Mount,
		generation: u64,
		items: Vec<ManagementItem>,
		now: u64,
	) -> Result<(), &'static str> {
		let input = ManagementApply { generation: sized(generation), items, tokens: None };
		listed.apply(&input, &machine(), mount, now).map(drop).map_err(|r| r.reason)
	}

	fn state(listed: &Listed, id: u32) -> ManagementState {
		listed.items[&id].state.clone()
	}

	fn asked(mount: &Mount) -> Vec<String> {
		mount.asked.borrow_mut().drain(..).collect()
	}

	#[test]
	fn a_volume_item_is_made_a_volume_of_its_size_at_its_path() {
		let mount = Mount::new("volume");
		let mut listed = Listed::new(7);
		apply(&mut listed, &mount, 1, vec![volume(2, 4096)], 0).unwrap();
		let at = place(&mount.path, VOLUMES, Volume { binding: 7, item: 2 });
		let address = at.display().to_string();
		assert_eq!(state(&listed, 2), ManagementState::Made { address });
		assert_eq!(asked(&mount), ["volume volumes 2 4096"]);
		// Sent again as it is, nothing is made again.
		apply(&mut listed, &mount, 2, vec![volume(2, 4096)], 0).unwrap();
		assert!(asked(&mount).is_empty());
		apply(&mut listed, &mount, 3, vec![volume(2, 8192)], 0).unwrap();
		assert_eq!(asked(&mount), ["volume volumes 2 8192"]);
	}

	#[test]
	fn an_object_item_is_the_binding_s_bucket_and_a_second_is_beyond_the_host() {
		let mount = Mount::new("object");
		let mut listed = Listed::new(7);
		apply(&mut listed, &mount, 1, vec![object(1, 1024), object(2, 1024)], 0).unwrap();
		let address = machine().address;
		assert_eq!(state(&listed, 1), ManagementState::Made { address });
		let ManagementState::Failed { reason, .. } = state(&listed, 2) else { panic!() };
		assert_eq!(reason, "beyond_host");
		let (held, bucket) = listed.bucket.clone().unwrap();
		assert_eq!(held, 1);
		let room = 1024 + u64::try_from(driver_machine_object::MOST).unwrap();
		assert_eq!(asked(&mount), [format!("volume buckets 1 {room}")]);
		// Its capacity is the item's size.
		let write = |n: usize| ObjectWrite { name: "a".into(), content: vec![1; n] };
		assert!(bucket.write(&write(2048)).is_err());
		bucket.write(&write(1000)).unwrap();
		apply(&mut listed, &mount, 2, vec![object(1, 4096)], 0).unwrap();
		bucket.write(&write(2048)).unwrap();
		assert!(std::sync::Arc::ptr_eq(&bucket, &listed.bucket.clone().unwrap().1));
	}

	#[test]
	fn a_list_asking_more_space_than_is_free_is_beyond_the_host_but_one_made_is_not_asked_again() {
		let mut mount = Mount::new("free");
		mount.free = 10_000;
		let mut listed = Listed::new(7);
		assert_eq!(
			apply(&mut listed, &mount, 1, vec![volume(1, 6000), object(2, 6000)], 0),
			Err("beyond_host")
		);
		assert!(listed.items.is_empty() && asked(&mount).is_empty());
		apply(&mut listed, &mount, 1, vec![volume(1, 6000)], 0).unwrap();
		mount.free = 5000;
		// What is made counts once, so the same list fits however full the volume became.
		apply(&mut listed, &mount, 2, vec![volume(1, 6000), object(2, 4000)], 0).unwrap();
		assert_eq!(apply(&mut listed, &mount, 3, vec![volume(1, 12_000)], 0), Err("beyond_host"));
	}

	#[test]
	fn an_item_unasked_is_unmade_past_its_grace_and_the_binding_released_with_its_last() {
		let mount = Mount::new("unmade");
		let mut listed = Listed::new(7);
		let policy = ManagementPolicy { generation: sized(1), grace: 10 };
		listed.set_policy(&policy).unwrap();
		apply(&mut listed, &mount, 1, vec![volume(1, 64), object(2, 64), container(3, 100)], 0)
			.unwrap();
		let bucket = place(&mount.path, BUCKETS, Volume { binding: 7, item: 2 });
		assert!(bucket.join(driver_machine_object::INDEX).exists());
		asked(&mount);
		apply(&mut listed, &mount, 2, Vec::new(), 1000).unwrap();
		listed.describe(&mount, 5000).unwrap();
		assert!(asked(&mount).is_empty(), "within its grace nothing goes");
		assert_eq!(listed.items.len(), 3);
		listed.describe(&mount, 11_000).unwrap();
		assert_eq!(
			asked(&mount),
			["unvolume volumes 1", "unvolume buckets 2", "emptied b7 3", "released 7"]
		);
		assert!(listed.items.is_empty() && listed.bucket.is_none() && listed.made.is_none());
		assert!(!bucket.exists());
	}

	#[test]
	fn an_item_ended_is_unmade_at_once() {
		let mount = Mount::new("ended");
		let mut listed = Listed::new(7);
		apply(&mut listed, &mount, 1, vec![volume(1, 64), volume(2, 64)], 0).unwrap();
		apply(&mut listed, &mount, 2, vec![volume(2, 64)], 0).unwrap();
		asked(&mount);
		listed.end(&ManagementEnd { id: 1 }, &mount).unwrap();
		assert_eq!(asked(&mount), ["unvolume volumes 1"]);
		assert_eq!(listed.items.keys().copied().collect::<Vec<_>>(), [2]);
	}

	#[test]
	fn an_item_made_another_kind_is_unmade_first() {
		let mount = Mount::new("kind");
		let mut listed = Listed::new(7);
		apply(&mut listed, &mount, 1, vec![container(1, 100)], 0).unwrap();
		apply(&mut listed, &mount, 2, vec![volume(1, 64)], 0).unwrap();
		assert_eq!(asked(&mount), ["emptied b7 1", "volume volumes 1 64"]);
		assert!(listed.made.is_none());
	}

	#[test]
	fn a_list_found_again_reopens_its_bucket_and_fails_a_volume_gone() {
		let mount = Mount::new("found");
		let mut listed = Listed::new(7);
		apply(&mut listed, &mount, 1, vec![object(1, 1024), volume(2, 64)], 0).unwrap();
		let (_, bucket) = listed.bucket.clone().unwrap();
		bucket.write(&ObjectWrite { name: "a".into(), content: b"kept".to_vec() }).unwrap();
		drop(bucket);
		let mut again = Listed::new(7);
		again.items = listed.items.clone();
		drop(listed);
		std::fs::remove_dir_all(place(&mount.path, VOLUMES, Volume { binding: 7, item: 2 })).unwrap();
		super::found(&mut again, &mount.path);
		let (_, bucket) = again.bucket.clone().unwrap();
		let read = bucket.read(&ObjectRead { name: "a".into(), range: None }).unwrap();
		assert_eq!(read.content, b"kept");
		let ManagementState::Failed { reason, .. } = state(&again, 2) else { panic!() };
		assert_eq!(reason, "fault");
		// A volume not found is made again by the next list.
		apply(&mut again, &mount, 2, vec![object(1, 1024), volume(2, 64)], 0).unwrap();
		assert!(matches!(state(&again, 2), ManagementState::Made { .. }));
	}
}
