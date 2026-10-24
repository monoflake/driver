/***
 * The Worker `driver` answering requests over node's SQLite standing in for its D1, its migrations
 * applied, and Cloudflare's API answered by its documented examples, `documented.res`.
 */
open Node
module Contracts = Envelope.Contracts

let secret = Uint8Array.fromLength(32)->TypedArray.fillAll(7)
let token = `1.${Envelope.Base64url.encode(secret)}`
let binding = Envelope.Hex.encode(Keys.Hash.plain(secret))
let other = Uint8Array.fromLength(32)->TypedArray.fillAll(9)

let envOf = (~revision=?, ~db=database(), ()): Driver.env => {
  db,
  apiToken: "t0ken",
  accountId: "023e105f4ecef8ad9ca31a8372d0c353",
  binding,
  ?revision,
}

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

test("a call is answered only for the binding's token", async () => {
  let env = envOf()
  let denied = (403, Some(JSON.String("denied")))
  let describe = management("describe", "{}")
  deepEqual(
    reasonOf(await call(env, ~path="/management/describe", ~body=describe, ~authorization="")),
    denied,
  )
  let wrong = `Bearer 1.${Envelope.Base64url.encode(other)}`
  deepEqual(
    reasonOf(await call(env, ~path="/management/describe", ~body=describe, ~authorization=wrong)),
    denied,
  )
  let bare = `Bearer ${Envelope.Base64url.encode(secret)}`
  deepEqual(
    reasonOf(await call(env, ~path="/management/describe", ~body=describe, ~authorization=bare)),
    denied,
  )
  let (status, media, _) = await call(env, ~path="/management/describe", ~body=describe)
  deepEqual((status, media), (200, Some("application/json")))
})

test("a binding new holds nothing, its grace a week, and names the revision given", async () => {
  let env = envOf(~revision="4b825dc", ())
  deepEqual(
    await manage(env, "describe", "{}"),
    (
      200,
      Some("application/json"),
      success(`{"generation": 0, "policy": 0, "grace": 604800, "items": [],
        "revision": "4b825dc"}`),
    ),
  )
})

