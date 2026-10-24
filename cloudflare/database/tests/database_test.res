/*** The Worker `database` where the samples do not reach, its token, item, size and rewind. */
open Node

let reasonOf = ((status, json)) => (status, json->Served.textOf("reason"))
let messageOf = ((_, json)) => json->Served.textOf("message")
let success = data => JSON.parseOrThrow(`{"status": "success", "data": ${data}}`)

/** The names of what the database holds, as SQLite lists them. */
let names = served =>
  served.Served.sqlite
  ->rows("SELECT name FROM sqlite_master ORDER BY name")
  ->Array.filterMap(row => row->Dict.get("name")->Option.flatMap(JSON.Decode.string))

let count = served => served->Served.execute(["SELECT count(*) AS n FROM t"])

let counted = n =>
  success(
    `{"results": [{"columns": ["n"], "rows": [[{"kind": "integer", "value": ${n}}]],
    "changed": 0}]}`,
  )

test("a call is answered only for the binding's token, or the tokens an apply named", async () => {
  let served = Served.make(~size=1_000_000.)
  let select = authorization => served->Served.call(~authorization, "execute", `{"statements": []}`)
  let other = Uint8Array.fromLength(32)->TypedArray.fillAll(9)
  let theirs = `Bearer 1.${Envelope.Base64url.encode(other)}`
  deepEqual(reasonOf(await select("")), (403, Some("denied")))
  deepEqual(reasonOf(await select(theirs)), (403, Some("denied")))
  deepEqual(await select(`Bearer ${Served.token}`), (200, success(`{"results": []}`)))
  let hash = Envelope.Hex.encode(Keys.Hash.plain(other))
  served.driver->run("UPDATE held SET listed = 1", [])
  served.driver->run("INSERT INTO tokens (hash) VALUES (?)", [JSON.String(hash)])
  deepEqual(reasonOf(await select(`Bearer ${Served.token}`)), (403, Some("denied")))
  deepEqual(await select(theirs), (200, success(`{"results": []}`)))
})

test("a call not at its path, or not as the path names it, is malformed", async () => {
  let served = Served.make(~size=1_000_000.)
  let empty = `{"statements": []}`
  let malformed = (400, Some("malformed"))
  deepEqual(
    reasonOf(await served->Served.call(~path="/object/execute", "execute", empty)),
    malformed,
  )
  deepEqual(
    reasonOf(await served->Served.call(~path="/database/rewind", "execute", empty)),
    malformed,
  )
  deepEqual(reasonOf(await served->Served.call(~method="PUT", "execute", empty)), malformed)
  // A body of neither form is answered in CBOR, which this helper reads as nothing.
  deepEqual(
    (await served->Served.call(~contentType="text/plain", "execute", empty))->Pair.first,
    400,
  )
})

test("with no database item an execute finds no room and a rewind no window", async () => {
  let served = Served.make()
  served->Served.item(~kind="object", 1024.)
  served->Served.item(~id=2., ~state="failed", 1024.)
  deepEqual(reasonOf(await served->Served.execute(["SELECT 1"])), (503, Some("storage_full")))
  deepEqual(
    reasonOf(
      await served->Served.call("rewind", `{"to": ${Float.toString(served.clock.contents)}}`),
    ),
    (400, Some("beyond_window")),
  )
  deepEqual(served.sent, [])
})

test("the first call for another item drops whatever a user made, and D1's own stays", async () => {
  let served = Served.make(~size=1_000_000.)
  let made = [
    "CREATE TABLE parent (id INTEGER PRIMARY KEY)",
    "CREATE TABLE child (id INTEGER, parent INTEGER REFERENCES parent (id))",
    "CREATE INDEX child_parent ON child (parent)",
    "CREATE VIEW parents AS SELECT id FROM parent",
    `CREATE TRIGGER "a ""quoted"" trigger" AFTER INSERT ON parent BEGIN SELECT 1; END`,
    "INSERT INTO parent VALUES (1)",
    "INSERT INTO child VALUES (1, 1)",
  ]
  deepEqual((await served->Served.execute(made))->Pair.first, 200)
  let held = [
    "_cf_KV",
    "a \"quoted\" trigger",
    "child",
    "child_parent",
    "parent",
    "parents",
    "sqlite_autoindex__cf_KV_1",
  ]
  deepEqual(names(served), held)
  // The same item asked again keeps what it made.
  deepEqual((await served->Served.execute(["SELECT 1"]))->Pair.first, 200)
  deepEqual(names(served), held)
  served->Served.forget(1.)
  served->Served.item(~id=2., 1_000_000.)
  deepEqual(
    reasonOf(await served->Served.execute(["SELECT * FROM parent"])),
    (400, Some("invalid")),
  )
  deepEqual(names(served), ["_cf_KV", "sqlite_autoindex__cf_KV_1"])
  deepEqual(
    served.driver->rows("SELECT item, since FROM database_held"),
    [dict{"item": JSON.Number(2.), "since": JSON.Number(served.clock.contents)}],
  )
})

