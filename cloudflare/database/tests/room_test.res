/*** The room a batch of writes finds, reckoned before it runs, apart from any database. */
open Node

module Contracts = Envelope.Contracts

let statement = (sql, parameters): Contracts.DatabaseStatement.t => {sql, parameters}

test("a batch's bytes are its SQL in UTF-8 and each parameter it binds", async () => {
  deepEqual(Room.added([]), 0.)
  deepEqual(Room.added([{sql: "SELECT 1"}]), 8.)
  // The SQL of two bytes a character, and a text parameter of three bytes for one.
  deepEqual(Room.added([statement("é", [Text({value: "€"})])]), 5.)
  let parameters: array<Contracts.DatabaseValue.t> = [
    Null,
    Integer({value: 1.}),
    Real({value: 0.5}),
    Bytes({value: Uint8Array.fromLength(100)}),
  ]
  deepEqual(
    Room.added([statement("?", parameters), {sql: "ab"}]),
    1. +. 0. +. 8. +. 8. +. 100. +. 2.,
  )
})

test("a batch is refused where it would pass the size, or the size is already held", async () => {
  let batch = [statement("x", [Bytes({value: Uint8Array.fromLength(9)})])]
  deepEqual(Room.refusal(batch, ~held=90., ~size=100.), None)
  ok(Room.refusal(batch, ~held=91., ~size=100.)->Option.isSome)
  ok(Room.refusal([], ~held=100., ~size=100.)->Option.isSome)
  ok(Room.refusal([], ~held=150., ~size=100.)->Option.isSome)
  deepEqual(Room.refusal([], ~held=99., ~size=100.), None)
})
