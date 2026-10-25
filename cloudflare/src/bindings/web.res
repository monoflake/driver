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

@get external responseHeaders: response => headers = "headers"

type parts
@new external parts: string => parts = "URL"
/** An address read against the one it was found at, as a redirect's `Location` is. */
@new external partsIn: (string, string) => parts = "URL"
@get external pathname: parts => string = "pathname"
@get external protocol: parts => string = "protocol"
@get external href: parts => string = "href"

/** A fetch's options, its redirects answered rather than followed where `manual`. */
type fetchInit = {method: string, redirect: string}

/** What fetches an address, the runtime's `fetch`. */
@val external fetch: (string, fetchInit) => promise<response> = "fetch"

type stream
type reader
type chunk = {done: bool, value: Nullable.t<Uint8Array.t>}
@get external body: response => Nullable.t<stream> = "body"
@send external reader: stream => reader = "getReader"
@send external read: reader => promise<chunk> = "read"
@send external cancel: reader => promise<unit> = "cancel"
@send external discard: stream => promise<unit> = "cancel"

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

/** Bytes copied into others from an offset by `set`, never number by number. */
@send external copyInto: (Uint8Array.t, Uint8Array.t, int) => unit = "set"

/** A call's options, its method and its headers. */
type sendInit = {method: string, headers: dict<string>}

/** What sends a call to an API, the runtime's `fetch`. */
@val external send: (string, sendInit) => promise<response> = "fetch"
@send external text: response => promise<string> = "text"
@val external encodeURIComponent: string => string = "encodeURIComponent"