test("an item unasked once made still holds the database, within its grace", async () => {
  let served = Served.make()
  let address = "database.my-subdomain.workers.dev"
  served->Served.item(~state="unasked", ~address, ~since=1., 1_000_000.)
  deepEqual((await served->Served.execute(["CREATE TABLE t (i INTEGER)"]))->Pair.first, 200)
  // A newer item failed by the management holds nothing, so the older one keeps its tables.
  served->Served.item(~id=2., ~state="failed", 1_000_000.)
  deepEqual(await served->count, (200, counted("0")))
})

test(
  "once the database holds its item's size a write is refused, and a read answered",
  async () => {
    let served = Served.make(~size=40_000.)
    deepEqual((await served->Served.execute(["CREATE TABLE t (b BLOB)"]))->Pair.first, 200)
    // A batch below the size is run whole, though it takes the database past it.
    let fill = "INSERT INTO t VALUES (zeroblob(50000))"
    deepEqual((await served->Served.execute([fill]))->Pair.first, 200)
    deepEqual(reasonOf(await served->Served.execute([fill])), (503, Some("storage_full")))
    deepEqual(
      reasonOf(await served->Served.execute(["SELECT 1", "DELETE FROM t"])),
      (503, Some("storage_full")),
    )
    deepEqual(await served->count, (200, counted("1")))
    deepEqual(
      await served->Served.execute(["  -- a comment first\n/* and another */ select 1 AS one"]),
      (
        200,
        success(`{"results": [{"columns": ["one"], "rows": [[{"kind": "integer", "value": 1}]],
      "changed": 0}]}`),
      ),
    )
  },
)

test("a statement past the bound is refused before D1 runs anything of its batch", async () => {
  let served = Served.make(~size=1_000_000.)
  let long = "SELECT 1" ++ String.repeat(" ", Statements.bound - 8)
  deepEqual((await served->Served.execute([long]))->Pair.first, 200)
  let done = served.env.database->batches
  // Past the bound by one byte of UTF-8, though by no character.
  let past = "SELECT 'é'" ++ String.repeat(" ", Statements.bound - 10)
  deepEqual(String.length(past), Statements.bound)
  deepEqual(
    reasonOf(await served->Served.execute(["CREATE TABLE t (i INTEGER)", past])),
    (400, Some("beyond_limit")),
  )
  deepEqual(served.env.database->batches, done)
})

test("a failed batch keeps nothing, its reason read from D1's message", async () => {
  let served = Served.make(~size=1_000_000.)
  deepEqual((await served->Served.execute(["CREATE TABLE t (i INTEGER UNIQUE)"]))->Pair.first, 200)
  let failing = [
    (["INSERT INTO t VALUES (1)", "INSERT INTO t VALUES (1)"], "constraint"),
    (["INSERT INTO t VALUES (1)", "SELECT * FROM nowhere"], "invalid"),
    (["INSERT INTO t VALUES (1)", "SELEKT 1"], "invalid"),
  ]
  for at in 0 to Array.length(failing) - 1 {
    let (sqls, reason) = failing->Array.getUnsafe(at)
    let answer = await served->Served.execute(sqls)
    deepEqual(reasonOf(answer)->Pair.second, Some(reason))
    ok(messageOf(answer)->Option.mapOr(false, m => m->String.startsWith("D1_ERROR")))
  }
  deepEqual(await served->count, (200, counted("0")))
  deepEqual(Failed.reasonOf("D1 DB is overloaded. Requests queued for too long."), "overloaded")
  deepEqual(Failed.reasonOf("D1_ERROR: string or blob too big: SQLITE_TOOBIG"), "beyond_limit")
  deepEqual(Failed.reasonOf("Network connection lost."), "fault")
})

