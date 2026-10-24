/***
 * A call read and its answer written, JSON or CBOR as the request asks, each answer one envelope
 * its status tells, as the Worker `driver`'s `answer.res` writes them, RFCs vr5lw and ge55b.
 */
module Contracts = Envelope.Contracts
module Cbor = Codec.Cbor

/** The two forms a body is written in. */
type form = Json | Cbor

let media = form =>
  switch form {
  | Json => "application/json"
  | Cbor => "application/cbor"
  }

/** The form a media type names, its parameters passed over. */
let named = media =>
  switch media
  ->String.split(";")
  ->Array.get(0)
  ->Option.map(m => m->String.trim->String.toLowerCase) {
  | Some("application/json") => Some(Json)
  | Some("application/cbor") => Some(Cbor)
  | Some(_) | None => None
  }

/** The form of a request's body, and the one its answer is written in. */
type forms = {body: option<form>, answer: form}

/** The answer's form is the first `Accept` names, else the body's, else CBOR, RFC vr5lw. */
let formsOf = (~contentType, ~accept) => {
  let body = contentType->Option.flatMap(named)
  let accepted = accept->Option.flatMap(a => a->String.split(",")->Array.findMap(named))
  {body, answer: accepted->Option.getOr(body->Option.getOr(Cbor))}
}

/** An error by its reason, its failure the operation's own or every operation's, else unknown. */
let error = (~declared: array<Contracts.reason>=[], reason, ~message=?): Contracts.Error.t => {
  let known = Array.concat(declared, Contracts.reasons)->Array.find(r => r.name == reason)
  {
    failure: known->Option.mapOr(Contracts.Failure.Unknown, r => r.failure),
    reason,
    message: switch message {
    | Some(message) if message != "" => message
    | Some(_) | None => Contracts.messages->Dict.get(reason)->Option.getOr(reason)
    },
  }
}

let malformed = message => error("malformed", ~message)

/** Where a value read stands, `input.items[0].id`. */
let place = (at: array<Envelope.Malformed.step>) =>
  at->Array.reduce("", (text, step) =>
    switch step {
    | Field(name) if text == "" => name
    | Field(name) => `${text}.${name}`
    | Index(index) => `${text}[${Int.toString(index)}]`
    | Key(key) => `${text}[${JSON.stringify(JSON.String(key))}]`
    }
  )

/** Why a call was not read, as its `malformed` message says it. */
let unread = (why: Envelope.Malformed.t) =>
  malformed(
    why.at == [] ? `expected ${why.expected}` : `expected ${why.expected} at ${place(why.at)}`,
  )

/** The call a body holds in its form, read by the interface's own readers. */
let call = (form, bytes, ~fromJson, ~fromCbor) =>
  switch form {
  | Json =>
    switch Web.fromUtf8(bytes)->Option.map(text => JSON.parseOrThrow(text)) {
    | Some(json) => fromJson(json)->Result.mapError(unread)
    | None => Error(malformed("the body is not JSON"))
    | exception JsExn(_) => Error(malformed("the body is not JSON"))
    }
  | Cbor =>
    switch Cbor.decode(bytes) {
    | Ok(value) => fromCbor(value)->Result.mapError(unread)
    | Error(_) => Error(malformed("the body is not one CBOR data item"))
    }
  }

/** The status an answer is sent with, which says as much to what stands between, RFC ge55b. */
let status = (error: Contracts.Error.t) =>
  switch (error.failure, error.reason) {
  | (Rejected, "denied") => 403
  | (Rejected, "not_found") => 404
  | (Rejected, _) => 400
  | (Unavailable, "rate_limited") => 429
  | (Unavailable, _) => 503
  | (Unknown, _) => 500
  }

/** An answer's bytes in its form, none where its CBOR cannot be written. */
let bytes = (answer, form, ~toJson, ~toCbor) =>
  switch form {
  | Json => Some(Contracts.Answer.toJson(answer, toJson)->JSON.stringify->Web.utf8)
  | Cbor => Contracts.Answer.toCbor(answer, toCbor)->Cbor.encode->Result.mapOr(None, b => Some(b))
  }

/** An answer written as a response; an output that cannot be written is a `fault`. */
let written = (answer: Contracts.Answer.t<'o>, form, ~toJson, ~toCbor) => {
  let code = switch answer {
  | Success(_) => 200
  | Error(e) => status(e)
  }
  let respond = (code, bytes) =>
    Web.response(bytes, {status: code, headers: dict{"content-type": media(form)}})
  switch bytes(answer, form, ~toJson, ~toCbor) {
  | Some(bytes) => respond(code, bytes)
  | None =>
    let fault = error("fault", ~message="the answer could not be written")
    respond(
      status(fault),
      bytes(Contracts.Answer.Error(fault), form, ~toJson, ~toCbor)->Option.getOr(
        Uint8Array.fromLength(0),
      ),
    )
  }
}

/** An error written before any operation is reached, a denial or a call not as it is written. */
let refused = (error, form) =>
  written(
    Contracts.Answer.Error(error),
    form,
    ~toJson=Contracts.DatabaseRewound.toJson,
    ~toCbor=Contracts.DatabaseRewound.toCbor,
  )
