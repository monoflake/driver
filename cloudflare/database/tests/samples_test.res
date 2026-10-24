/***
 * The `database` samples run through the Worker `database`, each case on a binding holding one item
 * of the size it gives, a `wait` moving the clock and `$time` read from it.
 */
open Node

let member = Served.member
let textOf = Served.textOf

let samples = [
  "../platform/tests/kinds/databases/statements.json",
  "../platform/tests/kinds/databases/batches.json",
  "../platform/tests/kinds/databases/limits.json",
  "../platform/tests/kinds/databases/rewinds.json",
]

/** The size of an item where a case gives none, the most this driver takes, 10 GB. */
let largest = 10_000_000_000.

/** Each bound a case may name, as this driver declares it. */
let bounds = dict{"statement": Statements.bound}

/** `$bytes` of a length, the BLAKE3 of the case's description, the step and the path, repeated. */
let filled = (description, step, path, length) => {
  let seed = Keys.Hash.plain(Web.utf8(`${description}/${Int.toString(step)}/${path}`))
  let bytes = Uint8Array.fromLength(length)
  for at in 0 to length - 1 {
    bytes->TypedArray.set(at, seed->TypedArray.get(Int.mod(at, 32))->Option.getOr(0))
  }
  bytes
}

/** A length, a number or a bound this driver declares and how far past it. */
let lengthOf = spec =>
  switch (
    spec->JSON.Decode.float,
    spec->textOf("bound")->Option.flatMap(name => bounds->Dict.get(name)),
    spec->member("plus")->Option.flatMap(JSON.Decode.float),
  ) {
  | (Some(n), _, _) => Float.toInt(n)
  | (None, Some(bound), plus) => bound + plus->Option.mapOr(0, Float.toInt)
  | (None, None, _) => throw(JsExn.anyToExnInternal("a length is a number or a declared bound"))
  }

/** An input with each placeholder made, `$use` what was captured, `$time` read from the clock. */
let rec resolved = (description, step, path, input: JSON.t, captured: dict<JSON.t>, ~now) => {
  let within = (key, value) => resolved(description, step, `${path}/${key}`, value, captured, ~now)
  switch (input->JSON.Decode.object, input->JSON.Decode.array) {
  | (Some(o), _) =>
    switch (
      o->Dict.get("$use"),
      o->Dict.get("$bytes"),
      o->Dict.get("$text"),
      o->Dict.get("$time"),
    ) {
    | (Some(name), _, _, _) =>
      captured->Dict.get(name->JSON.Decode.string->Option.getOr(""))->Option.getOr(JSON.Null)
    | (None, Some(spec), _, _) =>
      let length = lengthOf(spec->member("length")->Option.getOr(JSON.Null))
      JSON.String(Envelope.Base64url.encode(filled(description, step, path, length)))
    | (None, None, Some(spec), _) =>
      let start = spec->textOf("start")->Option.getOr("")
      let length = lengthOf(spec->member("length")->Option.getOr(JSON.Null))
      JSON.String(start ++ String.repeat(" ", length - String.length(start)))
    | (None, None, None, Some(spec)) =>
      let ago = spec->member("ago")->Option.flatMap(JSON.Decode.float)->Option.getOr(0.)
      JSON.Number(now -. ago)
    | (None, None, None, None) =>
      JSON.Object(o->Dict.toArray->Array.map(((k, v)) => (k, within(k, v)))->Dict.fromArray)
    }
  | (None, Some(a)) => JSON.Array(a->Array.mapWithIndex((v, i) => within(Int.toString(i), v)))
  | (None, None) => input
  }
}

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

/** One case on a binding of its own, the steps that did not hold as each answered. */
let ran = async (case: JSON.t) => {
  let description = case->textOf("description")->Option.getOr("")
  let size =
    case->member("given")->Option.flatMap(g => g->member("size"))->Option.flatMap(JSON.Decode.float)
  let served = Served.make(~size=size->Option.getOr(largest))
  let captured = dict{}
  let missed = []
  let steps = case->member("steps")->Option.flatMap(JSON.Decode.array)->Option.getOr([])
  for at in 0 to Array.length(steps) - 1 {
    let step = steps->Array.getUnsafe(at)
    switch step->member("wait")->Option.flatMap(JSON.Decode.float) {
    | Some(wait) => served.clock := served.clock.contents +. wait
    | None =>
      let operation = step->textOf("call")->Option.getOr("")
      let input = resolved(
        description,
        at,
        "input",
        step->member("input")->Option.getOr(JSON.Null),
        captured,
        ~now=served.clock.contents,
      )
      let (_, answer) = await served->Served.call(operation, JSON.stringify(input))
      let expect = step->member("expect")->Option.getOr(JSON.Null)
      if !held(expect, answer, captured) {
        let shown = JSON.stringify(answer)->String.slice(~start=0, ~end=400)
        missed->Array.push(`${description}: step ${Int.toString(at)}, ${operation}, ${shown}`)
      }
    }
  }
  missed
}

test("every database sample holds", async () => {
  let cases = samples->Array.flatMap(path => {
    let sample = fromRoot(path)
    deepEqual(sample->textOf("interface"), Some("database"))
    sample->member("cases")->Option.flatMap(JSON.Decode.array)->Option.getOr([])
  })
  let missed = []
  for c in 0 to Array.length(cases) - 1 {
    missed->Array.pushMany(await ran(cases->Array.getUnsafe(c)))
  }
  deepEqual((Array.length(cases), missed), (11, []))
})
