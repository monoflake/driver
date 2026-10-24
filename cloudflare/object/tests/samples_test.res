/***
 * The `object` samples run through the Worker `object`, each case on a binding holding one item of
 * the size it gives, a write refused within a second of its key's last sent again a second later.
 */
open Node

let member = Served.member
let textOf = Served.textOf

let samples = [
  "../platform/tests/kinds/objects/listing.json",
  "../platform/tests/kinds/objects/ranges.json",
  "../platform/tests/kinds/objects/writes.json",
]

/** The size of an item where a case gives none, the most this driver takes, 1 TiB. */
let largest = 1_099_511_627_776.

/** The bound `content`, the contract's 16 MiB. */
let bound =
  16 * 1024 * 1024

/** `$bytes` of a length, the BLAKE3 of the case's description, the step and the field, repeated. */
let filled = (description, step, field, length) => {
  let seed = Keys.Hash.plain(Web.utf8(`${description}/${Int.toString(step)}/${field}`))
  let bytes = Uint8Array.fromLength(length)
  for at in 0 to length - 1 {
    bytes->TypedArray.set(at, seed->TypedArray.get(Int.mod(at, 32))->Option.getOr(0))
  }
  bytes
}

/** A `$bytes` length, a number or the bound `content` and how far past it. */
let lengthOf = spec =>
  switch (spec->JSON.Decode.float, spec->member("plus")->Option.flatMap(JSON.Decode.float)) {
  | (Some(n), _) => Float.toInt(n)
  | (None, Some(plus)) => bound + Float.toInt(plus)
  | (None, None) => throw(JsExn.anyToExnInternal("a $bytes length is a number or a bound"))
  }

/** An input with each `$use` given what was captured, and each `$bytes` filled. */
let resolved = (description, step, input, captured: dict<JSON.t>) =>
  input
  ->JSON.Decode.object
  ->Option.getOr(dict{})
  ->Dict.toArray
  ->Array.map(((key, value)) =>
    switch (value->textOf("$use"), value->member("$bytes")) {
    | (Some(name), _) => (key, captured->Dict.get(name)->Option.getOr(JSON.Null))
    | (None, Some(spec)) =>
      let bytes = filled(
        description,
        step,
        key,
        lengthOf(spec->member("length")->Option.getOr(JSON.Null)),
      )
      (key, JSON.String(Envelope.Base64url.encode(bytes)))
    | (None, None) => (key, value)
    }
  )
  ->Dict.fromArray

/** Whether a value is as expected, every field it writes and no other, `$capture` keeping one. */
let rec matches = (expect: JSON.t, actual: JSON.t, captured: dict<JSON.t>) =>
  switch (expect->JSON.Decode.object, expect->JSON.Decode.array) {
  | (Some(e), _) if e->Dict.get("$any") != None => true
  | (Some(e), _) if e->Dict.get("$capture") != None =>
    e
    ->Dict.get("$capture")
    ->Option.flatMap(JSON.Decode.string)
    ->Option.forEach(name => captured->Dict.set(name, actual))
    true
  | (Some(e), _) =>
    switch actual->JSON.Decode.object {
    | Some(a) =>
      Dict.keysToArray(e)->Array.length == Dict.keysToArray(a)->Array.length &&
        e
        ->Dict.toArray
        ->Array.every(((key, value)) =>
          a->Dict.get(key)->Option.mapOr(false, v => matches(value, v, captured))
        )
    | None => false
    }
  | (None, Some(e)) =>
    switch actual->JSON.Decode.array {
    | Some(a) =>
      Array.length(e) == Array.length(a) &&
        e->Array.everyWithIndex((value, i) => matches(value, a->Array.getUnsafe(i), captured))
    | None => false
    }
  | (None, None) => expect == actual
  }

/** Whether an answer held what a step expects. */
let held = (expect, answer, captured) =>
  switch expect->member("output") {
  | Some(output) =>
    answer->textOf("status") == Some("success") &&
      matches(output, answer->member("data")->Option.getOr(JSON.Null), captured)
  | None =>
    answer->textOf("status") == Some("error") &&
    answer->member("failure") == expect->member("failure") &&
    answer->member("reason") == expect->member("reason")
  }

/** One case on a binding of its own, how many writes it sent again. */
let ran = async (case: JSON.t) => {
  let description = case->textOf("description")->Option.getOr("")
  let size =
    case->member("given")->Option.flatMap(g => g->member("size"))->Option.flatMap(JSON.Decode.float)
  let served = Served.make(~size=size->Option.getOr(largest))
  let captured = dict{}
  let again = ref(0)
  let steps = case->member("steps")->Option.flatMap(JSON.Decode.array)->Option.getOr([])
  for at in 0 to Array.length(steps) - 1 {
    let step = steps->Array.getUnsafe(at)
    let operation = step->textOf("call")->Option.getOr("")
    let input = resolved(description, at, step->member("input")->Option.getOr(JSON.Null), captured)
    let send = () => served->Served.call(operation, JSON.stringify(JSON.Object(input)))
    let (_, first) = await send()
    let answer = if first->textOf("message") == Some(Stores.limited) {
      served.clock := served.clock.contents +. 1000.
      again := again.contents + 1
      let (_, second) = await send()
      second
    } else {
      first
    }
    let expect = step->member("expect")->Option.getOr(JSON.Null)
    let shown = JSON.stringify(answer)->String.slice(~start=0, ~end=400)
    ok(
      held(expect, answer, captured),
      ~message=`${description}: step ${Int.toString(at)}, ${operation}, answered ${shown}`,
    )
  }
  again.contents
}

test("every object sample holds, a write within a second of another sent again", async () => {
  let cases = samples->Array.flatMap(path => {
    let sample = fromRoot(path)
    deepEqual(sample->textOf("interface"), Some("object"))
    sample->member("cases")->Option.flatMap(JSON.Decode.array)->Option.getOr([])
  })
  let again = ref(0)
  for c in 0 to Array.length(cases) - 1 {
    again := again.contents + (await ran(cases->Array.getUnsafe(c)))
  }
  deepEqual((Array.length(cases), again.contents), (12, 1))
})
