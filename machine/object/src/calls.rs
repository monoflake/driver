//! Call history committed with the bucket's object names.

use std::time::{SystemTime, UNIX_EPOCH};

use envelope::contracts::{CallStep, CallSteps};
use envelope::{Bounded as _, Uint53};
use rusqlite::Connection;

use crate::{CALLS, Fault, ObjectStatusAnswer};

/// The current time in milliseconds since the Unix epoch.
pub(crate) fn now() -> Result<u64, Fault> {
	let elapsed = SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e| Fault(e.to_string()))?;
	u64::try_from(elapsed.as_millis()).map_err(|e| Fault(e.to_string()))
}

/// The id's bits kept in SQLite's signed integer without losing the high bit.
pub(crate) fn id(text: &str) -> Result<i64, String> {
	if text.len() != 16 || !text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
		return Err("a call id must be sixteen lowercase hexadecimal digits".into());
	}
	let bits = u64::from_str_radix(text, 16).map_err(|e| e.to_string())?;
	Ok(i64::from_ne_bytes(bits.to_ne_bytes()))
}

/// The oldest timestamp still retained.
fn oldest(now: u64) -> Result<u64, Fault> {
	Ok(now.saturating_sub(CALLS.as_ref().map_err(Clone::clone)?.status_retention))
}

pub(crate) fn open(index: &Connection) -> Result<(), Fault> {
	index.execute_batch(
		"CREATE TABLE IF NOT EXISTS calls (id INTEGER NOT NULL, sequence INTEGER NOT NULL, \
		 expires INTEGER NOT NULL, last INTEGER NOT NULL, PRIMARY KEY (id, sequence)) WITHOUT ROWID;",
	)?;
	Ok(())
}

pub(crate) fn sweep(index: &Connection, now: u64) -> Result<(), Fault> {
	// Negative ids hold future timestamps with their high bit set.
	let cutoff = i64::try_from(oldest(now)?).unwrap_or(i64::MAX);
	index.execute("DELETE FROM calls WHERE id >= 0 AND (id >> 16) < ?1", [cutoff])?;
	Ok(())
}

pub(crate) fn record(index: &Connection, call: &CallStep, id: i64) -> Result<(), rusqlite::Error> {
	let expires = i64::try_from(call.expires.get())
		.map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
	index.execute(
		"INSERT INTO calls (id, sequence, expires, last) VALUES (?1, ?2, ?3, ?4) \
		 ON CONFLICT (id, sequence) DO NOTHING",
		rusqlite::params![id, call.sequence, expires, call.last],
	)?;
	Ok(())
}

pub(crate) fn status(index: &Connection, id: i64) -> Result<ObjectStatusAnswer, Fault> {
	let mut statement =
		index.prepare("SELECT sequence, expires, last FROM calls WHERE id = ?1 ORDER BY sequence")?;
	let mut rows = statement.query([id])?;
	let mut committed = Vec::new();
	let mut expires = 0;
	let mut finished = false;
	while let Some(row) = rows.next()? {
		committed.push(row.get::<_, u32>(0)?);
		expires = row.get::<_, i64>(1)?;
		finished |= row.get::<_, bool>(2)?;
	}
	if committed.is_empty() {
		return Ok(ObjectStatusAnswer::NotFound);
	}
	let expires = u64::try_from(expires)
		.ok()
		.and_then(Uint53::new)
		.ok_or_else(|| Fault("call expiry is outside uint53".into()))?;
	Ok(ObjectStatusAnswer::Found(CallSteps { committed, expires, finished }))
}

pub(crate) fn forgotten(id: i64, now: u64) -> Result<bool, Fault> {
	Ok((u64::from_ne_bytes(id.to_ne_bytes()) >> 16) < oldest(now)?)
}

#[cfg(test)]
mod tests {
	use crate::CALLS;

	#[test]
	fn the_platform_call_timing_values_parse() {
		let timing = CALLS.as_ref().unwrap();
		for value in [
			timing.lock_wait,
			timing.lock_hold,
			timing.lookup_deadline,
			timing.id_life,
			timing.status_retention,
		] {
			assert!(value > 0);
		}
	}
}
