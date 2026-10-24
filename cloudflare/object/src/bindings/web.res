/*** What the Worker takes of the web's APIs, a request read, a response written and UTF-8. */
type request
type response
type headers

@get external url: request => string = "url"
@get external method_: request => string = "method"
@get external requestHeaders: request => headers = "headers"
@send external header: (headers, string) => Nullable.t<string> = "get"

type stream
type reader
type chunk = {done: bool, value: Nullable.t<Uint8Array.t>}
@get external requestBody: request => Nullable.t<stream> = "body"
@send external reader: stream => reader = "getReader"
@send external read: reader => promise<chunk> = "read"
@send external cancel: reader => promise<unit> = "cancel"

/** Bytes copied into others from an offset by `set`, never number by number. */
@send external copyInto: (Uint8Array.t, Uint8Array.t, int) => unit = "set"

/** A request's body read as it comes, none once it passes `largest` bytes, read no further. */
let bytesOf = async (request, ~largest) =>
  switch request->requestBody->Nullable.toOption {
  | None => Some(Uint8Array.fromLength(0))
  | Some(stream) =>
    let reader = stream->reader
    let chunks = []
    let total = ref(0)
    let over = ref(false)
    let ended = ref(false)
    while !ended.contents && !over.contents {
      let chunk = await reader->read
      switch chunk.value->Nullable.toOption {
      | Some(bytes) if !chunk.done =>
        total := total.contents + TypedArray.length(bytes)
        total.contents > largest ? over := true : chunks->Array.push(bytes)
      | Some(_) | None => ended := true
      }
    }
    if over.contents {
      await reader->cancel
      None
    } else {
      let whole = Uint8Array.fromLength(total.contents)
      chunks
      ->Array.reduce(0, (at, bytes) => {
        whole->copyInto(bytes, at)
        at + TypedArray.length(bytes)
      })
      ->ignore
      Some(whole)
    }
  }

type responseInit = {status: int, headers: dict<string>}
@new external response: (Uint8Array.t, responseInit) => response = "Response"
@get external status: response => int = "status"
@send external responseBuffer: response => promise<ArrayBuffer.t> = "arrayBuffer"

/** A response's body whole. */
let responseBytes = async response => Uint8Array.fromBuffer(await response->responseBuffer)

@get external responseHeaders: response => headers = "headers"

type parts
@new external parts: string => parts = "URL"
@get external pathname: parts => string = "pathname"

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
