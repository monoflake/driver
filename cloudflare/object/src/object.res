/***
 * The Worker `object`, every call held to the binding's token before it is read, then answered on
 * the bucket `objects` as driver(machine)'s `served.rs` answers its bucket, RFC nrs5v.
 */
module Contracts = Envelope.Contracts
module Interface = Contracts.Interface.Object

type database = Stores.database
type bucket = Stores.bucket

type env = {
  @as("DB") db: database,
  @as("OBJECTS") objects: bucket,
  @as("BINDING") binding: string,
}

/** The most an object holds in bytes, the contract's 16 MiB. */
let most =
  16 * 1024 * 1024

/** The most a call's body may be, a content at its bound in base64url beside 2 MiB for the rest. */
let largest =
  (most + 2) / 3 * 4 + 2 * 1024 * 1024

/** The most names one list answers, the contract's default, however many it asks. */
let page = 1000

/** An answer of an operation, its error by a reason the operation declares and its message. */
let refused = (operation: Contracts.operation, reason, ~message=?) => Contracts.Answer.Error(
  Answer.error(~declared=operation.reasons, reason, ~message?),
)

/** What R2 did not do, a fault, a key written too often asking for the write again. */
let failed = (operation: Contracts.operation, failure: Stores.failure) =>
  switch failure {
  | Limited => refused(operation, "fault", ~message=Stores.limited)
  | Unsatisfiable => refused(operation, "fault", ~message="the range read was not satisfiable")
  | Failed(message) => refused(operation, "fault", ~message)
  }

/** An object's key in the bucket, under its item's prefix. */
let keyOf = (item: Held.item, name) => Held.prefixOf(item.id) ++ name

let written = async (env, item: option<Held.item>, input: Contracts.ObjectWrite.t) => {
  let size = TypedArray.length(input.content)
  switch item {
  | _ if size > most =>
    refused(
      Interface.write,
      "too_large",
      ~message=`an object is at most ${Int.toString(most)} bytes`,
    )
  | None => refused(Interface.write, "storage_full", ~message="the binding holds no bucket")
  | Some(item) =>
    let name = input.name
    let before = await Held.counted(env.db, ~item=item.id, name)
    if await Held.take(env.db, ~item, ~name, ~size=Int.toFloat(size)) {
      let key = keyOf(item, name)
      let put = await Stores.put(env.objects, key, input.content)
      // The count follows what R2 holds for the key once the put is done, whatever ran between.
      switch (put, await Stores.head(env.objects, key)) {
      | (_, Ok(stored)) =>
        await Held.settle(env.db, ~item=item.id, ~name, stored->Option.map(Stores.size))
      // A put that failed beside its head leaves the count as it stood before the write.
      | (Error(_), Error(_)) => await Held.settle(env.db, ~item=item.id, ~name, before)
      // A put that held beside a head that failed leaves the count as taken, the size written.
      | (Ok(_), Error(_)) => ()
      }
      switch put {
      | Ok(_) => Contracts.Answer.Success(({}: Contracts.ObjectWritten.t))
      | Error(failure) => failed(Interface.write, failure)
      }
    } else {
      refused(Interface.write, "storage_full")
    }
  }
}

let notFound = () => refused(Interface.read, "not_found")

/** An object's size beside no bytes, as a range of none or past its end reads. */
let empty = async (env, key) =>
  switch await Stores.head(env.objects, key) {
  | Ok(Some(stored)) =>
    let content = Uint8Array.fromLength(0)
    Contracts.Answer.Success(({content, size: stored->Stores.size}: Contracts.ObjectContent.t))
  | Ok(None) => notFound()
  | Error(failure) => failed(Interface.read, failure)
  }

