/***
 * What the tests of the Worker `driver` share, its env over node's SQLite, the calls made to it,
 * the artifact deployed and the fake account holding the organization's own Workers.
 */
open Node

let secret = Uint8Array.fromLength(32)->TypedArray.fillAll(7)
let token = `1.${Envelope.Base64url.encode(secret)}`
let binding = Envelope.Hex.encode(Keys.Hash.plain(secret))
let other = Uint8Array.fromLength(32)->TypedArray.fillAll(9)

/** A made-up install id, as install draws one. */
let installId = "0a1b2c3d"

let envOf = (
  ~revision=?,
  ~db=database(),
  ~vars=dict{"INSTALL_ID": installId, "KINDS": "function,object,database"},
  (),
): Driver.env =>
  withVars(
    (
      {
        db,
        apiToken: "t0ken",
        accountId: "023e105f4ecef8ad9ca31a8372d0c353",
        binding,
        ?revision,
      }: Driver.env
    ),
    vars,
  )

/** A call's answer, its status, its content type and its body's JSON. */
let call = async (
  env,
  ~path,
  ~body,
  ~method="POST",
  ~authorization=`Bearer ${token}`,
  ~contentType="application/json",
) => {
  let headers = dict{"authorization": authorization, "content-type": contentType}
  let response = await Driver.fetch(
    request(`https://driver.example.workers.dev${path}`, {method, headers, body: Web.utf8(body)}),
    env,
  )
  let media = response->responseHeaders->Web.header("content-type")->Nullable.toOption
  let bytes = await response->Web.responseBytes
  // An answer in CBOR is read in its own test, so here it is told by its type alone.
  let json = switch media {
  | Some("application/json") => JSON.parseOrThrow(Web.fromUtf8(bytes)->Option.getOr(""))
  | Some(_) | None => JSON.Null
  }
  (response->Web.status, media, json)
}

let management = (operation, input) =>
  `{"interface": "management", "operation": "${operation}", "input": ${input}}`

let manage = (env, operation, input) =>
  call(env, ~path=`/management/${operation}`, ~body=management(operation, input))

let success = data => JSON.parseOrThrow(`{"status": "success", "data": ${data}}`)

let reasonOf = ((status, _, json)) => (
  status,
  json->JSON.Decode.object->Option.flatMap(o => o->Dict.get("reason")),
)

let item = `{"id": 1, "capacity": {"name": "object", "size": 1048576},
  "credentials": ["af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"]}`

/** An artifact's bytes, a bundle of one module answering hello. */
let artifact = Tar.archive([
  Tar.file("metadata.json", `{"main_module": "main.js", "compatibility_date": "2026-10-21"}`),
  Tar.file("main.js", `export default { fetch: () => new Response("hello") }`),
])

let messageOf = ((_, _, json)) =>
  json->JSON.Decode.object->Option.flatMap(o => o->Dict.get("message"))

/** A deployments call's body, its operation and its input. */
let deploymentsCall = (operation, input) =>
  `{"interface": "deployments", "operation": "${operation}", "input": ${input}}`

let deploying = (env, operation, input) =>
  call(env, ~path=`/deployments/${operation}`, ~body=deploymentsCall(operation, input))

/** A deploy of `artifact` for what `runs` names. */
let deployInput = async runs => {
  let hash = Envelope.Hex.encode(await sha256(artifact))
  `{"runs": ${runs}, "version": "${hash}", "form": "modules",
    "isolation": ["isolate"], "artifact": {"address": "https://artifacts.example/hello",
    "hash": "${hash}"}, "footing": "https://footing.invalid", "secrets": {},
    "network": ["http", "tcp"]}`
}

let app = id => `{"name": "app", "id": ${Int.toString(id)}}`
let component = id => `{"name": "component", "component": "pages", "id": ${id}}`

/** The fake account with the organization's own Workers made on it, each call it is asked kept. */
let accountHolding = async (~asked=[], names) => {
  let account = Account.make(~artifacts=dict{"https://artifacts.example/hello": artifact})
  for at in 0 to Array.length(names) - 1 {
    let name = names->Array.getUnsafe(at)
    ignore(await account(`${Account.api}/workers/scripts/${name}`, {method: "PUT"}))
  }
  replaced(async (url, init) => {
    asked->Array.push(`${init.method} ${url->String.replace(Account.api, "")}`)
    await account(url, init)
  })
}

/** Whether the records hold a name, read from the rows. */
let claims = (sqlite, name) =>
  rows(sqlite)->String.includes(`{"name":"${name}","role":"deployment"}`)
