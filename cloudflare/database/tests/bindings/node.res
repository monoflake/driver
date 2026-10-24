/***
 * What the tests take of node, its test runner, strict assertions, files, its SQLite standing in
 * for D1 with its batches and Time Travel's snapshots, a clock, and Cloudflare's API answered.
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

/** A path from this block's directory, this file at `cloudflare/database/tests/bindings/`. */
let fromBlock = path => pathOf(urlIn(`../../${path}`, importMetaUrl))

/** A file's JSON by its path from the repository's root, two directories above this block's. */
let fromRoot = path => JSON.parseOrThrow(readText(fromBlock(`../../${path}`)))

type sqlite
@module("node:sqlite") @new external openSqlite: string => sqlite = "DatabaseSync"
@send external exec: (sqlite, string) => unit = "exec"

/**
 * node's SQLite answering as D1 does, a batch one transaction, its rows, meta and errors worded as
 * D1's, each batch done kept as a snapshot at the clock's time for `restore` to take back.
 */
let asDatabase: (sqlite, ref<float>) => Database.database = %raw(`(db, clock) => {
  const codes = { 1: "ERROR", 8: "READONLY", 13: "FULL", 18: "TOOBIG", 19: "CONSTRAINT",
    20: "MISMATCH", 25: "RANGE" }
  const failed = e => {
    const code = codes[(e.errcode ?? 1) & 0xff] ?? "ERROR"
    return new Error("D1_ERROR: " + e.message + ": SQLITE_" + code)
  }
  const cell = v => typeof v === "bigint" ? Number(v) : v instanceof Uint8Array ? Array.from(v) : v
  const bound = v => typeof v === "number" && Number.isInteger(v) ? BigInt(v) : v
  const one = (sql, values) => {
    const statement = db.prepare(sql)
    statement.setReadBigInts(true)
    return statement
  }
  const size = () => db.prepare(
    "SELECT page_count * page_size AS size FROM pragma_page_count(), pragma_page_size()").get().size
  const total = () => Number(db.prepare("SELECT total_changes() AS n").get().n)
  const schema = () => Number(db.prepare("PRAGMA schema_version").get().schema_version)
  const ran = (sql, values) => {
    const before = [total(), schema()]
    const statement = one(sql, values)
    const args = values.map(bound)
    let results
    if (statement.columns().length > 0) {
      results = statement.all(...args).map(row =>
        Object.fromEntries(Object.entries(row).map(([k, v]) => [k, cell(v)])))
    } else {
      statement.run(...args)
      results = []
    }
    const changes = Number(db.prepare("SELECT changes() AS n").get().n)
    const changed_db = total() !== before[0] || schema() !== before[1]
    return { success: true, results, meta: { changes, changed_db, size_after: size() } }
  }
  const snapshots = [{ time: -Infinity, bytes: db.serialize() }]
  const statement = (sql, values) => ({
    sql,
    values,
    bind: (...bound) => statement(sql, bound),
    first: async () => {
      const row = db.prepare(sql).get(...values.map(bound))
      return row ? Object.fromEntries(Object.entries(row).map(([k, v]) => [k, cell(v)])) : null
    },
    all: async () => ({
      results: db.prepare(sql).all(...values.map(bound)).map(row =>
        Object.fromEntries(Object.entries(row).map(([k, v]) => [k, cell(v)]))),
    }),
    run: async () => {
      try { return ran(sql, values) } catch (e) { throw failed(e) }
    },
  })
  return {
    prepare: sql => statement(sql, []),
    batch: async statements => {
      db.exec("BEGIN")
      try {
        const results = statements.map(s => ran(s.sql, s.values))
        db.exec("COMMIT")
        snapshots.push({ time: clock.contents, bytes: db.serialize() })
        return results
      } catch (e) {
        db.exec("ROLLBACK")
        throw failed(e)
      }
    },
    restore: time => {
      const at = snapshots.filter(s => s.time <= time).at(-1)
      db.deserialize(at.bytes)
      clock.contents += 1
      snapshots.push({ time: clock.contents, bytes: db.serialize() })
    },
    batches: () => snapshots.length - 1,
  }
}`)

/** The database taken back to the last batch done by a time, the restore kept as a batch. */
@send external restoreTo: (Database.database, float) => unit = "restore"

/** How many batches were done and restores made, every one kept as a snapshot. */
@send external batches: Database.database => int = "batches"

/** node's SQLite in memory with the driver's migrations applied in order. */
let migrated = () => {
  let db = openSqlite(":memory:")
  let migrations = fromBlock("../migrations")
  list(migrations)
  ->Array.filter(name => name->String.endsWith(".sql"))
  ->Array.toSorted(String.compare)
  ->Array.forEach(name => db->exec(readText(`${migrations}/${name}`)))
  db
}

/** Statements run as written, to put an item or a token where a test needs it. */
let run: (sqlite, string, array<JSON.t>) => unit = %raw(`(db, sql, values) => {
  db.prepare(sql).run(...values)
}`)

/** Every row a statement reads, each a column's name to its value. */
let rows: (sqlite, string) => array<dict<JSON.t>> = %raw(`(db, sql) =>
  db.prepare(sql).all().map(row => ({ ...row }))
`)

/** The clock every `Date.now` reads, set by a test. */
let clockedBy: ref<float> => unit = %raw(`clock => { Date.now = () => clock.contents }`)

type requestInit = {method: string, headers: dict<string>, body?: Uint8Array.t}
@new external request: (string, requestInit) => Web.request = "Request"
type responseInit = {status: int}
@new external response: (string, responseInit) => Web.response = "Response"

/** A request sent out by the Worker, its method, its address and its headers. */
type sent = {url: string, init: Web.init}

/** Every request the Worker sends out answered by `answer`, each kept in `sent`. */
let answering: (array<sent>, (string, Web.init) => promise<Web.response>) => unit = %raw(`
  (sent, answer) => {
    globalThis.fetch = async (url, init) => {
      sent.push({ url, init })
      return answer(url, init)
    }
  }
`)

type params
@get external searchParams: Web.parts => params = "searchParams"
@send external searchGet: (params, string) => Nullable.t<string> = "get"
