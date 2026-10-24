/***
 * What the tests take of node, its test runner, strict assertions, files, its SQLite in memory
 * standing in for D1, requests made, and the global `fetch` answered by a test.
 */
@module("node:test") external test: (string, unit => promise<unit>) => unit = "test"

@module("node:assert/strict")
external deepEqual: ('a, 'a, ~message: string=?) => unit = "deepStrictEqual"
@module("node:assert/strict") external ok: (bool, ~message: string=?) => unit = "ok"

type url
@new external urlIn: (string, string) => url = "URL"
@val external importMetaUrl: string = "import.meta.url"
@module("node:url") external pathOf: url => string = "fileURLToPath"
@module("node:fs") external readText: (string, @as("utf8") _) => string = "readFileSync"
@module("node:fs") external list: string => array<string> = "readdirSync"

/** A path from this block's directory, this file at `cloudflare/tests/bindings/`. */
let fromBlock = path => pathOf(urlIn(`../../${path}`, importMetaUrl))

type sqlite
@module("node:sqlite") @new external openSqlite: string => sqlite = "DatabaseSync"
@send external exec: (sqlite, string) => unit = "exec"

/** node's SQLite called as the driver calls D1, a batch run as one transaction. */
let asDatabase: sqlite => Driver.database = %raw(`db => {
  const statement = (sql, values) => ({
    bind: (...bound) => statement(sql, bound),
    first: async () => db.prepare(sql).get(...values) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...values) }),
    run: () => db.prepare(sql).run(...values),
  })
  return {
    prepare: sql => statement(sql, []),
    batch: async statements => {
      db.exec("BEGIN")
      try {
        for (const s of statements) s.run()
        db.exec("COMMIT")
      } catch (e) {
        db.exec("ROLLBACK")
        throw e
      }
    },
  }
}`)

/** A database in memory with the driver's migrations applied in order. */
let database = () => {
  let db = openSqlite(":memory:")
  let migrations = fromBlock("migrations")
  list(migrations)
  ->Array.filter(name => name->String.endsWith(".sql"))
  ->Array.toSorted(String.compare)
  ->Array.forEach(name => db->exec(readText(`${migrations}/${name}`)))
  asDatabase(db)
}

type requestInit = {method: string, headers: dict<string>, body?: Uint8Array.t}
@new external request: (string, requestInit) => Web.request = "Request"
@get external responseHeaders: Web.response => Web.headers = "headers"

type sentBody
type fetchInit = {method: string, body?: sentBody}
@send external formField: (sentBody, string) => Nullable.t<string> = "get"
external sentText: sentBody => string = "%identity"
@get external fetchedUrl: 'request => string = "url"
type answer
type answerInit = {status: int}
@new external answerText: (string, answerInit) => answer = "Response"
@new external answerBytes: (Uint8Array.t, answerInit) => answer = "Response"

/** The global `fetch` answered by `answer` until `restore` is called, each address it was asked. */
let replaced: ((string, fetchInit) => promise<answer>) => unit => unit = %raw(`answer => {
  const kept = globalThis.fetch
  globalThis.fetch = async (input, init) =>
    answer(String(input.url ?? input), init ?? { method: "GET" })
  return () => { globalThis.fetch = kept }
}`)

@val @scope(("crypto", "subtle"))
external digest: (string, Uint8Array.t) => promise<ArrayBuffer.t> = "digest"

/** Bytes' SHA-256. */
let sha256 = async bytes => Uint8Array.fromBuffer(await digest("SHA-256", bytes))

/** A file's JSON by its path from the repository's root, the directory above this block's. */
let fromRoot = path => JSON.parseOrThrow(readText(fromBlock(`../${path}`)))
