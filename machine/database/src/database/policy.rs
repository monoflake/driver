//! Tenant authorization and SQLite failures.

use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use rusqlite::{Error, ErrorCode};

use crate::{Fault, Unexecuted};

pub(super) fn authorize(context: AuthContext<'_>) -> Authorization {
	match context.action {
		AuthAction::Attach { .. }
		| AuthAction::Detach { .. }
		| AuthAction::Pragma { .. }
		| AuthAction::Transaction { .. }
		| AuthAction::Savepoint { .. }
		| AuthAction::CreateVtable { .. }
		| AuthAction::DropVtable { .. }
		| AuthAction::Unknown { .. } => Authorization::Deny,
		AuthAction::Function { function_name } => {
			if functions().any(|name| function_name.eq_ignore_ascii_case(name)) {
				Authorization::Allow
			} else {
				Authorization::Deny
			}
		}
		AuthAction::CreateIndex { .. }
		| AuthAction::CreateTable { .. }
		| AuthAction::CreateTempIndex { .. }
		| AuthAction::CreateTempTable { .. }
		| AuthAction::CreateTempTrigger { .. }
		| AuthAction::CreateTempView { .. }
		| AuthAction::CreateTrigger { .. }
		| AuthAction::CreateView { .. }
		| AuthAction::Delete { .. }
		| AuthAction::DropIndex { .. }
		| AuthAction::DropTable { .. }
		| AuthAction::DropTempIndex { .. }
		| AuthAction::DropTempTable { .. }
		| AuthAction::DropTempTrigger { .. }
		| AuthAction::DropTempView { .. }
		| AuthAction::DropTrigger { .. }
		| AuthAction::DropView { .. }
		| AuthAction::Insert { .. }
		| AuthAction::Read { .. }
		| AuthAction::Select
		| AuthAction::Update { .. }
		| AuthAction::AlterTable { .. }
		| AuthAction::Reindex { .. }
		| AuthAction::Analyze { .. }
		| AuthAction::Recursive => Authorization::Allow,
		_ => Authorization::Deny,
	}
}

// The function lists in sqlite.org/lang_corefunc.html and its five linked families.
fn functions() -> impl Iterator<Item = &'static str> {
	[
		"abs changes char coalesce concat concat_ws format glob hex if ifnull iif instr \
		 last_insert_rowid length like likelihood likely lower ltrim max min nullif octet_length \
		 printf quote random randomblob replace round rtrim sign soundex sqlite_compileoption_get \
		 sqlite_compileoption_used sqlite_offset sqlite_source_id sqlite_version substr substring \
		 total_changes trim typeof unhex unicode unistr unistr_quote unlikely upper zeroblob",
		"avg count group_concat median percentile percentile_cont percentile_disc string_agg sum total",
		"row_number rank dense_rank percent_rank cume_dist ntile lag lead first_value last_value nth_value",
		"current_date current_time current_timestamp date time datetime julianday unixepoch strftime \
		 timediff",
		// What ALTER TABLE calls in its nested SQL, which a caller's own SQL cannot call.
		"sqlite_drop_column sqlite_rename_column sqlite_rename_quotefix sqlite_rename_table \
		 sqlite_rename_test",
		"acos acosh asin asinh atan atan2 atanh ceil ceiling cos cosh degrees exp floor ln log log10 \
		 log2 mod pi pow power radians sin sinh sqrt tan tanh trunc",
		"json jsonb json_array jsonb_array json_array_insert jsonb_array_insert json_array_length \
		 json_error_position json_extract jsonb_extract -> ->> json_insert jsonb_insert json_object \
		 jsonb_object json_patch jsonb_patch json_pretty json_quote json_remove jsonb_remove \
		 json_replace jsonb_replace json_set jsonb_set json_type json_valid json_group_array \
		 jsonb_group_array json_group_object jsonb_group_object json_each json_tree jsonb_each jsonb_tree",
	]
	.into_iter()
	.flat_map(str::split_ascii_whitespace)
}

pub(super) fn error(failure: Error) -> Unexecuted {
	let message = failure.to_string();
	let code = if let Error::SqlInputError { error: sqlite, .. } = &failure {
		Some(sqlite.code)
	} else {
		failure.sqlite_error_code()
	};
	match code {
		Some(ErrorCode::DiskFull) => Unexecuted::StorageFull,
		Some(ErrorCode::ConstraintViolation) => Unexecuted::Constraint(message),
		Some(ErrorCode::TooBig) => Unexecuted::BeyondLimit(message),
		Some(ErrorCode::Unknown)
			if message.starts_with("too many SQL variables")
				|| message.starts_with("Expression tree is too large")
				|| message.starts_with("too many terms in compound SELECT") =>
		{
			Unexecuted::BeyondLimit(message)
		}
		Some(
			ErrorCode::Unknown
			| ErrorCode::AuthorizationForStatementDenied
			| ErrorCode::ParameterOutOfRange
			| ErrorCode::TypeMismatch,
		) => Unexecuted::Invalid(message),
		None
			if matches!(
				failure,
				Error::MultipleStatement
					| Error::InvalidParameterCount(..)
					| Error::InvalidParameterName(_)
					| Error::NulError(_)
			) =>
		{
			Unexecuted::Invalid(message)
		}
		Some(_) | None => Unexecuted::Fault(Fault(message)),
	}
}