/** An object read whole or in a range cut at its end, as a range past it is read empty. */
let read = async (env, item: option<Held.item>, input: Contracts.ObjectRead.t) =>
  switch item {
  | None => notFound()
  | Some(item) =>
    let key = keyOf(item, input.name)
    switch input.range {
    // A range of no bytes never reaches R2, so nothing rests on how it would answer one.
    | Some(range) if range.length == 0. => await empty(env, key)
    | range =>
      let range = range->Option.map((r): Stores.range => {offset: r.start, length: r.length})
      switch await Stores.get(env.objects, key, ~range?) {
      | Ok(Some((content, size))) =>
        Contracts.Answer.Success(({content, size}: Contracts.ObjectContent.t))
      | Ok(None) => notFound()
      // R2 refuses a range starting at or past the end, which reads nothing here.
      | Error(Unsatisfiable) => await empty(env, key)
      | Error((Limited | Failed(_)) as failure) => failed(Interface.read, failure)
      }
    }
  }

let described = async (env, item: option<Held.item>, input: Contracts.ObjectName.t) =>
  switch item {
  | None => Contracts.Answer.Success(({}: Contracts.ObjectDescribed.t))
  | Some(item) =>
    switch await Stores.head(env.objects, keyOf(item, input.name)) {
    | Ok(stored) =>
      let size = stored->Option.map(Stores.size)
      Contracts.Answer.Success(({size: ?size}: Contracts.ObjectDescribed.t))
    | Error(failure) => failed(Interface.describe, failure)
    }
  }

let deleted = async (env, item: option<Held.item>, input: Contracts.ObjectName.t) =>
  switch item {
  | None => Contracts.Answer.Success(({}: Contracts.ObjectDeleted.t))
  | Some(item) =>
    switch await Stores.delete(env.objects, keyOf(item, input.name)) {
    | Ok() =>
      await Held.forget(env.db, ~item=item.id, input.name)
      Contracts.Answer.Success(({}: Contracts.ObjectDeleted.t))
    | Error(failure) => failed(Interface.delete, failure)
    }
  }

/** The names under a prefix after `after`, `next` the last of them where R2 holds more. */
let listed = async (env, item: option<Held.item>, input: Contracts.ObjectList.t) =>
  switch item {
  | None => Contracts.Answer.Success(({objects: []}: Contracts.ObjectListed.t))
  | Some(item) =>
    let limit = switch input.limit {
    | None => page
    | Some(0.) => %todo("lnxbp")
    | Some(limit) => Math.Int.min(Float.toInt(limit), page)
    }
    let under = Held.prefixOf(item.id)
    let after = input.after->Option.map(after => under ++ after)
    switch await Stores.list(env.objects, ~prefix=under ++ input.prefix, ~after?, ~limit) {
    | Ok({objects, truncated}) =>
      let objects = objects->Array.map((stored): Contracts.ObjectListedOne.t => {
        name: stored->Stores.key->String.slice(~start=String.length(under)),
        size: stored->Stores.size,
      })
      let next = truncated ? objects->Array.at(-1)->Option.map(o => o.name) : None
      Contracts.Answer.Success(({objects, ?next}: Contracts.ObjectListed.t))
    | Error(failure) => failed(Interface.list, failure)
    }
  }

let operationOf = (call: Interface.call) =>
  switch call {
  | Write(_) => "write"
  | Read(_) => "read"
  | Describe(_) => "describe"
  | Delete(_) => "delete"
  | List(_) => "list"
  }

/** A call on the bucket, against the one `object` item the list holds. */
let stored = async (env, item, call: Interface.call, form) =>
  switch call {
  | Write(input) =>
    (await written(env, item, input))->Answer.written(
      form,
      ~toJson=Contracts.ObjectWritten.toJson,
      ~toCbor=Contracts.ObjectWritten.toCbor,
    )
  | Read(input) =>
    (await read(env, item, input))->Answer.written(
      form,
      ~toJson=Contracts.ObjectContent.toJson,
      ~toCbor=Contracts.ObjectContent.toCbor,
    )
  | Describe(input) =>
    (await described(env, item, input))->Answer.written(
      form,
      ~toJson=Contracts.ObjectDescribed.toJson,
      ~toCbor=Contracts.ObjectDescribed.toCbor,
    )
  | Delete(input) =>
    (await deleted(env, item, input))->Answer.written(
      form,
      ~toJson=Contracts.ObjectDeleted.toJson,
      ~toCbor=Contracts.ObjectDeleted.toCbor,
    )
  | List(input) =>
    (await listed(env, item, input))->Answer.written(
      form,
      ~toJson=Contracts.ObjectListed.toJson,
      ~toCbor=Contracts.ObjectListed.toCbor,
    )
  }

