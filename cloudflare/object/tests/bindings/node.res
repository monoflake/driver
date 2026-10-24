/***
 * What the tests take of node, its test runner, strict assertions, files, its SQLite in memory
 * standing in for D1, a bucket in memory standing in for R2, and requests made.
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

/** A path from this block's directory, this file at `cloudflare/object/tests/bindings/`. */
let fromBlock = path => pathOf(urlIn(`../../${path}`, importMetaUrl))

/** A file's JSON by its path from the repository's root, two directories above this block's. */
let fromRoot = path => JSON.parseOrThrow(readText(fromBlock(`../../${path}`)))

type sqlite
@module("node:sqlite") @new external openSqlite: string => sqlite = "DatabaseSync"
@send external exec: (sqlite, string) => unit = "exec"

/** node's SQLite called as the Worker calls D1, a run telling the rows it changed. */
let asDatabase: sqlite => Object.database = %raw(`db => {
  const statement = (sql, values) => ({
    bind: (...bound) => statement(sql, bound),
    first: async () => db.prepare(sql).get(...values) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...values) }),
    run: async () => ({ meta: { changes: Number(db.prepare(sql).run(...values).changes) } }),
  })
  return { prepare: sql => statement(sql, []) }
}`)

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

/** Every object's size as `objects` counts it, by its item and its name. */
let counted: sqlite => array<(float, string, float)> = %raw(`db =>
  db.prepare("SELECT item, name, size FROM objects ORDER BY item, name").all()
    .map(r => [r.item, r.name, r.size])
`)

/** Statements run as written, to put an item or a token where a test needs it. */
let run: (sqlite, string, array<JSON.t>) => unit = %raw(`(db, sql, values) => {
  db.prepare(sql).run(...values)
}`)

// A bucket in memory answering as R2's binding does by the references `stores.res` names.
// A range of no bytes is not modeled, and `before` sets a hook run once before an operation,
// which fails the operation where it throws.
let bucket: ref<float> => Object.bucket = %raw(`clock => {
  const objects = new Map()
  const encoder = new TextEncoder()
  const order = (a, b) => {
    const x = encoder.encode(a), y = encoder.encode(b)
    for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) return x[i] - y[i]
    return x.length - y.length
  }
  const stored = (key, bytes, range) => ({
    key,
    size: bytes.length,
    arrayBuffer: async () => {
      const part = range ? bytes.slice(range.offset, range.offset + range.length) : bytes
      return part.buffer.slice(part.byteOffset, part.byteOffset + part.byteLength)
    },
  })
  const hooks = new Map()
  const hook = async operation => {
    const run = hooks.get(operation)
    hooks.delete(operation)
    if (run) await run()
  }
  return {
    before: (operation, run) => hooks.set(operation, run),
    failing: (operation, message) =>
      hooks.set(operation, async () => { throw new Error(message) }),
    head: async key => {
      await hook("head")
      return objects.has(key) ? stored(key, objects.get(key).bytes) : null
    },
    get: async (key, options) => {
      const held = objects.get(key)
      if (!held) return null
      const range = options?.range
      if (range && range.length <= 0) throw new Error("get: a range of no bytes is not modeled")
      if (range && range.offset >= held.bytes.length)
        throw new Error("get: Requested byte range is not satisfiable. (10039)")
      return stored(key, held.bytes, range)
    },
    put: async (key, value) => {
      await hook("put")
      const held = objects.get(key)
      if (held && clock.contents - held.written < 1000)
        throw new Error("put: Rate limit exceeded. (10058)")
      const bytes = new Uint8Array(value)
      objects.set(key, { bytes, written: clock.contents })
      return stored(key, bytes)
    },
    delete: async keys => {
      for (const key of [keys].flat()) objects.delete(key)
    },
    list: async ({ prefix, startAfter, delimiter, limit }) => {
      await hook(delimiter === undefined ? "list" : "prefixes")
      const entries = []
      for (const k of [...objects.keys()].sort(order)) {
        const before = startAfter !== undefined && order(k, startAfter) <= 0
        if (!k.startsWith(prefix) || before) continue
        const cut = delimiter === undefined ? -1 : k.indexOf(delimiter, prefix.length)
        const entry = cut < 0 ? { key: k } : { prefix: k.slice(0, cut + delimiter.length) }
        const last = entries[entries.length - 1]
        if (entry.prefix === undefined || last?.prefix !== entry.prefix) entries.push(entry)
      }
      const page = entries.slice(0, limit)
      const truncated = entries.length > limit
      return {
        objects: page.filter(e => e.key).map(e => stored(e.key, objects.get(e.key).bytes)),
        truncated,
        ...(truncated ? { cursor: "opaque" } : {}),
        delimitedPrefixes: page.filter(e => e.prefix).map(e => e.prefix),
      }
    },
    keys: () => [...objects.keys()].sort(order),
  }
}`)

/** Every key the bucket in memory holds, in byte order. */
@send external keys: Object.bucket => array<string> = "keys"

/** A call run once before the bucket's next `head`, `put`, `list`, or `prefixes`, a list by
 * delimiter. */
@send external before: (Object.bucket, string, unit => promise<unit>) => unit = "before"

/** The bucket's next `head`, `put`, `list` or `prefixes` failed with a message, as R2 throws. */
@send external failing: (Object.bucket, string, string) => unit = "failing"

/** A key written to the bucket as it stands, past the Worker. */
@send external placed: (Object.bucket, string, Uint8Array.t) => promise<unit> = "put"

type requestInit = {method: string, headers: dict<string>, body?: Uint8Array.t}
@new external request: (string, requestInit) => Web.request = "Request"

/** A secret the Worker is given unset, as where none was put. */
let unset: string = %raw(`undefined`)

/** A copy of `env` with `vars` set beside its own fields, as install sets a Worker's variables. */
@val external assignedOf: (dict<string>, 'env, dict<string>) => 'env = "Object.assign"
let withVars = (env: 'env, vars) => assignedOf(dict{}, env, vars)
