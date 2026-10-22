//! A call read and its answer written, JSON or CBOR as the request asks, each answer one envelope
//! its status tells, RFCs vr5lw and ge55b.

use axum::http::{HeaderMap, StatusCode, header};
use codec::Cbor as _;
use driver_machine_container::Refused;
use envelope::contracts::{self, Error, Failure};
use envelope::{Answer, Called, Encoded, Envelope, Malformed, Reason, Step};

/// The two forms a body is written in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Form {
	Json,
	Cbor,
}

impl Form {
	/// The form a media type names, its parameters passed over.
	fn named(media: &str) -> Option<Self> {
		let bare = media.split(';').next().unwrap_or_default().trim();
		if bare.eq_ignore_ascii_case("application/json") {
			Some(Self::Json)
		} else if bare.eq_ignore_ascii_case("application/cbor") {
			Some(Self::Cbor)
		} else {
			None
		}
	}

	pub(crate) const fn media(self) -> &'static str {
		match self {
			Self::Json => "application/json",
			Self::Cbor => "application/cbor",
		}
	}
}

/// The form a request's body is in, by its `Content-Type`, and the form its answer is written in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Forms {
	pub(crate) body: Option<Form>,
	pub(crate) answer: Form,
}

impl Forms {
	/// The answer's form is the first `Accept` names, else the body's, else CBOR, RFC vr5lw.
	pub(crate) fn of(headers: &HeaderMap) -> Self {
		let text = |name| headers.get(name).and_then(|v| v.to_str().ok());
		let body = text(header::CONTENT_TYPE).and_then(Form::named);
		let accepted = text(header::ACCEPT).and_then(|a| a.split(',').find_map(Form::named));
		Self { body, answer: accepted.or(body).unwrap_or(Form::Cbor) }
	}
}

/// An error by its reason, its failure the operation's own or every operation's, else unknown, and
/// its message the one given or the reason's own, RFC ge55b.
pub(crate) fn error(declared: &[Reason], reason: &str, message: Option<String>) -> Error {
	let known = declared.iter().chain(contracts::REASONS).find(|r| r.name == reason);
	Error {
		failure: known.map_or(Failure::Unknown, |r| r.failure),
		reason: reason.to_owned(),
		message: message
			.or_else(|| contracts::message(reason).map(str::to_owned))
			.unwrap_or_else(|| reason.to_owned()),
	}
}

/// What the container kind refused, as the operation answers it.
pub(crate) fn refused(declared: &[Reason], refusal: Refused) -> Error {
	error(declared, refusal.reason, refusal.message)
}

/// A call not as its interface writes it.
pub(crate) fn malformed(message: impl Into<String>) -> Error {
	error(&[], "malformed", Some(message.into()))
}

/// Where a value read stands, `input.items[0].id`.
fn place(at: &[Step]) -> String {
	at.iter().fold(String::new(), |mut text, step| {
		match step {
			Step::Field(name) if text.is_empty() => text.push_str(name),
			Step::Field(name) => text.push_str(&format!(".{name}")),
			Step::Index(index) => text.push_str(&format!("[{index}]")),
			Step::Key(key) => text.push_str(&format!("[{key:?}]")),
		}
		text
	})
}

/// Why a call was not read, as its `malformed` message says it.
fn unread(why: &Malformed) -> Error {
	if why.at.is_empty() {
		malformed(format!("expected {}", why.expected))
	} else {
		malformed(format!("expected {} at {}", why.expected, place(&why.at)))
	}
}

/// The call a body holds in its form.
pub(crate) fn call<C: Called>(form: Form, body: &[u8]) -> Result<Envelope<C>, Error> {
	match form {
		Form::Json => {
			let json: serde_json::Value = serde_json::from_slice(body)
				.map_err(|e| malformed(format!("the body is not JSON, {e}")))?;
			Envelope::<C>::from_json(&json).map_err(|why| unread(&why))
		}
		Form::Cbor => {
			let cbor = codec::Value::decode(body)
				.map_err(|e| malformed(format!("the body is not one CBOR data item, {e:?}")))?;
			Envelope::<C>::from_cbor(&cbor).map_err(|why| unread(&why))
		}
	}
}

/// The status an answer is sent with, which says as much to what stands between, RFC ge55b.
pub(crate) fn status(error: &Error) -> StatusCode {
	match (error.failure, error.reason.as_str()) {
		(Failure::Rejected, "denied") => StatusCode::FORBIDDEN,
		(Failure::Rejected, "not_found") => StatusCode::NOT_FOUND,
		(Failure::Rejected, _) => StatusCode::BAD_REQUEST,
		(Failure::Unavailable, "rate_limited") => StatusCode::TOO_MANY_REQUESTS,
		(Failure::Unavailable, _) => StatusCode::SERVICE_UNAVAILABLE,
		(Failure::Unknown, _) => StatusCode::INTERNAL_SERVER_ERROR,
	}
}

/// An answer's bytes in its form, or none where it cannot be written.
fn bytes<O: Encoded>(answer: &Answer<O>, form: Form) -> Option<Vec<u8>> {
	match form {
		Form::Json => serde_json::to_vec(&answer.to_json()).ok(),
		Form::Cbor => answer.to_cbor().encode().ok(),
	}
}

/// An answer written, its status and bytes; an output that cannot be written is a `fault`.
pub(crate) fn written<O: Encoded>(answer: Result<O, Error>, form: Form) -> (StatusCode, Vec<u8>) {
	let (code, answer) = match answer {
		Ok(output) => (StatusCode::OK, Answer::Success(output)),
		Err(e) => (status(&e), Answer::Error(e)),
	};
	match bytes(&answer, form) {
		Some(encoded) => (code, encoded),
		None => {
			let fault = error(&[], "fault", Some("the answer could not be written".to_owned()));
			let code = status(&fault);
			(code, bytes(&Answer::<O>::Error(fault), form).unwrap_or_default())
		}
	}
}
