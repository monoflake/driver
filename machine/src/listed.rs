//! A binding's list held by generation, its grace and each item asked or unasked, as
//! `model/contracts/kinds/management.res` and its samples have it, RFC vr5lw.

use std::collections::{BTreeMap, BTreeSet};

use driver_machine_container::{Capacity, Refused};
use driver_machine_management::Binding;
use envelope::contracts::{
	ManagementApply, ManagementCapacity, ManagementDescribed, ManagementEnd, ManagementEnded,
	ManagementHeld, ManagementHolding, ManagementItem, ManagementPolicy, ManagementState,
};
use envelope::{Bounded, Uint53};

use crate::{Item, Listed, Machine, Manage};

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
		qgroup: format!("1/{binding}"),
		capacities: BTreeMap::new(),
	}
}

/// What the machine made of a binding found again from its items, each `container` item made a
/// container of capacity, none where it holds no such item.
pub(crate) fn remade(
	binding: Binding,
	items: &BTreeMap<u32, Item>,
) -> Option<driver_machine_container::Binding> {
	let mut made = named(binding);
	for (id, item) in items {
		if let (ManagementCapacity::Container { millicores, memory }, ManagementState::Made { .. }) =
			(&item.capacity, &item.state)
		{
			made.capacities.insert(*id, Capacity { millicores: *millicores, memory: memory.get() });
		}
	}
	(!made.capacities.is_empty()).then_some(made)
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

/// A list whose `container` items ask at most the machine's cores and memory, the bound RFC 4elqc
/// proposes, what other bindings hold not yet counted.
fn bounded(items: &[ManagementItem], machine: &Machine) -> Result<(), Refused> {
	let (mut millicores, mut memory) = (0u64, 0u64);
	for item in items {
		match &item.capacity {
			ManagementCapacity::Container { millicores: cores, memory: bytes } => {
				millicores = millicores.saturating_add(u64::from(*cores));
				memory = memory.saturating_add(bytes.get());
			}
			ManagementCapacity::Volume { .. }
			| ManagementCapacity::Object { .. }
			| ManagementCapacity::Database { .. } => {}
		}
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
	Ok(())
}

/// An item made on the machine, and its state; a `container` item is recorded and made at once,
/// since the container kind applies its share as it creates each container, RFC 4elqc.
fn made(
	listed: &mut Listed,
	item: &ManagementItem,
	machine: &Machine,
) -> Result<ManagementState, Refused> {
	if let Some(made) = listed.made.as_mut() {
		made.capacities.remove(&item.id);
	}
	match &item.capacity {
		ManagementCapacity::Container { millicores, memory } => {
			let binding = listed.binding;
			let made = listed.made.get_or_insert_with(|| named(binding));
			made.capacities.insert(item.id, Capacity { millicores: *millicores, memory: memory.get() });
			Ok(ManagementState::Made { address: machine.address.clone() })
		}
		// The other kinds wait for their blocks, RFC 4elqc.
		ManagementCapacity::Volume { .. }
		| ManagementCapacity::Object { .. }
		| ManagementCapacity::Database { .. } => todo!("4elqc"),
	}
}

/// An item removed from the machine.
fn unmade(_listed: &mut Listed, _id: u32) -> Result<(), Refused> {
	todo!("4elqc")
}

impl Listed {
	/// Every item unasked past its grace removed.
	fn swept(&mut self, now: u64) -> Result<(), Refused> {
		let grace = u64::from(self.grace).saturating_mul(1000);
		let past: Vec<u32> = self
			.items
			.iter()
			.filter(|(_, item)| item.unasked.is_some_and(|since| now >= since.saturating_add(grace)))
			.map(|(id, _)| *id)
			.collect();
		for id in past {
			unmade(self, id)?;
			self.items.remove(&id);
		}
		Ok(())
	}
}

impl Manage for Listed {
	fn apply(
		&mut self,
		input: &ManagementApply,
		machine: &Machine,
		now: u64,
	) -> Result<ManagementHeld, Refused> {
		valid(&input.items)?;
		if input.generation.get() < self.generation {
			return held(self.generation);
		}
		bounded(&input.items, machine)?;
		for item in &input.items {
			let kept = self.items.get(&item.id).is_some_and(|i| i.capacity == item.capacity);
			if !kept {
				let state = made(self, item, machine)?;
				self.items.insert(
					item.id,
					Item { capacity: item.capacity.clone(), credentials: Vec::new(), state, unasked: None },
				);
			}
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
		self.swept(now)?;
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

	fn describe(&mut self, now: u64) -> Result<ManagementDescribed, Refused> {
		self.swept(now)?;
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

	fn end(&mut self, input: &ManagementEnd) -> Result<ManagementEnded, Refused> {
		match self.items.get(&input.id) {
			None => Ok(ManagementEnded {}),
			Some(item) if item.unasked.is_none() => {
				Err(refused("still_asked", format!("the list still asks item {}", input.id)))
			}
			Some(_) => {
				unmade(self, input.id)?;
				self.items.remove(&input.id);
				Ok(ManagementEnded {})
			}
		}
	}
}