/** A call of a caller held to a token, as its path and its body say it. */
let called = async (request, env, forms: Answer.forms, parts, ~holding) => {
  let early = error => Answer.refused(error, forms.answer)
  switch (parts, request->Web.method_, forms.body) {
  | (["", "object", operation], "POST", Some(form)) =>
    switch await request->Web.bytesOf(~largest) {
    | None => early(Answer.malformed(`a call's body is at most ${Int.toString(largest)} bytes`))
    | Some(bytes) =>
      switch Answer.call(form, bytes, ~fromJson=Interface.fromJson, ~fromCbor=Interface.fromCbor) {
      | Ok(envelope) if operationOf(envelope.call) == operation =>
        await stored(env, holding, envelope.call, forms.answer)
      | Ok(envelope) =>
        let named = operationOf(envelope.call)
        early(Answer.malformed(`the path names ${operation} and the call ${named}`))
      | Error(error) => early(error)
      }
    }
  | (["", "object", _], "POST", None) =>
    early(Answer.malformed("a call's body is application/json or application/cbor"))
  | (["", other, _], "POST", _) => early(Answer.malformed(`no interface ${other}, one of object`))
  | _ => early(Answer.malformed("a call is POST /object/{operation}"))
  }
}

/** A call of a Worker installed whole, held to the binding's token before it is read. */
let held = async (request, env, forms: Answer.forms) => {
  let header = name => request->Web.requestHeaders->Web.header(name)->Nullable.toOption
  let early = error => Answer.refused(error, forms.answer)
  // An unset or empty BINDING holds no token, so every caller is denied.
  let given =
    Secrets.read(env.binding)
    ->Nullable.toOption
    ->Option.map(binding => binding->String.trim->String.toLowerCase)
    ->Option.filter(binding => binding != "")
  // A caller not yet held to a token is told nothing of why its token could not be read.
  let held = switch Bearer.hashOf(header("authorization")) {
  | Some(hash) =>
    switch await Held.holds(env.db, ~given, hash) {
    | held => Ok(held)
    | exception Held.Unkept(_) => Error()
    | exception JsExn(_) => Error()
    }
  | None => Ok(false)
  }
  let parts = Web.parts(request->Web.url)->Web.pathname->String.split("/")
  switch held {
  | Error() => early(Answer.error("fault", ~message="the call's token was not checked"))
  | Ok(false) => early(Answer.error("denied"))
  | Ok(true) =>
    let holding = await Held.item(env.db)
    let answer = await called(request, env, forms, parts, ~holding)
    // A batch a fault left is cleared by a later request, so the call's answer stands.
    switch await Cleared.clear(env.db, env.objects) {
    | () => ()
    | exception JsExn(_) => ()
    }
    answer
  }
}

/** A call answered, denied unread where the Worker is not installed whole, as an unset BINDING. */
let serve = (request, env, forms: Answer.forms) =>
  Installed.whole(env)
    ? held(request, env, forms)
    : Promise.resolve(Answer.refused(Answer.error("denied"), forms.answer))

let fetch = async (request, env) => {
  let header = name => request->Web.requestHeaders->Web.header(name)->Nullable.toOption
  let forms = Answer.formsOf(~contentType=header("content-type"), ~accept=header("accept"))
  let fault = message => Answer.refused(Answer.error("fault", ~message), forms.answer)
  switch await serve(request, env, forms) {
  | response => response
  | exception Held.Unkept(message) => fault(message)
  | exception JsExn(e) => fault(e->JsExn.message->Option.getOr("the Worker failed while answering"))
  }
}
