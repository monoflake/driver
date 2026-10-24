/*** The Worker `object` on node's SQLite and a bucket in memory, its one item put as asked. */
open Node

let secret = Uint8Array.fromLength(32)->TypedArray.fillAll(5)
let token = `1.${Envelope.Base64url.encode(secret)}`
let binding = Envelope.Hex.encode(Keys.Hash.plain(secret))

/** A made-up install id, as install draws one. */
let installId = "0a1b2c3d"

/** What a test reaches, the Worker's env, its SQLite and the bucket's clock in milliseconds. */
type served = {env: Object.env, sqlite: sqlite, clock: ref<float>}

let items =
  [
    "INSERT INTO items (id, kind, bytes, credentials, state, address, since)",
    "VALUES (?, ?, ?, ?, ?, ?, ?)",
  ]->Array.join(" ")

/** An item kept in D1 as the management writes it, an `object` made at an address by default. */
let item = (served, ~id=1., ~kind="object", ~state="made", ~address=?, ~since=?, size) =>
  served.sqlite->run(
    items,
    [
      JSON.Number(id),
      JSON.String(kind),
      JSON.Number(size),
      JSON.String(binding),
      JSON.String(state),
      switch (state, address) {
      | (_, Some(address)) => JSON.String(address)
      | ("made", None) => JSON.String("object.my-subdomain.workers.dev")
      | (_, None) => JSON.Null
      },
      since->Option.mapOr(JSON.Null, s => JSON.Number(s)),
    ],
  )

/** A binding new, holding no item unless `size` names one. */
let make = (~size=?) => {
  let sqlite = migrated()
  let clock = ref(0.)
  let env: Object.env = {db: asDatabase(sqlite), objects: bucket(clock), binding}
  let served = {env: withVars(env, dict{"INSTALL_ID": installId}), sqlite, clock}
  size->Option.forEach(size => served->item(size))
  served
}

/** A call's answer, its status, its content type and its body's JSON. */
let call = async (
  served,
  ~path=?,
  ~method="POST",
  ~authorization=`Bearer ${token}`,
  ~contentType="application/json",
  operation,
  input,
) => {
  let body = `{"interface": "object", "operation": "${operation}", "input": ${input}}`
  let headers = dict{"authorization": authorization, "content-type": contentType}
  let path = path->Option.getOr(`/object/${operation}`)
  let response = await Object.fetch(
    request(`https://object.example.workers.dev${path}`, {method, headers, body: Web.utf8(body)}),
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

let member = (json, key) => json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key))
let textOf = (json, key) => json->member(key)->Option.flatMap(JSON.Decode.string)
