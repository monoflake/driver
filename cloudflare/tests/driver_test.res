/***
 * The Worker `driver` answering requests over node's SQLite standing in for its D1, its migrations
 * applied, and Cloudflare's API answered by its documented examples, `documented.res`.
 */
open Node
module Contracts = Envelope.Contracts
module Function = DriverCloudflareFunction.Function

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

test("a database item is made at the Worker `database`'s address, as an object is", async () => {
  let env = envOf()
  let restore = replaced(Account.make(~artifacts=dict{}))
  let database = `{"id": 2, "capacity": {"name": "database", "size": 1048576},
    "credentials": ["af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"]}`
  let (_, _, applied) = await manage(
    env,
    "apply",
    `{"generation": 1, "items": [${item}, ${database}]}`,
  )
  restore()
  deepEqual(applied, success(`{"generation": 1}`))
  let (_, _, described) = await manage(env, "describe", "{}")
  deepEqual(
    described,
    success(`{"generation": 1, "policy": 0, "grace": 604800, "items": [{"id": 1,
    "capacity": {"name": "object", "size": 1048576}, "state": {"name": "made",
    "address": "object-0a1b2c3d.my-subdomain.workers.dev"}}, {"id": 2,
    "capacity": {"name": "database", "size": 1048576}, "state": {"name": "made",
    "address": "database-0a1b2c3d.my-subdomain.workers.dev"}}]}`),
  )
})

