/***
 * Whether a batch of writes has room in the item's size, its own bytes added to the size last read
 * before it runs, and the size read after it runs, RFC nrs5v.
 */
module Contracts = Envelope.Contracts

/** The bytes a value adds, a number as SQLite's widest of eight, text in UTF-8, none for null. */
let valueBytes = (value: Contracts.DatabaseValue.t) =>
  switch value {
  | Null => 0
  | Integer(_) | Real(_) => 8
  | Text({value}) => TypedArray.length(Web.utf8(value))
  | Bytes({value}) => TypedArray.length(value)
  }

/** The bytes a batch adds, every statement's SQL in UTF-8 and every parameter it binds. */
let added = (statements: array<Contracts.DatabaseStatement.t>) =>
  statements->Array.reduce(0., (total, statement) =>
    statement.parameters
    ->Option.getOr([])
    ->Array.reduce(total +. Int.toFloat(TypedArray.length(Web.utf8(statement.sql))), (
      total,
      value,
    ) => total +. Int.toFloat(valueBytes(value)))
  )

/** Why a batch of writes finds no room, none where it has room. */
let refusal = (statements, ~held, ~size) =>
  if held >= size {
    Some("the database holds its item's size")
  } else if held +. added(statements) > size {
    Some("the batch would take the database past its item's size")
  } else {
    None
  }
