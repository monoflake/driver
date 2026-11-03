//! Parameters, rows and the number changed by this statement alone.

use envelope::contracts::{DatabaseResult, DatabaseStatement, DatabaseValue};
use envelope::{Bounded, Int53, Uint53};
use rusqlite::fallible_iterator::FallibleIterator as _;
use rusqlite::types::{Value, ValueRef};
use rusqlite::{Batch, Connection, params_from_iter};

use super::policy;
use crate::Unexecuted;

fn parameter(input: &DatabaseValue) -> Value {
	match input {
		DatabaseValue::Null => Value::Null,
		DatabaseValue::Integer { value: number } => Value::Integer(number.get()),
		DatabaseValue::Real { value: number } => Value::Real(*number),
		DatabaseValue::Text { value: text } => Value::Text(text.clone()),
		DatabaseValue::Bytes { value: bytes } => Value::Blob(bytes.clone()),
	}
}

fn value(cell: ValueRef<'_>) -> Result<DatabaseValue, Unexecuted> {
	Ok(match cell {
		ValueRef::Null => DatabaseValue::Null,
		ValueRef::Integer(n) => DatabaseValue::Integer {
			value: Int53::new(n).ok_or_else(|| Unexecuted::BeyondRange(n.to_string()))?,
		},
		ValueRef::Real(number) => {
			if !number.is_finite() {
				return Err(Unexecuted::BeyondRange(number.to_string()));
			}
			DatabaseValue::Real { value: number }
		}
		ValueRef::Text(bytes) => DatabaseValue::Text {
			value: std::str::from_utf8(bytes).map_err(|e| Unexecuted::Invalid(e.to_string()))?.into(),
		},
		ValueRef::Blob(bytes) => DatabaseValue::Bytes { value: bytes.into() },
	})
}

pub(super) fn run(
	connection: &Connection,
	input: &DatabaseStatement,
) -> Result<DatabaseResult, Unexecuted> {
	if input.sql.contains('\0') {
		return Err(Unexecuted::Invalid("SQL contains a NUL byte".into()));
	}
	let mut batch = Batch::new(connection, &input.sql);
	let mut statement = batch
		.next()
		.map_err(policy::error)?
		.ok_or_else(|| Unexecuted::Invalid("expected one SQL statement".into()))?;
	if batch.next().map_err(policy::error)?.is_some() {
		return Err(Unexecuted::Invalid("expected one SQL statement".into()));
	}
	let parameters = input.parameters.as_deref().unwrap_or_default();
	if statement.parameter_count() != parameters.len() {
		return Err(Unexecuted::Invalid("parameter count does not match statement".into()));
	}
	let columns = statement.column_names().map(str::to_owned).collect::<Vec<_>>();
	let before = connection.total_changes();
	let mut rows = Vec::new();
	{
		let mut cursor =
			statement.query(params_from_iter(parameters.iter().map(parameter))).map_err(policy::error)?;
		while let Some(row) = cursor.next().map_err(policy::error)? {
			rows.push(
				(0..columns.len())
					.map(|i| value(row.get_ref(i).map_err(policy::error)?))
					.collect::<Result<Vec<_>, _>>()?,
			);
		}
	}
	let changed = if connection.total_changes() == before { 0 } else { connection.changes() };
	let changed = Uint53::new(changed).ok_or_else(|| Unexecuted::BeyondRange(changed.to_string()))?;
	Ok(DatabaseResult { columns, rows, changed })
}