test(
  "a list is kept in D1, its object made at the Worker's address, unasked, then swept",
  async () => {
    let env = envOf()
    let restore = replaced(Account.make(~artifacts=dict{}))
    let (_, _, applied) = await manage(env, "apply", `{"generation": 1, "items": [${item}]}`)
    restore()
    deepEqual(applied, success(`{"generation": 1}`))
    let (_, _, described) = await manage(env, "describe", "{}")
    deepEqual(
      described,
      success(`{"generation": 1, "policy": 0, "grace": 604800, "items": [{"id": 1,
      "capacity": {"name": "object", "size": 1048576}, "state": {"name": "made",
      "address": "object-0a1b2c3d.my-subdomain.workers.dev"}}]}`),
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
  let sqlite = migrated()
  let env = envOf(~db=asDatabase(sqlite), ())
  let asked = []
  let restore = replaced(async (url, init) => {
    asked->Array.push(`${init.method} ${url}`)
    let api = "https://api.cloudflare.com/client/v4/accounts/023e105f4ecef8ad9ca31a8372d0c353"
    switch (init.method, url->String.replace(api, "")) {
    | ("GET", "https://artifacts.example/hello") => answerBytes(artifact, {status: 200})
    | ("GET", "/workers/scripts/app-1-0a1b2c3d/deployments") =>
      answerText(Documented.notFound, {status: 404})
    | ("POST", "/workers/scripts/app-1-0a1b2c3d/versions") =>
      answerText(Documented.versionUploaded, {status: 200})
    | ("POST", "/workers/scripts/app-1-0a1b2c3d/deployments") =>
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
    "state": {"name": "running", "address": "app-1-0a1b2c3d.my-subdomain.workers.dev",
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
      "GET /workers/scripts/app-1-0a1b2c3d/deployments",
      "GET https://artifacts.example/hello",
      "POST /workers/scripts/app-1-0a1b2c3d/versions",
      "POST /workers/scripts/app-1-0a1b2c3d/deployments",
      "GET /workers/subdomain",
      "GET /workers/subdomain",
    ],
  )
  // The deployment is kept by its Worker's whole name, the install id in it.
  ok(rows(sqlite)->String.includes(`"worker":"app-1-0a1b2c3d"`), ~message=rows(sqlite))
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
  let restore = replaced(Account.make(~artifacts=dict{}))
  ignore(await manage(env, "apply", `{"generation": 1, "items": [${item}]}`))
  restore()
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

test("a Worker whose INSTALL_ID or KINDS is not as install sets it answers fault", async () => {
  let kinds = "function,object,database"
  let unid = "INSTALL_ID is unset or not 8 lowercase hex digits, so install broke"
  let cases = [
    (dict{"KINDS": kinds}, unid),
    (dict{"INSTALL_ID": "", "KINDS": kinds}, unid),
    (dict{"INSTALL_ID": "0A1B2C3D", "KINDS": kinds}, unid),
    (dict{"INSTALL_ID": "0a1b2c3", "KINDS": kinds}, unid),
    (dict{"INSTALL_ID": "0a1b2c3d0", "KINDS": kinds}, unid),
    (dict{"INSTALL_ID": installId}, "KINDS is unset, so install broke"),
    (dict{"INSTALL_ID": installId, "KINDS": " "}, "KINDS is empty, so install broke"),
    (
      dict{"INSTALL_ID": installId, "KINDS": "function,instance"},
      `KINDS names "instance", where each is function, object or database, so install broke`,
    ),
    (
      dict{"INSTALL_ID": installId, "KINDS": "function,"},
      `KINDS names "", where each is function, object or database, so install broke`,
    ),
  ]
  let answers = await Promise.all(
    cases->Array.map(async ((vars, _)) => {
      let env = envOf(~vars, ())
      // A misinstall is told before the token, so a caller without one is told it too.
      let answered = await call(
        env,
        ~path="/management/describe",
        ~body=management("describe", "{}"),
        ~authorization="",
      )
      (reasonOf(answered), messageOf(answered))
    }),
  )
  deepEqual(
    answers,
    cases->Array.map(((_, message)) => (
      (500, Some(JSON.String("fault"))),
      Some(JSON.String(message)),
    )),
  )
  let (status, _, _) = await manage(
    envOf(~vars=dict{"INSTALL_ID": installId, "KINDS": "function"}, ()),
    "describe",
    "{}",
  )
  deepEqual(status, 200)
})

test("a list naming a kind KINDS does not offer is refused whole as beyond_host", async () => {
  let env = envOf(~vars=dict{"INSTALL_ID": installId, "KINDS": "function"}, ())
  let asked = []
  let restore = replaced(async (url, _) => {
    asked->Array.push(url)
    answerText("{}", {status: 500})
  })
  let refused = await manage(env, "apply", `{"generation": 1, "items": [${item}]}`)
  deepEqual(
    (reasonOf(refused), messageOf(refused)),
    (
      (400, Some(JSON.String("beyond_host"))),
      Some(JSON.String("item 1: object is not offered, only function")),
    ),
  )
  let (_, _, described) = await manage(env, "describe", "{}")
  deepEqual(described, success(`{"generation": 0, "policy": 0, "grace": 604800, "items": []}`))
  let objects = envOf(~db=database(), ~vars=dict{"INSTALL_ID": installId, "KINDS": "object"}, ())
  ignore(await manage(objects, "apply", `{"generation": 2, "items": []}`))
  // A list behind is answered by the generation held, before its kinds are read.
  let behind = await manage(objects, "apply", `{"generation": 1, "items": [${item}]}`)
  let database = `{"id": 2, "capacity": {"name": "database", "size": 1048576},
    "credentials": ["af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"]}`
  let unoffered = await manage(objects, "apply", `{"generation": 3, "items": [${database}]}`)
  restore()
  deepEqual(behind, (200, Some("application/json"), success(`{"generation": 2}`)))
  deepEqual(
    (reasonOf(unoffered), messageOf(unoffered)),
    (
      (400, Some(JSON.String("beyond_host"))),
      Some(JSON.String("item 2: database is not offered, only object")),
    ),
  )
  deepEqual(asked, [])
})

test(
  "with KINDS lacking function, deploy is beyond the host and no deployment is found",
  async () => {
    let env = envOf(~vars=dict{"INSTALL_ID": installId, "KINDS": "object,database"}, ())
    let asked = []
    let restore = replaced(async (url, _) => {
      asked->Array.push(url)
      answerText("{}", {status: 500})
    })
    let runs = `{"runs": {"name": "app", "id": 1}}`
    let deploy = `{"runs": {"name": "app", "id": 1}, "version": "${binding}", "form": "modules",
    "isolation": ["isolate"], "artifact": {"address": "https://artifacts.example/hello",
    "hash": "${binding}"}, "footing": "https://footing.invalid", "secrets": {},
    "network": ["http", "tcp"]}`
    let answers = await Promise.all(
      [
        ("deploy", deploy),
        ("stop", runs),
        ("resume", runs),
        ("describe", runs),
        ("delete", runs),
      ]->Array.map(async ((operation, input)) => {
        let body = `{"interface": "deployments", "operation": "${operation}", "input": ${input}}`
        let answered = await call(env, ~path=`/deployments/${operation}`, ~body)
        let (_, reason) = reasonOf(answered)
        (operation, reason, messageOf(answered))
      }),
    )
    restore()
    let none = Some(JSON.String("no deployment is kept, function not being offered, by KINDS"))
    deepEqual(
      answers,
      [
        (
          "deploy",
          Some(JSON.String("beyond_host")),
          Some(JSON.String("function is not offered, by KINDS")),
        ),
        ("stop", Some(JSON.String("not_found")), none),
        ("resume", Some(JSON.String("not_found")), none),
        ("describe", Some(JSON.String("not_found")), none),
        ("delete", None, None),
      ],
    )
    deepEqual(asked, [])
  },
)

test("only a name ending in its own install id is the driver's own", async () => {
  let owned = name => Installed.owned(name, ~id=installId)
  deepEqual(
    [
      "app-1-0a1b2c3d",
      "component-hello-0a1b2c3d",
      "driver-0a1b2c3d",
      "app-1",
      "driver",
      "app-1-ffffffff",
      "app-1-0a1b2c3d-0a1b2c3d0",
      "-0a1b2c3d",
      "Hello-0a1b2c3d",
      "hello_world-0a1b2c3d",
    ]->Array.map(owned),
    [true, true, true, false, false, false, false, false, false, false],
  )
  deepEqual(Installed.held("app-1-0a1b2c3d", ~id=installId), Ok("app-1-0a1b2c3d"))
  deepEqual(
    [
      Installed.held("component-Hello-0a1b2c3d", ~id=installId),
      Installed.held("app-1", ~id=installId),
      Installed.held("app-1-ffffffff", ~id=installId),
    ]->Array.map(held => held->Result.mapError(r => r.reason)),
    [Error("fault"), Error("fault"), Error("fault")],
  )
})

test("a deployment whose Worker's name is not in the id form is refused untouched", async () => {
  let env = envOf()
  let asked = []
  let restore = replaced(async (url, _) => {
    asked->Array.push(url)
    answerText("{}", {status: 500})
  })
  let runs = `{"name": "component", "component": "Hello_World"}`
  let deploy = `{"interface": "deployments", "operation": "deploy", "input": {
    "runs": ${runs}, "version": "${binding}", "form": "modules",
    "isolation": ["isolate"], "artifact": {"address": "https://artifacts.example/hello",
    "hash": "${binding}"}, "footing": "https://footing.invalid", "secrets": {},
    "network": ["http", "tcp"]}}`
  let deployed = await call(env, ~path="/deployments/deploy", ~body=deploy)
  let delete = `{"interface": "deployments", "operation": "delete", "input": {"runs": ${runs}}}`
  let deleted = await call(env, ~path="/deployments/delete", ~body=delete)
  restore()
  deepEqual(reasonOf(deployed), (500, Some(JSON.String("fault"))))
  deepEqual(reasonOf(deleted), (500, Some(JSON.String("fault"))))
  deepEqual(
    messageOf(deleted),
    Some(
      JSON.String(
        "component-Hello_World-0a1b2c3d is not in the driver's id form, so it is never acted on",
      ),
    ),
  )
  deepEqual(asked, [])
})

test("the guard answers fault for a name the driver formed, never calling Cloudflare", async () => {
  let asked = []
  let reached = name => {
    asked->Array.push(name)
    Promise.resolve(Error({Function.reason: "fault", message: "reached"}))
  }
  let account: Function.api = {
    upload: (name, _) => reached(name),
    deploy: (name, _) => reached(name),
    running: name => reached(name)->Promise.thenResolve(r => r->Result.map(_ => None)),
    delete: name => reached(name)->Promise.thenResolve(r => r->Result.map(_ => ())),
    address: reached,
  }
  let held = account->Installed.api(~id=installId)
  let reasons = [
    (await held.address("object-ffffffff"))->Result.mapError(r => r.reason),
    (await held.address("object"))->Result.mapError(r => r.reason),
    (await held.delete("app-1-ffffffff"))->Result.mapError(r => r.reason)->Result.map(_ => ""),
  ]
  deepEqual(reasons, [Error("fault"), Error("fault"), Error("fault")])
  deepEqual(asked, [])
  ignore(await held.address("object-0a1b2c3d"))
  deepEqual(asked, ["object-0a1b2c3d"])
})
