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
			// Only bundled SQLite functions are available and no extensions are installed.
			if ["load_extension", "readfile", "writefile", "edit"]
				.iter()
				.any(|name| function_name.eq_ignore_ascii_case(name))
			{
				Authorization::Deny
			} else {
				Authorization::Allow
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

pub(super) fn error(error: Error) -> Unexecuted {
	let message = error.to_string();
	let code = if let Error::SqlInputError { error, .. } = &error {
		Some(error.code)
	} else {
		error.sqlite_error_code()
	};
	match code {
		Some(ErrorCode::DiskFull) => Unexecuted::StorageFull,
		Some(ErrorCode::ConstraintViolation) => Unexecuted::Constraint(message),
		Some(ErrorCode::TooBig) => Unexecuted::BeyondLimit(message),
		Some(
			ErrorCode::Unknown
			| ErrorCode::AuthorizationForStatementDenied
			| ErrorCode::ParameterOutOfRange
			| ErrorCode::TypeMismatch,
		) => Unexecuted::Invalid(message),
		None
			if matches!(
				error,
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
