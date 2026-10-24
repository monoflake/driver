/***
 * A contract's value bound to a statement, and a row's cell read back, as D1 converts each,
 * https://developers.cloudflare.com/d1/worker-api/#type-conversion, RFC nrs5v.
 */
module Contracts = Envelope.Contracts

/** A contract's value as D1 binds it, an integer and a real alike a number. */
let bound = (value: Contracts.DatabaseValue.t): Stores.value =>
  switch value {
  | Null => Null
  | Integer({value}) | Real({value}) => Number(value)
  | Text({value}) => Text(value)
  | Bytes({value}) => Stores.bytes(value)
  }

/** The most an integer is carried whole, as a JavaScript number holds it. */
let safest = 9007199254740991.

/** Why a cell was not read, past the range a number carries, or of no type D1 answers. */
type unread = Beyond | Unknown

/** Whether a number holds no fraction. */
let whole = value => Float.isFinite(value) && Math.floor(value) == value

/**
 * A cell read as a contract's value. D1 answers an integer and a real alike as a number, so one
 * with no fraction is read an integer.
 */
let read = (cell: Stores.cell): result<Contracts.DatabaseValue.t, unread> =>
  switch Stores.readOf(cell) {
  | Absent => Ok(Null)
  | Textual(value) => Ok(Text({value: value}))
  | Binary(value) => Ok(Bytes({value: value}))
  | Numeric(value) if whole(value) && Math.abs(value) > safest => Error(Beyond)
  | Numeric(value) if whole(value) => Ok(Integer({value: value}))
  | Numeric(value) if Float.isFinite(value) => Ok(Real({value: value}))
  | Numeric(_) | Other => Error(Unknown)
  | Large => Error(Beyond)
  }
