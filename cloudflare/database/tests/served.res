/***
 * The Worker `database` on node's SQLite, its one item put as asked, a clock a test moves, and
 * Time Travel's restore answered by its documented example on the fake database.
 */
open Node

let secret = Uint8Array.fromLength(32)->TypedArray.fillAll(5)
let token = `1.${Envelope.Base64url.encode(secret)}`
let binding = Envelope.Hex.encode(Keys.Hash.plain(secret))

/** A made-up install id, as install draws one. */
let installId = "0a1b2c3d"

let accountId = "023e105f4ecef8ad9ca31a8372d0c353"
let databaseId = "1fc0aa2e-b5a1-4b8e-8f0e-3c6f2c1d9a7b"
let apiToken = "d1-t0ken"

/**
 * What a test reaches, the Worker's env, the driver's SQLite and the database's, the clock, the
 * requests sent out, and the answer the next restore is given where it is not the documented one.
 */
type served = {
  env: Database.env,
  driver: sqlite,
  sqlite: sqlite,
  clock: ref<float>,
  sent: array<sent>,
  refusing: ref<option<(int, string)>>,
}

let items =
  [
    "INSERT INTO items (id, kind, bytes, credentials, state, address, since)",
    "VALUES (?, ?, ?, ?, ?, ?, ?)",
  ]->Array.join(" ")

/** An item kept in D1 as the management writes it, a `database` made at an address by default. */
let item = (served, ~id=1., ~kind="database", ~state="made", ~address=?, ~since=?, size) =>
  served.driver->run(
    items,
    [
      JSON.Number(id),
      JSON.String(kind),
      JSON.Number(size),
      JSON.String(binding),
      JSON.String(state),
      switch (state, address) {
      | (_, Some(address)) => JSON.String(address)
      | ("made", None) => JSON.String("database.my-subdomain.workers.dev")
      | (_, None) => JSON.Null
      },
      since->Option.mapOr(JSON.Null, s => JSON.Number(s)),
    ],
  )

/** An item no longer listed, as the management forgets one ended or swept. */
let forget = (served, id) => served.driver->run("DELETE FROM items WHERE id = ?", [JSON.Number(id)])

/** The restore's path on the account, its timestamp read from the address. */
let restorePath = `/client/v4/accounts/${accountId}/d1/database/${databaseId}/time_travel/restore`

/** A binding new at a moment, holding no item unless `size` names one. */
let make = (~size=?, ~at=1_790_000_000_000.) => {
  let clock = ref(at)
  clockedBy(clock)
  let driver = migrated()
  let sqlite = openSqlite(":memory:")
  // D1 keeps a table of its own in every database, which no user's call reaches.
  sqlite->exec("CREATE TABLE _cf_KV (key TEXT PRIMARY KEY, value BLOB)")
  let database = asDatabase(sqlite, clock)
  let env = withVars(
    (
      {
        db: asDatabase(driver, clock),
        database,
        binding,
        apiToken,
        accountId,
        databaseId,
      }: Database.env
    ),
    dict{"INSTALL_ID": installId},
  )
  let served = {env, driver, sqlite, clock, sent: [], refusing: ref(None)}
  answering(served.sent, async (url, init) => {
    let parts = Web.parts(url)
    switch (init.method, parts->Web.pathname, served.refusing.contents) {
    | ("POST", path, None) if path == restorePath =>
      let timestamp = searchParams(parts)->searchGet("timestamp")->Nullable.toOption
      switch timestamp->Option.map(t => Date.fromString(t)->Date.getTime) {
      | Some(time) if !Float.isNaN(time) =>
        database->restoreTo(time)
        response(Documented.restored, {status: 200})
      | Some(_) | None => response(Documented.refused, {status: 400})
      }
    | ("POST", path, Some((status, body))) if path == restorePath =>
      served.refusing := None
      response(body, {status: status})
    | _ => response(Documented.refused, {status: 404})
    }
  })
  size->Option.forEach(size => served->item(size))
  served
}

/** A call's answer, its status and its body's JSON. */
let call = async (
  served,
  ~path=?,
  ~method="POST",
  ~authorization=`Bearer ${token}`,
  ~contentType="application/json",
  operation,
  input,
) => {
  let body = `{"interface": "database", "operation": "${operation}", "input": ${input}}`
  let headers = dict{"authorization": authorization, "content-type": contentType}
  let path = path->Option.getOr(`/database/${operation}`)
  let response = await Database.fetch(
    request(`https://database.example.workers.dev${path}`, {method, headers, body: Web.utf8(body)}),
    served.env,
  )
  let media = response->Web.responseHeaders->Web.header("content-type")->Nullable.toOption
  let bytes = await response->Web.responseBytes
  let json = switch media {
  | Some("application/json") => JSON.parseOrThrow(Web.fromUtf8(bytes)->Option.getOr(""))
  | Some(_) | None => JSON.Null
  }
  (response->Web.status, json)
}

/** Statements executed, each its SQL alone. */
let execute = (served, sqls: array<string>) =>
  served->call(
    "execute",
    JSON.stringify(
      JSON.Object(
        dict{
          "statements": JSON.Array(
            sqls->Array.map(sql => JSON.Object(dict{"sql": JSON.String(sql)})),
          ),
        },
      ),
    ),
  )

let member = (json, key) => json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key))
let textOf = (json, key) => json->member(key)->Option.flatMap(JSON.Decode.string)
