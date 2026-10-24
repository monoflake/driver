/***
 * The stub a stopped deployment's Worker runs, answering every request 503 `stopped` in the form a
 * call asks, as driver(machine)'s answers choose it, RFC nrs5v.
 */
module Contracts = Envelope.Contracts

let message = Contracts.messages->Dict.get("stopped")->Option.getOr("stopped")

/** The answer as JSON writes it. */
let json = Contracts.Answer.toJson(
  Contracts.Answer.Error({failure: Unavailable, reason: "stopped", message}),
  (_: unit) => JSON.Null,
)->JSON.stringify

/** A CBOR text string's head and its UTF-8, RFC 8949 section 3.1. */
let text = value => {
  let utf8 = Web.utf8(value)
  let length = TypedArray.length(utf8)
  let bytes = Array.fromInitializer(~length, at => utf8->TypedArray.get(at)->Option.getOr(0))
  let head = length < 24 ? [0x60 + length] : [0x78, length]
  Array.concat(head, bytes)
}

/** The answer as CBOR writes it, the error's case 2 with its failure, reason and message. */
let cbor = Array.concat(
  [0xa4, 0x00, 0x02, 0x01, 0x02, 0x02],
  Array.concat(text("stopped"), Array.concat([0x03], text(message))),
)

let source = `const json = ${JSON.stringify(JSON.String(json))};
const cbor = new Uint8Array([${cbor->Array.map(b => Int.toString(b))->Array.join(", ")}]);
const forms = ["application/json", "application/cbor"];
const named = (media) =>
\t(media ?? "").split(",").map((m) => m.split(";")[0].trim().toLowerCase());
const formOf = (media) => named(media).find((m) => forms.includes(m));
const asked = (headers) =>
\tformOf(headers.get("accept")) ?? formOf(headers.get("content-type")) ?? "application/cbor";
export default {
\tfetch(request) {
\t\tconst form = asked(request.headers);
\t\tconst body = form === "application/json" ? json : cbor;
\t\treturn new Response(body, { status: 503, headers: { "content-type": form } });
\t},
};
`

let bundle: Script.bundle = {
  modules: [{name: "stopped.js", kind: Es, bytes: Web.utf8(source)}],
  compatibilityDate: "2026-10-21",
  compatibilityFlags: [],
}
