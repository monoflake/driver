//! Parameters, rows and the number changed by this statement alone.

use envelope::contracts::{DatabaseResult, DatabaseStatement, DatabaseValue};
use envelope::{Bounded, Int53, Uint53};
use rusqlite::types::{Value, ValueRef};
use rusqlite::{Connection, params_from_iter};

use super::policy;
use crate::Unexecuted;

fn parameter(value: &DatabaseValue) -> Value {
	match value {
		DatabaseValue::Null => Value::Null,
		DatabaseValue::Integer { value } => Value::Integer(value.get()),
		DatabaseValue::Real { value } => Value::Real(*value),
		DatabaseValue::Text { value } => Value::Text(value.clone()),
		DatabaseValue::Bytes { value } => Value::Blob(value.clone()),
	}
}

fn value(value: ValueRef<'_>) -> Result<DatabaseValue, Unexecuted> {
	Ok(match value {
		ValueRef::Null => DatabaseValue::Null,
		ValueRef::Integer(n) => DatabaseValue::Integer {
			value: Int53::new(n).ok_or_else(|| Unexecuted::BeyondRange(n.to_string()))?,
		},
		ValueRef::Real(value) => DatabaseValue::Real { value },
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
	let mut statement = connection.prepare(&input.sql).map_err(policy::error)?;
	if statement.expanded_sql().is_none() {
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
