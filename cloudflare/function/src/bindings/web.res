/*** What the function kind takes of the web's APIs, requests, forms, UTF-8 and SHA-256. */
type response
type form
type blob
type blobOptions = {@as("type") type_: string}

@new external form: unit => form = "FormData"
@send external append: (form, string, string) => unit = "append"
@send external appendFile: (form, string, blob, string) => unit = "append"
@new external blob: (array<Uint8Array.t>, blobOptions) => blob = "Blob"

/** What a request is sent with, a form or text. */
type body
external formBody: form => body = "%identity"
external textBody: string => body = "%identity"
type init = {method: string, headers: dict<string>, body?: body}

/** What sends a request and gives its response, the runtime's `fetch` or a test's. */
type send = (string, init) => promise<response>
@val external fetch: send = "fetch"

@get external status: response => int = "status"
@send external text: response => promise<string> = "text"

@val external encodeURIComponent: string => string = "encodeURIComponent"

type decoder
type decoderOptions = {fatal: bool}
@new external decoder: (string, decoderOptions) => decoder = "TextDecoder"
@send external decode: (decoder, Uint8Array.t) => string = "decode"

/** UTF-8 read as text, none where it is not UTF-8. */
let fromUtf8 = bytes =>
  switch decoder("utf-8", {fatal: true})->decode(bytes) {
  | text => Some(text)
  | exception JsExn(_) => None
  }

type encoder
@new external encoder: unit => encoder = "TextEncoder"
@send external encode: (encoder, string) => Uint8Array.t = "encode"

/** A text's UTF-8. */
let utf8 = text => encoder()->encode(text)

@val @scope(("crypto", "subtle"))
external digest: (string, Uint8Array.t) => promise<ArrayBuffer.t> = "digest"

/** Bytes' SHA-256. */
let sha256 = async bytes => Uint8Array.fromBuffer(await digest("SHA-256", bytes))
