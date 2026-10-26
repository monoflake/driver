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

test("an unset or empty BINDING holds no token, so every caller is denied", async () => {
  let served = Served.make(~size=1_000_000.)
  let bindings = [unset, "", "  "]
  for at in 0 to Array.length(bindings) - 1 {
    let unbound = {...served, env: {...served.env, binding: bindings->Array.getUnsafe(at)}}
    let select = authorization =>
      unbound->Served.call(~authorization, "execute", `{"statements": []}`)
    deepEqual(reasonOf(await select("")), (403, Some("denied")))
    deepEqual(reasonOf(await select(`Bearer ${Served.token}`)), (403, Some("denied")))
  }
})

test("a Worker whose INSTALL_ID is unset or not 8 lowercase hex answers fault", async () => {
  let served = Served.make(~size=1024.)
  let ids = [unset, "", "0A1B2C3D", "0a1b2c3", "0a1b2c3d0"]
  for at in 0 to Array.length(ids) - 1 {
    let env = withVars(served.env, dict{"INSTALL_ID": ids->Array.getUnsafe(at)})
    let answered = await {...served, env}->Served.call("execute", `{"statements": []}`)
    deepEqual(
      (reasonOf(answered), messageOf(answered)),
      (
        (500, Some("fault")),
        Some("INSTALL_ID is unset or not 8 lowercase hex digits, so install broke"),
      ),
    )
  }
  let (status, _) = await served->Served.call("execute", `{"statements": []}`)
  deepEqual(status, 200)
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

test(
  "a table named before one whose rows name it is dropped with it for another item",
  async () => {
    let served = Served.make(~size=1_000_000.)
    let made = [
      "CREATE TABLE a_parent (id INTEGER PRIMARY KEY)",
      "CREATE TABLE b_child (parent INTEGER REFERENCES a_parent (id))",
      "INSERT INTO a_parent VALUES (1)",
      "INSERT INTO b_child VALUES (1)",
    ]
    deepEqual((await served->Served.execute(made))->Pair.first, 200)
    served->Served.forget(1.)
    served->Served.item(~id=2., 1_000_000.)
    deepEqual((await served->Served.execute(["SELECT 1"]))->Pair.first, 200)
    deepEqual(names(served), ["_cf_KV", "sqlite_autoindex__cf_KV_1"])
  },
)

test("two first calls for a new item clear the database once, and keep what it made", async () => {
  let served = Served.make(~size=1_000_000.)
  deepEqual((await served->Served.execute(["CREATE TABLE old (i INTEGER)"]))->Pair.first, 200)
  served->Served.forget(1.)
  served->Served.item(~id=2., 1_000_000.)
  let done = served.env.database->batches
  // The late call reads the old item, and is answered that read once the early call is done.
  let gate = served.env.db->holdBack("FROM database_held")
  let late = served->Served.execute(["CREATE TABLE late (i INTEGER)"])
  await gate.reached
  deepEqual((await served->Served.execute(["CREATE TABLE early (i INTEGER)"]))->Pair.first, 200)
  gate.release()
  deepEqual((await late)->Pair.first, 200)
  deepEqual(names(served), ["_cf_KV", "early", "late", "sqlite_autoindex__cf_KV_1"])
  deepEqual(served.env.database->batches, done + 3)
})

/** A binding whose database held item 1's table, now listed for item 2 alone. */
let handing = async () => {
  let served = Served.make(~size=1_000_000.)
  deepEqual((await served->Served.execute(["CREATE TABLE old (i INTEGER)"]))->Pair.first, 200)
  served->Served.forget(1.)
  served->Served.item(~id=2., 1_000_000.)
  served
}

/** What `database_held` records, its item, whether it was emptied, and since when. */
let heldRow = served => served.Served.driver->rows("SELECT item, cleared, since FROM database_held")

/** A handover whose drops were done and whose record failed, its lease left at the clock. */
let unrecorded = async () => {
  let served = await handing()
  served.env.db->failOnce("SET cleared = 1")
  deepEqual(reasonOf(await served->Served.execute(["SELECT 1"])), (500, Some("fault")))
  served
}

test("a clear that failed midway is taken over once its lease passed, ending cleared", async () => {
  let served = await unrecorded()
  deepEqual(names(served), ["_cf_KV", "sqlite_autoindex__cf_KV_1"])
  deepEqual(heldRow(served)->Array.map(row => row->Dict.get("cleared")), [Some(JSON.Number(0.))])
  served.clock := served.clock.contents +. Held.lease +. 1.
  deepEqual((await served->Served.execute(["CREATE TABLE new (i INTEGER)"]))->Pair.first, 200)
  deepEqual(names(served), ["_cf_KV", "new", "sqlite_autoindex__cf_KV_1"])
  deepEqual(
    heldRow(served),
    [
      dict{
        "item": JSON.Number(2.),
        "cleared": JSON.Number(1.),
        "since": JSON.Number(served.clock.contents),
      },
    ],
  )
})

test("a call while another holds a fresh lease is overloaded, and runs nothing", async () => {
  let served = await unrecorded()
  let done = served.env.database->batches
  served.clock := served.clock.contents +. Held.lease
  let overloaded = (503, Some("overloaded"))
  deepEqual(reasonOf(await served->Served.execute(["CREATE TABLE t (i INTEGER)"])), overloaded)
  deepEqual(
    reasonOf(
      await served->Served.call("rewind", `{"to": ${Float.toString(served.clock.contents)}}`),
    ),
    overloaded,
  )
  deepEqual(served.env.database->batches, done)
  deepEqual(names(served), ["_cf_KV", "sqlite_autoindex__cf_KV_1"])
  deepEqual(served.sent, [])
})

test("of two calls racing for a lease that passed one clears, the other overloaded", async () => {
  let served = await unrecorded()
  served.clock := served.clock.contents +. Held.lease +. 1.
  let done = served.env.database->batches
  // The late call reads the lease that passed, and tries to take it while the early one clears.
  let read = served.env.db->holdBack("FROM database_held")
  let late = served->Served.execute(["CREATE TABLE late (i INTEGER)"])
  await read.reached
  let clearing = served.env.database->holdBack("sqlite_master")
  let early = served->Served.execute(["CREATE TABLE early (i INTEGER)"])
  // Raced with the early call's answer, so a call that never clears fails rather than waits.
  await Promise.race([clearing.reached, early->Promise.thenResolve(_ => ())])
  read.release()
  deepEqual(reasonOf(await late), (503, Some("overloaded")))
  clearing.release()
  deepEqual((await early)->Pair.first, 200)
  deepEqual(names(served), ["_cf_KV", "early", "sqlite_autoindex__cf_KV_1"])
  deepEqual(served.env.database->batches, done + 2)
})

test("the moment the database was emptied is taken once the clear is done", async () => {
  let served = await handing()
  let gate = served.env.database->holdBack("sqlite_master")
  let call = served->Served.execute(["SELECT 1"])
  await gate.reached
  served.clock := served.clock.contents +. 5000.
  gate.release()
  deepEqual((await call)->Pair.first, 200)
  deepEqual(
    heldRow(served)->Array.map(row => row->Dict.get("since")),
    [Some(JSON.Number(served.clock.contents))],
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

test(
  "a batch that committed is answered, its size recorded by a later batch where not",
  async () => {
    let served = Served.make(~size=1_000_000.)
    deepEqual((await served->Served.execute(["CREATE TABLE t (b BLOB)"]))->Pair.first, 200)
    let held = () =>
      served.driver
      ->rows("SELECT size FROM database_held")
      ->Array.filterMap(row => row->Dict.get("size")->Option.flatMap(JSON.Decode.float))
    let before = held()
    served.env.db->failOnce("UPDATE database_held SET size")
    let fill = "INSERT INTO t VALUES (zeroblob(50000))"
    deepEqual((await served->Served.execute([fill]))->Pair.first, 200)
    deepEqual(held(), before)
    deepEqual((await served->Served.execute(["INSERT INTO t VALUES (NULL)"]))->Pair.first, 200)
    ok(held()->Array.every(size => before->Array.every(was => size > was +. 40_000.)))
    deepEqual(await served->count, (200, counted("2")))
  },
)

test(
  "a statement D1 will not run is invalid, a tail, a binding past its count or an attach",
  async () => {
    let served = Served.make(~size=1_000_000.)
    let one = `{"kind": "integer", "value": 1}`
    let refused = [
      (`{"sql": "SELECT 1; SELECT 2"}`, "only one statement"),
      (`{"sql": "SELECT ?", "parameters": [${one}, ${one}]}`, "parameter bindings"),
      (`{"sql": "ATTACH ':memory:' AS other"}`, "SQLITE_AUTH"),
    ]
    for at in 0 to Array.length(refused) - 1 {
      let (statement, said) = refused->Array.getUnsafe(at)
      let answer = await served->Served.call("execute", `{"statements": [${statement}]}`)
      deepEqual(reasonOf(answer), (400, Some("invalid")))
      ok(messageOf(answer)->Option.mapOr(false, m => m->String.includes(said)))
    }
  },
)

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
          "GET",
          `https://api.cloudflare.com/client/v4/accounts/${Served.accountId}/d1/database/` ++
          Served.databaseId,
          dict{"authorization": `Bearer ${Served.apiToken}`},
        ),
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

test(
  "a rewind within 30 days but before the database was emptied is beyond the window",
  async () => {
    let served = Served.make(~size=1_000_000.)
    let start = served.clock.contents
    deepEqual((await served->Served.execute(["SELECT 1"]))->Pair.first, 200)
    served.clock := start +. 86_400_000.
    deepEqual(reasonOf(await served->rewind(start -. 60_000.)), (400, Some("beyond_window")))
    deepEqual(served.sent, [])
  },
)

test("a rewind reaches a second past when the database was emptied, never sooner", async () => {
  let served = Served.make(~size=1_000_000.)
  let start = served.clock.contents
  deepEqual((await served->Served.execute(["SELECT 1"]))->Pair.first, 200)
  served.clock := start +. 60_000.
  deepEqual(reasonOf(await served->rewind(start)), (400, Some("beyond_window")))
  deepEqual(reasonOf(await served->rewind(start +. 999.)), (400, Some("beyond_window")))
  deepEqual(served.sent, [])
  deepEqual((await served->rewind(start +. 1000.))->Pair.first, 200)
})

test(
  "a rewind that brings rows back holds the size it left, so a write finds no room",
  async () => {
    let served = Served.make(~size=100_000.)
    let start = served.clock.contents
    deepEqual((await served->Served.execute(["CREATE TABLE t (b BLOB)"]))->Pair.first, 200)
    served.clock := start +. 60_000.
    let fill = "INSERT INTO t VALUES (zeroblob(50000))"
    deepEqual((await served->Served.execute([fill]))->Pair.first, 200)
    served.clock := start +. 120_000.
    deepEqual((await served->rewind(start +. 1000.))->Pair.first, 200)
    // A batch after the first rewind records the size small, whatever that rewind kept.
    deepEqual((await served->Served.execute(["CREATE TABLE u (i INTEGER)"]))->Pair.first, 200)
    served.clock := start +. 180_000.
    deepEqual((await served->rewind(start +. 90_000.))->Pair.first, 200)
    let text = String.repeat("a", 40_000)
    let parameter = `{"kind": "text", "value": "${text}"}`
    let write = `{"sql": "INSERT INTO t VALUES (?)", "parameters": [${parameter}]}`
    deepEqual(
      reasonOf(await served->Served.call("execute", `{"statements": [${write}]}`)),
      (503, Some("storage_full")),
    )
    // Read last, as a read batch records the size too.
    deepEqual(await served->count, (200, counted("1")))
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

test(
  "a rewind of a database the driver's records do not name is a fault, nothing restored",
  async () => {
    let served = Served.make(~size=1_000_000.)
    let start = served.clock.contents
    deepEqual((await served->Served.execute(["CREATE TABLE t (i INTEGER)"]))->Pair.first, 200)
    served.clock := start +. 60_000.
    let names = ["my-database", "database-5f6a7b8c", "0a1b2c3d"]
    let answers = []
    for at in 0 to Array.length(names) - 1 {
      served.named := names->Array.getUnsafe(at)
      answers->Array.push(await served->rewind(start +. 30_000.))
    }
    let never = name => {
      let not = `not the one the driver's records hold, ${Served.recordedName}`
      `the database ${Served.databaseId} is ${name}, ${not}, so it is never restored`
    }
    deepEqual(
      answers->Array.map(answer => (reasonOf(answer), messageOf(answer))),
      names->Array.map(name => ((500, Some("fault")), Some(never(name)))),
    )
    deepEqual(served.sent->Array.map(s => s.init.method), ["GET", "GET", "GET"])
  },
)

test(
  "a rewind whose lookup of the database's name fails is a fault, nothing restored",
  async () => {
    let served = Served.make(~size=1_000_000.)
    let start = served.clock.contents
    deepEqual((await served->Served.execute(["CREATE TABLE t (i INTEGER)"]))->Pair.first, 200)
    served.clock := start +. 60_000.
    deepEqual((await served->Served.execute(["INSERT INTO t VALUES (1)"]))->Pair.first, 200)
    served.clock := start +. 120_000.
    served.getting := Some((403, Documented.refused))
    let answer = await served->rewind(start +. 30_000.)
    deepEqual(reasonOf(answer), (500, Some("fault")))
    deepEqual(messageOf(answer), Some("D1's get answered 403, 1000 message"))
    deepEqual(served.sent->Array.map(s => s.init.method), ["GET"])
    // The row written after the moment asked for is still there, so nothing was restored.
    served.getting := None
    deepEqual(await served->count, (200, counted("1")))
  },
)

test("a restore done is answered though its size was not read or recorded", async () => {
  let served = Served.make(~size=1_000_000.)
  let start = served.clock.contents
  deepEqual((await served->Served.execute(["CREATE TABLE t (i INTEGER)"]))->Pair.first, 200)
  let sizes = () => served.driver->rows("SELECT size FROM database_held")
  let was = sizes()
  served.clock := start +. 60_000.
  served.env.db->failOnce("UPDATE database_held SET size")
  let before = served.clock.contents
  deepEqual(
    await served->rewind(start +. 30_000.),
    (200, success(`{"before": ${Float.toString(before)}}`)),
  )
  deepEqual(sizes(), was)
  served.clock := start +. 120_000.
  served.env.database->failOnce("SELECT 1")
  let before = served.clock.contents
  deepEqual(
    await served->rewind(start +. 30_000.),
    (200, success(`{"before": ${Float.toString(before)}}`)),
  )
  deepEqual(sizes(), was)
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

/** Every request the Worker sends out throwing `thrown`, as a fetch that reached nothing. */
let throwing = thrown => answering([], async (_, _) => JsExn.throw(thrown))

test("a get or a restore never answered names the throw, its secrets replaced", async () => {
  let (accountId, databaseId, token) = (Served.accountId, Served.databaseId, Served.apiToken)
  let said = `Illegal invocation at https://api.cloudflare.com for ${accountId}, Bearer ${token}`
  throwing(JsError.TypeError.make(said))
  let detail = "TypeError: Illegal invocation at <address> for <account>, Bearer <token>"
  let unreached = Error(`Cloudflare's API was not reached, ${detail}`)
  deepEqual(await Restored.nameOf(~accountId, ~databaseId, ~token), unreached)
  deepEqual(await Restored.restore(~accountId, ~databaseId, ~token, ~to=0.), unreached)
})

test("a throw never answered is cut to 200, and one that is no Error is not told", async () => {
  let (accountId, databaseId, token) = (Served.accountId, Served.databaseId, Served.apiToken)
  throwing(JsError.TypeError.make(String.repeat("a", 300)))
  deepEqual(
    await Restored.nameOf(~accountId, ~databaseId, ~token),
    Error(`Cloudflare's API was not reached, TypeError: ${String.repeat("a", 189)}`),
  )
  throwing({"name": "TypeError", "message": "Illegal invocation"})
  deepEqual(
    await Restored.restore(~accountId, ~databaseId, ~token, ~to=0.),
    Error("Cloudflare's API was not reached"),
  )
})

test("a token echoed trimmed is replaced, and an address of any case or no slashes", async () => {
  let (accountId, databaseId) = (Served.accountId, Served.databaseId)
  let token = `${Served.apiToken}\n`
  let said = `Bearer ${Served.apiToken} is invalid at HTTPS://API.CLOUDFLARE.COM and https:x`
  throwing(JsError.TypeError.make(said))
  let detail = "TypeError: Bearer <token> is invalid at <address> and <address>"
  deepEqual(
    await Restored.nameOf(~accountId, ~databaseId, ~token),
    Error(`Cloudflare's API was not reached, ${detail}`),
  )
})
