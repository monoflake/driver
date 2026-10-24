/*** What the driver takes of the web's APIs, a request read, a response written and a fetch. */
type request
type response
type headers

@get external url: request => string = "url"
@get external method_: request => string = "method"
@get external requestHeaders: request => headers = "headers"
@send external header: (headers, string) => Nullable.t<string> = "get"
@send external requestBuffer: request => promise<ArrayBuffer.t> = "arrayBuffer"

/** A request's body whole. */
let bytesOf = async request => Uint8Array.fromBuffer(await request->requestBuffer)

type responseInit = {status: int, headers: dict<string>}
@new external response: (Uint8Array.t, responseInit) => response = "Response"
@get external status: response => int = "status"
@send external responseBuffer: response => promise<ArrayBuffer.t> = "arrayBuffer"

/** A response's body whole. */
let responseBytes = async response => Uint8Array.fromBuffer(await response->responseBuffer)

type parts
@new external parts: string => parts = "URL"
@get external pathname: parts => string = "pathname"
@get external protocol: parts => string = "protocol"

/** What fetches an address, the runtime's `fetch`. */
@val external fetch: string => promise<response> = "fetch"

type encoder
@new external encoder: unit => encoder = "TextEncoder"
@send external encode: (encoder, string) => Uint8Array.t = "encode"

/** A text's UTF-8. */
let utf8 = text => encoder()->encode(text)

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