test(
  "an integer past a number is beyond range, and a real and bytes are read as such",
  async () => {
    let served = Served.make(~size=1_000_000.)
    deepEqual(
      reasonOf(await served->Served.execute(["SELECT 1", "SELECT 9223372036854775807 AS big"])),
      (400, Some("beyond_range")),
    )
    deepEqual(
      await served->Served.execute(["SELECT 0.25 AS r, x'00ff' AS b, NULL AS n, 'a' AS s"]),
      (
        200,
        success(`{"results": [{"columns": ["r", "b", "n", "s"], "rows": [[
        {"kind": "real", "value": 0.25}, {"kind": "bytes", "value": "AP8"}, {"kind": "null"},
        {"kind": "text", "value": "a"}]], "changed": 0}]}`),
      ),
    )
  },
)

test(
  "a statement's changes are counted for a write alone, never left from one before",
  async () => {
    let served = Served.make(~size=1_000_000.)
    let changed = answer =>
      answer
      ->Pair.second
      ->Served.member("data")
      ->Option.flatMap(d => d->Served.member("results"))
      ->Option.flatMap(JSON.Decode.array)
      ->Option.getOr([])
      ->Array.map(r => r->Served.member("changed")->Option.flatMap(JSON.Decode.float))
    let answer = await served->Served.execute([
      "CREATE TABLE t (i INTEGER)",
      "INSERT INTO t VALUES (1), (2)",
      "CREATE INDEX t_i ON t (i)",
      "SELECT i FROM t",
      "WITH d AS (SELECT 1) DELETE FROM t WHERE i = 1",
      "WITH d AS (SELECT 1) SELECT * FROM d",
    ])
    deepEqual(changed(answer), [Some(0.), Some(2.), Some(0.), Some(0.), Some(1.), Some(0.)])
  },
)

let rewind = (served, to) => served->Served.call("rewind", `{"to": ${Float.toString(to)}}`)

test(
  "a rewind restores by Time Travel with the Worker's own token, the moment its timestamp",
  async () => {
    let served = Served.make(~size=1_000_000.)
    let start = served.clock.contents
    deepEqual((await served->Served.execute(["CREATE TABLE t (i INTEGER)"]))->Pair.first, 200)
    served.clock := start +. 60_000.
    let before = served.clock.contents
    deepEqual(
      await served->rewind(start +. 30_000.),
      (200, success(`{"before": ${Float.toString(before)}}`)),
    )
    let timestamp = Date.fromTime(start +. 30_000.)->Date.toISOString
    deepEqual(
      served.sent->Array.map(s => (s.init.method, s.url, s.init.headers)),
      [
        (
          "POST",
          `https://api.cloudflare.com/client/v4/accounts/${Served.accountId}/d1/database/` ++
          `${Served.databaseId}/time_travel/restore?timestamp=${Web.encodeURIComponent(timestamp)}`,
          dict{"authorization": `Bearer ${Served.apiToken}`},
        ),
      ],
    )
  },
)

test(
  "a rewind before the item took the database, or past 30 days, is beyond the window",
  async () => {
    let served = Served.make(~size=1_000_000.)
    let start = served.clock.contents
    deepEqual((await served->Served.execute(["SELECT 1"]))->Pair.first, 200)
    served.clock := start +. 31. *. 86_400_000.
    let beyond = (400, Some("beyond_window"))
    deepEqual(reasonOf(await served->rewind(start -. 1.)), beyond)
    deepEqual(reasonOf(await served->rewind(start +. 60_000.)), beyond)
    deepEqual(reasonOf(await served->rewind(served.clock.contents +. 1.)), beyond)
    deepEqual(served.sent, [])
    deepEqual((await served->rewind(start +. 2. *. 86_400_000.))->Pair.first, 200)
  },
)

test("a restore Cloudflare's API refuses is a fault naming what it answered", async () => {
  let served = Served.make(~size=1_000_000.)
  deepEqual((await served->Served.execute(["SELECT 1"]))->Pair.first, 200)
  served.clock := served.clock.contents +. 60_000.
  served.refusing := Some((400, Documented.refused))
  let answer = await served->rewind(served.clock.contents -. 30_000.)
  deepEqual(reasonOf(answer), (500, Some("fault")))
  deepEqual(messageOf(answer), Some("Time Travel's restore answered 400, 1000 message"))
})

test("a statement's first keyword is read past space and comments", async () => {
  deepEqual(Statements.keyword("  \n-- one\n/* two */\tselect 1"), "SELECT")
  deepEqual(Statements.keyword("/* never closed"), "")
  deepEqual(Statements.keyword("(SELECT 1)"), "")
  deepEqual(
    [
      "SELECT 1",
      "explain select 1",
      "VALUES (1)",
      "WITH a AS (SELECT 1) SELECT 1",
      "PRAGMA x",
    ]->Array.map(Statements.reads),
    [true, true, true, false, false],
  )
})