test(
  "a list is kept in D1, its object held failed, unasked, then swept past its grace",
  async () => {
    let env = envOf()
    let (_, _, applied) = await manage(env, "apply", `{"generation": 1, "items": [${item}]}`)
    deepEqual(applied, success(`{"generation": 1}`))
    let (_, _, described) = await manage(env, "describe", "{}")
    deepEqual(
      described,
      success(`{"generation": 1, "policy": 0, "grace": 604800, "items": [{"id": 1,
      "capacity": {"name": "object", "size": 1048576}, "state": {"name": "failed",
      "reason": "beyond_host", "message": "it waits on RFC nrs5v's next slice"}}]}`),
    )
    deepEqual(
      reasonOf(await manage(env, "end", `{"id": 1}`)),
      (400, Some(JSON.String("still_asked"))),
    )
    ignore(await manage(env, "apply", `{"generation": 2, "items": []}`))
    let (_, _, unasked) = await manage(env, "describe", "{}")
    let state =
      unasked
      ->JSON.Decode.object
      ->Option.flatMap(o => o->Dict.get("data"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(o => o->Dict.get("items"))
      ->Option.flatMap(JSON.Decode.array)
      ->Option.flatMap(items => items->Array.get(0))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(o => o->Dict.get("state"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(o => o->Dict.get("name"))
    deepEqual(state, Some(JSON.String("unasked")))
    ignore(await manage(env, "set_policy", `{"generation": 1, "grace": 0}`))
    deepEqual(
      await manage(env, "describe", "{}"),
      (
        200,
        Some("application/json"),
        success(`{"generation": 2, "policy": 1, "grace": 0, "items": []}`),
      ),
    )
  },
)

// The token's id is not checked, this driver holding one binding and never told its id.
test(
  "a token's id is passed over, its secret's hash held to the tokens an apply names",
  async () => {
    let env = envOf()
    let held = Envelope.Hex.encode(Keys.Hash.plain(other))
    ignore(await manage(env, "apply", `{"generation": 1, "items": [], "tokens": ["${held}"]}`))
    deepEqual(reasonOf(await manage(env, "describe", "{}")), (403, Some(JSON.String("denied"))))
    let theirs = `Bearer 7.${Envelope.Base64url.encode(other)}`
    let (status, _, _) = await call(
      env,
      ~path="/management/describe",
      ~body=management("describe", "{}"),
      ~authorization=theirs,
    )
    deepEqual(status, 200)
  },
)

test("a call in CBOR is answered in CBOR", async () => {
  let env = envOf()
  let envelope: Contracts.Interface.Management.envelope = {call: Describe({}), capabilities: []}
  let body = Contracts.Interface.Management.toCbor(envelope)->Codec.Cbor.encode->Result.getOrThrow
  let response = await Driver.fetch(
    request(
      "https://driver.example.workers.dev/management/describe",
      {
        method: "POST",
        headers: dict{"authorization": `Bearer ${token}`, "content-type": "application/cbor"},
        body,
      },
    ),
    env,
  )
  let answer =
    (await response->Web.responseBytes)
    ->Codec.Cbor.decode
    ->Result.getOrThrow
    ->Contracts.Answer.fromCbor(Contracts.ManagementDescribed.fromCbor)
  deepEqual(
    answer->Result.map(a => Contracts.Answer.toJson(a, Contracts.ManagementDescribed.toJson)),
    Ok(success(`{"generation": 0, "policy": 0, "grace": 604800, "items": []}`)),
  )
  deepEqual(
    response->responseHeaders->Web.header("content-type")->Nullable.toOption,
    Some("application/cbor"),
  )
})

test("a call not as its interface writes it is malformed", async () => {
  let env = envOf()
  let malformed = (400, Some(JSON.String("malformed")))
  let describe = management("describe", "{}")
  deepEqual(
    reasonOf(await call(env, ~path="/management/describe", ~body=describe, ~method="PUT")),
    malformed,
  )
  deepEqual(reasonOf(await call(env, ~path="/management", ~body=describe)), malformed)
  deepEqual(reasonOf(await call(env, ~path="/objects/read", ~body=describe)), malformed)
  deepEqual(reasonOf(await call(env, ~path="/management/apply", ~body=describe)), malformed)
  deepEqual(reasonOf(await call(env, ~path="/management/describe", ~body="{")), malformed)
  let (status, media, _) = await call(
    env,
    ~path="/management/describe",
    ~body=describe,
    ~contentType="text/plain",
  )
  deepEqual((status, media), (400, Some("application/cbor")))
  deepEqual(
    reasonOf(await manage(env, "apply", `{"generation": 1, "items": [${item}, ${item}]}`)),
    (400, Some(JSON.String("invalid"))),
  )
})

/** An artifact's bytes, a bundle of one module answering hello. */
let artifact = Tar.archive([
  Tar.file("metadata.json", `{"main_module": "main.js", "compatibility_date": "2026-10-21"}`),
  Tar.file("main.js", `export default { fetch: () => new Response("hello") }`),
])

test("a deployment is made a Worker of the account, kept in D1, and described", async () => {
  let env = envOf()
  let asked = []
  let restore = replaced(async (url, init) => {
    asked->Array.push(`${init.method} ${url}`)
    let api = "https://api.cloudflare.com/client/v4/accounts/023e105f4ecef8ad9ca31a8372d0c353"
    switch (init.method, url->String.replace(api, "")) {
    | ("GET", "https://artifacts.example/hello") => answerBytes(artifact, {status: 200})
    | ("GET", "/workers/scripts/app-1/deployments") =>
      answerText(Documented.notFound, {status: 404})
    | ("POST", "/workers/scripts/app-1/versions") =>
      answerText(Documented.versionUploaded, {status: 200})
    | ("POST", "/workers/scripts/app-1/deployments") =>
      answerText(Documented.deploymentCreated, {status: 200})
    | ("GET", "/workers/subdomain") => answerText(Documented.subdomainGot, {status: 200})
    | _ => answerText("{}", {status: 500})
    }
  })
  let hash = Envelope.Hex.encode(await sha256(artifact))
  let deploy = `{"interface": "deployments", "operation": "deploy", "input": {
    "runs": {"name": "app", "id": 1}, "version": "${hash}", "form": "modules",
    "isolation": ["isolate"], "artifact": {"address": "https://artifacts.example/hello",
    "hash": "${hash}"}, "footing": "https://footing.invalid", "secrets": {},
    "network": ["http", "tcp"]}}`
  let running = success(
    `{"runs": {"name": "app", "id": 1}, "version": "${hash}",
    "state": {"name": "running", "address": "app-1.my-subdomain.workers.dev",
    "runtime": "workers", "isolation": ["isolate"]}}`,
  )
  let deployed = await call(env, ~path="/deployments/deploy", ~body=deploy)
  let describe = `{"interface": "deployments", "operation": "describe",
    "input": {"runs": {"name": "app", "id": 1}}}`
  let described = await call(env, ~path="/deployments/describe", ~body=describe)
  restore()
  deepEqual(deployed, (200, Some("application/json"), running))
  deepEqual(described, (200, Some("application/json"), running))
  deepEqual(
    asked->Array.map(a =>
      a->String.replace(
        "https://api.cloudflare.com/client/v4/accounts/023e105f4ecef8ad9ca31a8372d0c353",
        "",
      )
    ),
    [
      "GET /workers/scripts/app-1/deployments",
      "GET https://artifacts.example/hello",
      "POST /workers/scripts/app-1/versions",
      "POST /workers/scripts/app-1/deployments",
      "GET /workers/subdomain",
      "GET /workers/subdomain",
    ],
  )
})

test(
  "an artifact's address a Worker cannot fetch is unfetchable, and nothing is made",
  async () => {
    let env = envOf()
    let restore = replaced(async (_, _) => answerText(Documented.notFound, {status: 404}))
    let deploy = address =>
      `{"interface": "deployments", "operation": "deploy", "input": {
    "runs": {"name": "app", "id": 1}, "version": "${binding}", "form": "modules",
    "isolation": ["isolate"], "artifact": {"address": "${address}", "hash": "${binding}"},
    "footing": "https://footing.invalid", "secrets": {}, "network": ["http", "tcp"]}}`
    let plain = await call(
      env,
      ~path="/deployments/deploy",
      ~body=deploy("http://artifacts.example"),
    )
    let none = await call(env, ~path="/deployments/deploy", ~body=deploy("artifacts"))
    restore()
    let unfetchable = (503, Some(JSON.String("unfetchable")))
    deepEqual((reasonOf(plain), reasonOf(none)), (unfetchable, unfetchable))
  },
)

let messageOf = ((_, _, json)) =>
  json->JSON.Decode.object->Option.flatMap(o => o->Dict.get("message"))

/** A first deploy of `artifact` from an address, `served` answering first and the account after. */
let deployedFrom = async (address, ~served) => {
  let env = envOf()
  let account = Account.make(~artifacts=dict{})
  let fetched = []
  let restore = replaced(async (url, init) =>
    switch served(url) {
    | Some(answer) =>
      fetched->Array.push(url)
      answer
    | None => await account(url, init)
    }
  )
  let hash = Envelope.Hex.encode(await sha256(artifact))
  let deploy = `{"interface": "deployments", "operation": "deploy", "input": {
    "runs": {"name": "app", "id": 1}, "version": "${hash}", "form": "modules",
    "isolation": ["isolate"], "artifact": {"address": "${address}", "hash": "${hash}"},
    "footing": "https://footing.invalid", "secrets": {}, "network": ["http", "tcp"]}}`
  let answered = await call(env, ~path="/deployments/deploy", ~body=deploy)
  restore()
  (answered, fetched)
}

let tooLarge = (400, Some(JSON.String("too_large")))
let largest = 67_108_864

test("an artifact past the bound is too large, by its length or by what came", async () => {
  let said = Dict.fromArray([("content-length", Int.toString(largest + 1))])
  let (byLength, _) = await deployedFrom("https://artifacts.example/said", ~served=url =>
    url->String.startsWith("https://artifacts.example")
      ? Some(answerWith(Web.utf8("small"), {status: 200, headers: said}))
      : None
  )
  deepEqual(reasonOf(byLength), tooLarge)
  let (byBytes, _) = await deployedFrom("https://artifacts.example/sent", ~served=url =>
    url->String.startsWith("https://artifacts.example")
      ? Some(answerBytes(Uint8Array.fromLength(largest + 1), {status: 200}))
      : None
  )
  deepEqual(reasonOf(byBytes), tooLarge)
})

test("an artifact's body is read no further than the bound, though it never ends", async () => {
  let (body, pulled) = endless()
  let (answered, _) = await deployedFrom("https://artifacts.example/endless", ~served=url =>
    url->String.startsWith("https://artifacts.example") ? Some(body) : None
  )
  deepEqual(reasonOf(answered), tooLarge)
  ok(pulled.contents <= largest / 1048576 + 2)
})

test("an artifact's redirect is followed to https alone, and only so often", async () => {
  let redirect = location => Some(
    answerWith(Uint8Array.fromLength(0), {status: 302, headers: dict{"location": location}}),
  )
  let (followed, fetched) = await deployedFrom("https://artifacts.example/a", ~served=url =>
    switch url {
    | "https://artifacts.example/a" => redirect("/b")
    | "https://artifacts.example/b" => Some(answerBytes(artifact, {status: 200}))
    | _ => None
    }
  )
  let (status, _, _) = followed
  deepEqual(
    (status, fetched),
    (200, ["https://artifacts.example/a", "https://artifacts.example/b"]),
  )
  let (plain, _) = await deployedFrom("https://artifacts.example/a", ~served=url =>
    url->String.startsWith("https://artifacts.example") || url->String.startsWith("http:")
      ? redirect("http://artifacts.example/b")
      : None
  )
  deepEqual(
    (reasonOf(plain), messageOf(plain)),
    ((503, Some(JSON.String("unfetchable"))), Some(JSON.String("an artifact's address is https:"))),
  )
  let (looping, fetched) = await deployedFrom("https://artifacts.example/a", ~served=url =>
    url->String.startsWith("https://artifacts.example") ? redirect("/a") : None
  )
  deepEqual(
    (messageOf(looping), Array.length(fetched)),
    (Some(JSON.String("the artifact's address redirects too often")), 11),
  )
})

test("an apply naming a token twice holds it once", async () => {
  let env = envOf()
  let held = Envelope.Hex.encode(Keys.Hash.plain(secret))
  let (status, _, _) = await manage(
    env,
    "apply",
    `{"generation": 1, "items": [], "tokens": ["${held}", "${held}"]}`,
  )
  deepEqual(status, 200)
  let (described, _, _) = await manage(env, "describe", "{}")
  deepEqual(described, 200)
})

test("a token not checked for a fault tells the caller nothing of why", async () => {
  let env = envOf(~db=refusing(database(), "SELECT hash FROM tokens"), ())
  let answered = await manage(env, "describe", "{}")
  deepEqual(
    (reasonOf(answered), messageOf(answered)),
    ((500, Some(JSON.String("fault"))), Some(JSON.String("the call's token was not checked"))),
  )
})

test("a deployments, a denied or a malformed call leaves D1 unswept and unwritten", async () => {
  let sqlite = migrated()
  let env = envOf(~db=asDatabase(sqlite), ())
  ignore(await manage(env, "set_policy", `{"generation": 1, "grace": 0}`))
  ignore(await manage(env, "apply", `{"generation": 1, "items": [${item}]}`))
  ignore(await manage(env, "apply", `{"generation": 2, "items": []}`))
  let before = rows(sqlite)
  let describe = `{"interface": "deployments", "operation": "describe",
    "input": {"runs": {"name": "app", "id": 1}}}`
  let found = await call(env, ~path="/deployments/describe", ~body=describe)
  let wrong = `Bearer 1.${Envelope.Base64url.encode(other)}`
  let denied = await call(
    env,
    ~path="/management/describe",
    ~body=management("describe", "{}"),
    ~authorization=wrong,
  )
  let malformed = await call(env, ~path="/management/describe", ~body="{")
  deepEqual(
    [reasonOf(found), reasonOf(denied), reasonOf(malformed)],
    [
      (404, Some(JSON.String("not_found"))),
      (403, Some(JSON.String("denied"))),
      (400, Some(JSON.String("malformed"))),
    ],
  )
  deepEqual(rows(sqlite), before)
  ok(before->String.includes("unasked"), ~message="the item unasked is held until a sweep")
})

test("the stub's answer in CBOR is the error stopped, as the codec reads it", async () => {
  let source = DriverCloudflareFunction.Function.stub.modules->Array.getUnsafe(0)
  let worker = (await imported(Web.fromUtf8(source.bytes)->Option.getOrThrow)).default
  let answer = worker.fetch(
    request("https://app-1.example/echo", {method: "POST", headers: dict{}}),
  )
  let read =
    (await answer->Web.responseBytes)
    ->Codec.Cbor.decodeDeterministic
    ->Result.getOrThrow
    ->Contracts.Answer.fromCbor(Contracts.DeploymentDeleted.fromCbor)
  deepEqual(
    (answer->Web.status, read),
    (
      503,
      Ok(
        Contracts.Answer.Error({
          failure: Unavailable,
          reason: "stopped",
          message: "What was called is stopped",
        }),
      ),
    ),
  )
})
