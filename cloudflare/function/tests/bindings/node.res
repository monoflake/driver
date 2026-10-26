/***
 * What the tests take of node, its test runner, strict assertions, a request's form read back, and
 * a module imported from its source.
 */
@module("node:test") external test: (string, unit => promise<unit>) => unit = "test"

@module("node:assert/strict")
external deepEqual: ('a, 'a, ~message: string=?) => unit = "deepStrictEqual"
@module("node:assert/strict") external ok: (bool, ~message: string=?) => unit = "ok"

/** A body sent as a form or as text, read back as the test wrote it. */
external asForm: Web.body => Web.form = "%identity"
external asText: Web.body => string = "%identity"

type file
@send external field: (Web.form, string) => Nullable.t<string> = "get"
@send external file: (Web.form, string) => Nullable.t<file> = "get"
@get external fileType: file => string = "type"
@get external fileName: file => string = "name"
@send external fileBuffer: file => promise<ArrayBuffer.t> = "arrayBuffer"
@send external keys: Web.form => Iterator.t<string> = "keys"

/** A file's bytes, whole. */
let fileBytes = async file => Uint8Array.fromBuffer(await file->fileBuffer)

/** A response answering a request as Cloudflare's API would, its status and its text. */
type responseInit = {status: int}
@new external response: (string, responseInit) => Web.response = "Response"

type request
type requestInit = {headers: dict<string>}
@new external request: (string, requestInit) => request = "Request"
type answer
@get external answerStatus: answer => int = "status"
type headers
@get external answerHeaders: answer => headers = "headers"
@send external header: (headers, string) => Nullable.t<string> = "get"
@send external answerBytes: answer => promise<ArrayBuffer.t> = "arrayBuffer"
type worker = {fetch: request => answer}
type imported = {default: worker}
@val external importModule: string => promise<imported> = "import"

/** A module's default export, imported from its source text. */
let imported = source => importModule("data:text/javascript," ++ Web.encodeURIComponent(source))

/** Each warning logged until the second is called, which gives `console.warn` back. */
let warned: unit => (array<string>, unit => unit) = %raw(`() => {
  const said = []
  const kept = console.warn
  console.warn = (...parts) => { said.push(parts.join(" ")) }
  return [said, () => { console.warn = kept }]
}`)

type url
@new external urlIn: (string, string) => url = "URL"
@val external importMetaUrl: string = "import.meta.url"
@module("node:url") external pathOf: url => string = "fileURLToPath"
@module("node:fs") external readText: (string, @as("utf8") _) => string = "readFileSync"

/** A file's JSON by its path from the repository's root, four directories above this file. */
let fromRoot = path =>
  JSON.parseOrThrow(readText(pathOf(urlIn(`../../../../${path}`, importMetaUrl))))

/**
 * The global `fetch` answered by `answer` until the second is called, throwing as workerd does
 * when it is called with a `this` other than the global object.
 */
let fetchAnswering: (
  (string, Web.init) => promise<Web.response>
) => unit => unit = %raw(`answer => {
  const kept = globalThis.fetch
  globalThis.fetch = function (url, init) {
    if (this !== undefined && this !== globalThis)
      throw new TypeError("Illegal invocation: function called with incorrect this reference")
    return answer(url, init)
  }
  return () => { globalThis.fetch = kept }
}`)
