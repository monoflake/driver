//! A binding's list held by generation, its grace and each item asked or unasked, as
//! `model/contracts/kinds/management.res` and its samples have it, RFC vr5lw.

use std::collections::{BTreeMap, BTreeSet};

use driver_machine_container::Refused;
use envelope::contracts::{
	ManagementApply, ManagementDescribed, ManagementEnd, ManagementEnded, ManagementHeld,
	ManagementHolding, ManagementItem, ManagementPolicy, ManagementState,
};
use envelope::{Bounded, Uint53};

use crate::{Item, Listed, Manage};

/// The grace of a binding that set none, a week in seconds.
const WEEK: u32 = 604_800;

/// The longest grace, a year of 365 days in seconds.
const YEAR: u32 = 31_536_000;

impl Default for Listed {
	fn default() -> Self {
		Self { generation: 0, policy: 0, grace: WEEK, items: BTreeMap::new(), made: None, bucket: None }
	}
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

/// An item made on the machine within what it can hold, and its state.
fn made(_listed: &mut Listed, _item: &ManagementItem) -> Result<ManagementState, Refused> {
	todo!("4elqc")
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
	fn apply(&mut self, input: &ManagementApply, now: u64) -> Result<ManagementHeld, Refused> {
		valid(&input.items)?;
		if input.generation.get() < self.generation {
			return held(self.generation);
		}
		for item in &input.items {
			let kept = self.items.get(&item.id).is_some_and(|i| i.capacity == item.capacity);
			if !kept {
				let state = made(self, item)?;
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
