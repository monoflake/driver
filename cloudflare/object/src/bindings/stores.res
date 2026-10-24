/***
 * What the Worker takes of D1 and R2, as https://developers.cloudflare.com/d1/worker-api/ and
 * https://developers.cloudflare.com/r2/api/workers/workers-api-reference/ document them.
 */
@notUndefined
type database
type statement

/** A value bound to a statement, text, a number or none. */
@unboxed
type value = Text(string) | Number(float) | @as(null) Null

@send external prepare: (database, string) => statement = "prepare"
@send @variadic external bind: (statement, array<value>) => statement = "bind"
/** The first row, its columns read as the caller's record names them. */
@send external first: statement => promise<Nullable.t<'row>> = "first"

type rows<'row> = {results: array<'row>}
@send external all: statement => promise<rows<'row>> = "all"

/** What a statement run changed, the rows it wrote. */
type meta = {changes: float}
type ran = {meta: meta}
@send external run: statement => promise<ran> = "run"

@notUndefined
type bucket

/** An object as R2 answers it, its body read where a get gave one. */
type stored
@get external key: stored => string = "key"
@get external size: stored => float = "size"
@send external storedBuffer: stored => promise<ArrayBuffer.t> = "arrayBuffer"

type range = {offset: float, length: float}
type getOptions = {range?: range}
type listOptions = {prefix: string, startAfter?: string, delimiter?: string, limit: int}
type listed = {objects: array<stored>, truncated: bool, delimitedPrefixes: array<string>}

@send external headRaw: (bucket, string) => promise<Nullable.t<stored>> = "head"
@send external getRaw: (bucket, string, getOptions) => promise<Nullable.t<stored>> = "get"
@send external putRaw: (bucket, string, Uint8Array.t) => promise<Nullable.t<stored>> = "put"
@send external deleteRaw: (bucket, string) => promise<unit> = "delete"
@send external deleteAllRaw: (bucket, array<string>) => promise<unit> = "delete"
@send external listRaw: (bucket, listOptions) => promise<listed> = "list"

/** Why R2 did not answer, by the code its message ends with. */
type failure =
  | Limited
  | Unsatisfiable
  | Failed(string)

/** The message a write to a key within a second of another is answered with. */
let limited = "R2 takes one write a second to a key, so send this write again in a second"

/**
 * A thrown error read by its code, 10058 a key written too often and 10039 a range past the end,
 * as https://developers.cloudflare.com/r2/api/error-codes/ ends each message with it.
 */
let failureOf = (e: JsExn.t) => {
  let message = e->JsExn.message->Option.getOr("R2 failed")
  switch message {
  | m if m->String.endsWith("(10058)") => Limited
  | m if m->String.endsWith("(10039)") => Unsatisfiable
  | m => Failed(m)
  }
}

let attempt = async run =>
  switch await run() {
  | value => Ok(value)
  | exception JsExn(e) => Error(failureOf(e))
  }

/** An object's metadata alone, none where the key holds nothing. */
let head = (bucket, key) => attempt(async () => (await bucket->headRaw(key))->Nullable.toOption)

/** An object read whole or in a range, beside its whole size, none where the key holds nothing. */
let get = (bucket, key, ~range=?) =>
  attempt(async () =>
    switch (await bucket->getRaw(key, {range: ?range}))->Nullable.toOption {
    | Some(found) => Some((Uint8Array.fromBuffer(await found->storedBuffer), found->size))
    | None => None
    }
  )

/** An object written, as R2 answers it where it gives an answer. */
let put = (bucket, key, bytes) =>
  attempt(async () => (await bucket->putRaw(key, bytes))->Nullable.toOption)

let delete = (bucket, key) => attempt(() => bucket->deleteRaw(key))

/** Keys deleted in one call, at most 1000 as R2 takes. */
let deleteAll = (bucket, keys) => attempt(() => bucket->deleteAllRaw(keys))

/** The prefixes up to the first `/` of every key, at most `limit`. */
let prefixes = (bucket, ~limit) =>
  attempt(async () =>
    (await bucket->listRaw({prefix: "", delimiter: "/", limit})).delimitedPrefixes
  )

/** Keys under a prefix after one, at most `limit`, R2's `startAfter` a name as the contract's. */
let list = (bucket, ~prefix, ~after=?, ~limit) =>
  attempt(() => bucket->listRaw({prefix, startAfter: ?after, limit}))
