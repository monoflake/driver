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
        "revision": "4b825dc", "kinds": ["function", "object", "database"], "adopted": []}`),
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
    "address": "2c3d4e5f.my-subdomain.workers.dev"}}, {"id": 2,
    "capacity": {"name": "database", "size": 1048576}, "state": {"name": "made",
    "address": "4e5f6a7b.my-subdomain.workers.dev"}}],
    "kinds": ["function", "object", "database"], "adopted": []}`),
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
      "address": "2c3d4e5f.my-subdomain.workers.dev"}}],
      "kinds": ["function", "object", "database"], "adopted": []}`),
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
        success(`{"generation": 2, "policy": 1, "grace": 0, "items": [],
        "kinds": ["function", "object", "database"], "adopted": []}`),
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
    Ok(
      success(`{"generation": 0, "policy": 0, "grace": 604800, "items": [],
      "kinds": ["function", "object", "database"], "adopted": []}`),
    ),
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
  let sqlite = installed()
  let env = envOf(~db=asDatabase(sqlite), ())
  let asked = []
  let restore = replaced(async (url, init) => {
    asked->Array.push(`${init.method} ${url}`)
    let api = "https://api.cloudflare.com/client/v4/accounts/023e105f4ecef8ad9ca31a8372d0c353"
    switch (init.method, url->String.replace(api, "")) {
    | ("GET", "https://artifacts.example/hello") => answerBytes(artifact, {status: 200})
    | ("GET", "/workers/scripts/00000001") => answerText(Documented.notFound, {status: 404})
    | ("GET", "/workers/scripts/00000001/deployments") =>
      answerText(Documented.notFound, {status: 404})
    | ("POST", "/workers/scripts/00000001/versions") =>
      answerText(Documented.versionUploaded, {status: 200})
    | ("POST", "/workers/scripts/00000001/deployments") =>
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
    "state": {"name": "running", "address": "00000001.my-subdomain.workers.dev",
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
      "GET /workers/scripts/00000001",
      "GET /workers/scripts/00000001/deployments",
      "GET https://artifacts.example/hello",
      // The upload reads the Worker's tag first, and finds none there.
      "GET /workers/scripts/00000001/deployments",
      "GET /workers/scripts/00000001",
      "POST /workers/scripts/00000001/versions",
      "POST /workers/scripts/00000001/deployments",
      "GET /workers/subdomain",
      "GET /workers/subdomain",
    ],
  )
  // The deployment is kept by its Worker's name, its id bare, and recorded as the driver's.
  ok(rows(sqlite)->String.includes(`"worker":"00000001"`), ~message=rows(sqlite))
  ok(
    rows(sqlite)->String.includes(`{"name":"00000001","role":"deployment"}`),
    ~message=rows(sqlite),
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
  let sqlite = installed()
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
  deepEqual(
    described,
    success(`{"generation": 0, "policy": 0, "grace": 604800, "items": [],
    "kinds": ["function"], "adopted": []}`),
  )
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

/** A fake account's API, each name it reaches pushed onto `asked`, its version tagged `tag`. */
let reaching = (~tag=?, asked) => {
  let reached = name => {
    asked->Array.push(name)
    Promise.resolve(Ok("reached"))
  }
  let account: Function.api = {
    upload: (name, _) => reached(name),
    deploy: (name, _) => reached(name)->Promise.thenResolve(r => r->Result.map(_ => ())),
    running: name =>
      reached(name)->Promise.thenResolve(r =>
        r->Result.map(_ => tag->Option.map((tag): Function.running => {id: "v1", tag: Some(tag)}))
      ),
    delete: name => reached(name)->Promise.thenResolve(r => r->Result.map(_ => ())),
    address: reached,
  }
  account
}

let outcome = (result: result<_, Function.refused>) =>
  switch result {
  | Ok(_) => "ok"
  | Error(refused) => refused.reason
  }

test("the guard acts on a name the records hold alone, whatever its form", async () => {
  let asked = []
  let exists = _ => Promise.resolve(Ok(true))
  let held =
    reaching(~tag="0a1b2c3d/00000001/stopped", asked)->Installed.api(
      ~held=["00000001", "my-own-name"],
      ~listed=[],
      ~exists,
      ~install="0a1b2c3d",
      ~owner="00000001",
    )
  deepEqual(
    [
      outcome(await held.address("00000001")),
      outcome(await held.address("my-own-name")),
      outcome(await held.delete("00000001")),
      outcome(await held.address("00000002")),
      outcome(await held.delete("driver-0a1b2c3d")),
      outcome(await held.running("1b2c3d4e")),
    ],
    ["ok", "ok", "ok", "fault", "fault", "fault"],
  )
  // A delete reads the Worker's tag first, which it carries.
  deepEqual(asked, ["00000001", "my-own-name", "00000001", "00000001"])
})

test("a listed name passes the guard by the list alone, never deleted and never made", async () => {
  let asked = []
  let there = ref(true)
  let looked = []
  let exists = name => {
    looked->Array.push(name)
    Promise.resolve(Ok(there.contents))
  }
  let held =
    reaching(asked)->Installed.api(
      ~held=[],
      ~listed=["shop-front"],
      ~exists,
      ~install="0a1b2c3d",
      ~owner="00000001",
    )
  let upload: Function.upload = {bundle: Function.stub, bindings: [], tag: "stopped"}
  deepEqual(
    [
      outcome(await held.address("shop-front")),
      outcome(await held.running("shop-front")),
      outcome(await held.upload("shop-front", upload)),
      outcome(await held.delete("shop-front")),
      outcome(await held.address("shop-back")),
    ],
    ["ok", "ok", "ok", "fault", "fault"],
  )
  there := false
  deepEqual(outcome(await held.upload("shop-front", upload)), "beyond_host")
  deepEqual(asked, ["shop-front", "shop-front", "shop-front"])
  deepEqual(looked, ["shop-front", "shop-front"])
  let seen = Installed.seen(exists, ~read=["old-blog"])
  deepEqual(outcome(await seen("old-shop")), "fault")
  deepEqual(looked, ["shop-front", "shop-front"])
})

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

test("a component's Worker is named by its id bare, as an app's is", async () => {
  let env = envOf()
  let restore = await accountHolding([])
  let (_, _, deployed) = await deploying(env, "deploy", await deployInput(component("3735928559")))
  restore()
  let address =
    deployed
    ->Account.member("data")
    ->Option.flatMap(d => d->Account.member("state"))
    ->Option.flatMap(s => s->Account.member("address"))
  deepEqual(address, Some(JSON.String("deadbeef.my-subdomain.workers.dev")))
})

test("a deployment's id of no resource's form is malformed, Cloudflare never reached", async () => {
  let env = envOf()
  let asked = []
  let restore = await accountHolding(~asked, [])
  let answers = []
  let ids = ["-1", "1.5", "4294967296"]
  for at in 0 to Array.length(ids) - 1 {
    let id = ids->Array.getUnsafe(at)
    let input = await deployInput(component(id))
    answers->Array.push(reasonOf(await deploying(env, "deploy", input)))
    answers->Array.push(reasonOf(await deploying(env, "delete", `{"runs": ${component(id)}}`)))
  }
  restore()
  ok(answers->Array.every(a => a == (400, Some(JSON.String("malformed")))))
  deepEqual(asked, [])
})

test("a Worker of the deployment's name the driver did not make is never overwritten", async () => {
  let sqlite = installed()
  let env = envOf(~db=asDatabase(sqlite), ())
  let asked = []
  let restore = await accountHolding(~asked, ["00000001"])
  let deployed = await deploying(env, "deploy", await deployInput(app(1)))
  let deleted = await deploying(env, "delete", `{"runs": ${app(1)}}`)
  restore()
  deepEqual(reasonOf(deployed), (400, Some(JSON.String("beyond_host"))))
  deepEqual(reasonOf(deleted), (200, None))
  deepEqual(asked, ["GET /workers/scripts/00000001"])
  ok(!(rows(sqlite)->String.includes(`"00000001"`)), ~message=rows(sqlite))
})

test("a deployment whose id names one of the driver's own parts is beyond the host", async () => {
  let env = envOf()
  let asked = []
  let restore = await accountHolding(~asked, [])
  // The Worker `object`'s name, 2c3d4e5f, read as a resource id.
  let runs = app(0x2c3d4e5f)
  let deployed = await deploying(env, "deploy", await deployInput(runs))
  let deleted = await deploying(env, "delete", `{"runs": ${runs}}`)
  let described = await deploying(env, "describe", `{"runs": ${runs}}`)
  restore()
  deepEqual(
    (reasonOf(deployed), messageOf(deployed)),
    (
      (400, Some(JSON.String("beyond_host"))),
      Some(JSON.String("2c3d4e5f is the driver's own Worker object, so nothing runs as it")),
    ),
  )
  deepEqual(
    (reasonOf(deleted), reasonOf(described)),
    ((200, None), (404, Some(JSON.String("not_found")))),
  )
  deepEqual(asked, [])
})

test("a deployment never made is deleted by nothing, Cloudflare not reached", async () => {
  let env = envOf()
  let asked = []
  let restore = await accountHolding(~asked, [])
  let deleted = await deploying(env, "delete", `{"runs": ${app(7)}}`)
  restore()
  deepEqual((reasonOf(deleted), asked), ((200, None), []))
})

test("a deployment deleted lets its record go with its Worker", async () => {
  let sqlite = installed()
  let env = envOf(~db=asDatabase(sqlite), ())
  let restore = await accountHolding([])
  ignore(await deploying(env, "deploy", await deployInput(app(1))))
  ignore(await deploying(env, "stop", `{"runs": ${app(1)}}`))
  let (status, _, _) = await deploying(env, "delete", `{"runs": ${app(1)}}`)
  restore()
  deepEqual(status, 200)
  ok(!(rows(sqlite)->String.includes(`"00000001"`)), ~message=rows(sqlite))
})

/** An apply adopting the organization's Workers for apps. */
let adopting = (generation, adopted) =>
  `{"generation": ${Int.toString(generation)}, "items": [], "adopted": ${adopted}}`

/** The organization's Worker `name` listed for app `id`, a made-up name. */
let listing = (name, id) =>
  `{"kind": "function", "name": "${name}",
  "for": {"name": "deployment", "runs": {"name": "app", "id": ${Int.toString(id)}}}}`

let shopFront = listing("shop-front", 1)
let docsPages = listing("docs-pages", 2)

/** The data of a management describe, by one of its fields. */
let describedOf = async (env, key) => {
  let (_, _, json) = await manage(env, "describe", "{}")
  json
  ->JSON.Decode.object
  ->Option.flatMap(o => o->Dict.get("data"))
  ->Option.flatMap(d => d->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key)))
}

/** Each warning's reason and name, as describe answers them. */
let warnedOf = async env =>
  (await describedOf(env, "warnings"))
  ->Option.flatMap(JSON.Decode.array)
  ->Option.map(warnings =>
    warnings->Array.map(w => {
      let text = key => w->Account.member(key)->Option.flatMap(JSON.Decode.string)->Option.getOr("")
      (text("reason"), text("name"), text("message")->String.includes(text("name")))
    })
  )

test("an adopted list is kept in D1 as given and described with the kinds offered", async () => {
  let env = envOf()
  let restore = await accountHolding(["shop-front", "docs-pages"])
  let (_, _, applied) = await manage(env, "apply", adopting(1, `[${shopFront}, ${docsPages}]`))
  deepEqual(applied, success(`{"generation": 1}`))
  deepEqual(
    await describedOf(env, "adopted"),
    Some(JSON.parseOrThrow(`[${shopFront}, ${docsPages}]`)),
  )
  deepEqual(
    await describedOf(env, "kinds"),
    Some(JSON.parseOrThrow(`["function", "object", "database"]`)),
  )
  ignore(await manage(env, "apply", `{"generation": 2, "items": []}`))
  deepEqual(
    await describedOf(env, "adopted"),
    Some(JSON.parseOrThrow(`[${shopFront}, ${docsPages}]`)),
  )
  deepEqual(await warnedOf(env), None)
  restore()
})

test("an adopted list not exact, or beyond what is offered, is refused whole", async () => {
  let env = envOf(~vars=dict{"INSTALL_ID": installId, "KINDS": "function,object"}, ())
  let restore = await accountHolding(["shop-front"])
  let refused = async adopted => reasonOf(await manage(env, "apply", adopting(1, adopted)))
  let invalid = (400, Some(JSON.String("invalid")))
  let beyond = (400, Some(JSON.String("beyond_host")))
  deepEqual(await refused(`[${listing("shop-*", 1)}]`), invalid)
  deepEqual(await refused(`[${listing("Shop-Front", 1)}]`), invalid)
  deepEqual(await refused(`[${shopFront}, ${shopFront}]`), invalid)
  let item = `{"kind": "function", "name": "a", "for": {"name": "item", "id": 2}}`
  deepEqual(await refused(`[${item}]`), invalid)
  let photos = `{"kind": "object", "name": "photos", "for": {"name": "item", "id": 2}}`
  deepEqual(await refused(`[${photos}]`), beyond)
  let ledger = `{"kind": "database", "name": "ledger", "for": {"name": "item", "id": 3}}`
  deepEqual(await refused(`[${ledger}]`), beyond)
  deepEqual(await describedOf(env, "generation"), Some(JSON.Number(0.)))
  restore()
})

test("a listed name the records hold, or the account lacks, is refused as invalid", async () => {
  let sqlite = installed()
  let env = envOf(~db=asDatabase(sqlite), ())
  let restore = await accountHolding(["2c3d4e5f", "0a1b2c3d"])
  ignore(await deploying(env, "deploy", await deployInput(app(2))))
  let refused = async (name, id) => {
    let answered = await manage(env, "apply", adopting(1, `[${listing(name, id)}]`))
    (reasonOf(answered), messageOf(answered))
  }
  let invalid = message => ((400, Some(JSON.String("invalid"))), Some(JSON.String(message)))
  deepEqual(
    await refused("2c3d4e5f", 1),
    invalid("2c3d4e5f is the driver's own Worker object, never listed"),
  )
  deepEqual(
    await refused("0a1b2c3d", 1),
    invalid("0a1b2c3d is the driver's own state D1, never listed"),
  )
  deepEqual(
    await refused("00000002", 1),
    invalid("00000002 is a deployment's Worker the driver made, so it is never listed"),
  )
  deepEqual(
    await refused("shop-front", 1),
    invalid("shop-front is no Worker on the account, and adoption takes only what is there"),
  )
  deepEqual(
    await refused("00000002", 2),
    invalid("00000002 is a deployment's Worker the driver made, so it is never listed"),
  )
  restore()
  deepEqual(rows(sqlite)->String.includes(`"adopted"`), false)
  deepEqual(await describedOf(env, "generation"), Some(JSON.Number(0.)))
})

test("a Worker is not listed for a deployment already running as one", async () => {
  let env = envOf()
  let restore = await accountHolding(["shop-front", "shop-back"])
  ignore(await deploying(env, "deploy", await deployInput(app(2))))
  let answered = await manage(env, "apply", adopting(1, `[${listing("shop-front", 2)}]`))
  deepEqual(
    (reasonOf(answered), messageOf(answered)),
    (
      (400, Some(JSON.String("invalid"))),
      Some(JSON.String("app 2 runs as 00000002 already, so shop-front waits until it is deleted")),
    ),
  )
  // One listed and deployed is not renamed in one apply either.
  ignore(await manage(env, "apply", adopting(1, `[${shopFront}]`)))
  ignore(await deploying(env, "deploy", await deployInput(app(1))))
  let renamed = await manage(env, "apply", adopting(2, `[${listing("shop-back", 1)}]`))
  restore()
  deepEqual(reasonOf(renamed), (400, Some(JSON.String("invalid"))))
})

test("a listed Worker stands for its deployment, and is let go, never deleted", async () => {
  let sqlite = installed()
  let env = envOf(~db=asDatabase(sqlite), ())
  let asked = []
  let restore = await accountHolding(~asked, ["shop-front"])
  ignore(await manage(env, "apply", adopting(1, `[${shopFront}]`)))
  let (_, _, deployed) = await deploying(env, "deploy", await deployInput(app(1)))
  let address =
    deployed
    ->Account.member("data")
    ->Option.flatMap(d => d->Account.member("state"))
    ->Option.flatMap(s => s->Account.member("address"))
  deepEqual(address, Some(JSON.String("shop-front.my-subdomain.workers.dev")))
  let runs = `{"runs": ${app(1)}}`
  ignore(await deploying(env, "stop", runs))
  ignore(await deploying(env, "resume", runs))
  ignore(await deploying(env, "stop", runs))
  let (_, _, deleted) = await deploying(env, "delete", runs)
  deepEqual(deleted, success("{}"))
  deepEqual(asked->Array.some(a => a->String.includes("00000001")), false)
  deepEqual(asked->Array.some(a => a->String.startsWith("DELETE")), false)
  deepEqual(await warnedOf(env), Some([("delete_by_hand", "shop-front", true)]))
  // The same list sent again clears no warning.
  ignore(await manage(env, "apply", adopting(2, `[${shopFront}]`)))
  deepEqual(await warnedOf(env), Some([("delete_by_hand", "shop-front", true)]))
  // A deploy to it again manages it once more, and its warning goes.
  ignore(await deploying(env, "deploy", await deployInput(app(1))))
  deepEqual(await warnedOf(env), None)
  restore()
})

test(
  "describe leaves a gone Worker's warning out, writing nothing, and apply removes it",
  async () => {
    let sqlite = installed()
    let env = envOf(~db=asDatabase(sqlite), ())
    let account = Account.make(~artifacts=dict{"https://artifacts.example/hello": artifact})
    ignore(await account(`${Account.api}/workers/scripts/shop-front`, {method: "PUT"}))
    let restore = replaced(account)
    ignore(await manage(env, "apply", adopting(1, `[${shopFront}]`)))
    ignore(await deploying(env, "deploy", await deployInput(app(1))))
    ignore(await manage(env, "apply", adopting(2, `[]`)))
    deepEqual(await warnedOf(env), Some([("delete_by_hand", "shop-front", true)]))
    ok(rows(sqlite)->String.includes(`"worker":"shop-front"`), ~message="the row a release keeps")
    // Deleted by hand, the Worker is gone, and describe leaves its warning out.
    ignore(await account(`${Account.api}/workers/scripts/shop-front`, {method: "DELETE"}))
    let before = rows(sqlite)
    deepEqual(await warnedOf(env), None)
    deepEqual(rows(sqlite), before)
    // The next apply removes the warning and the row it kept.
    ignore(await manage(env, "apply", adopting(3, `[]`)))
    restore()
    deepEqual(rows(sqlite)->String.includes("delete_by_hand"), false)
    deepEqual(rows(sqlite)->String.includes(`"worker":"shop-front"`), false)
  },
)

test("a dropped Worker is warned of only where the driver took it over", async () => {
  let env = envOf()
  let restore = await accountHolding(["shop-front", "docs-pages"])
  ignore(await manage(env, "apply", adopting(1, `[${shopFront}, ${docsPages}]`)))
  ignore(await deploying(env, "deploy", await deployInput(app(2))))
  ignore(await manage(env, "apply", adopting(2, `[]`)))
  let warned = await warnedOf(env)
  // A listed Worker never deployed to, its deployment deleted, is not warned of either.
  ignore(await manage(env, "apply", adopting(3, `[${shopFront}]`)))
  ignore(await deploying(env, "delete", `{"runs": ${app(1)}}`))
  let after = await warnedOf(env)
  restore()
  deepEqual((warned, after), (Some([("delete_by_hand", "docs-pages", true)]), warned))
})

test("a listed Worker the account no longer holds is named missing, never made", async () => {
  let env = envOf()
  let account = Account.make(~artifacts=dict{"https://artifacts.example/hello": artifact})
  ignore(await account(`${Account.api}/workers/scripts/shop-front`, {method: "PUT"}))
  let asked = []
  let restore = replaced(async (url, init) => {
    asked->Array.push(`${init.method} ${url->String.replace(Account.api, "")}`)
    await account(url, init)
  })
  ignore(await manage(env, "apply", adopting(1, `[${shopFront}]`)))
  ignore(await account(`${Account.api}/workers/scripts/shop-front`, {method: "DELETE"}))
  let warned = await warnedOf(env)
  let deployed = await deploying(env, "deploy", await deployInput(app(1)))
  restore()
  deepEqual(warned, Some([("missing", "shop-front", true)]))
  deepEqual(reasonOf(deployed), (400, Some(JSON.String("beyond_host"))))
  deepEqual(asked->Array.some(a => a->String.startsWith("PUT")), false)
})

test(
  "a row of the driver's D1 missing what its kind holds is a fault, never a default",
  async () => {
    let sqlite = installed()
    sqlite->exec(`INSERT INTO adopted (name, kind, runs) VALUES ('shop-front', 'function', 'app')`)
    let answered = await manage(envOf(~db=asDatabase(sqlite), ()), "describe", "{}")
    deepEqual(
      (reasonOf(answered), messageOf(answered)),
      (
        (500, Some(JSON.String("fault"))),
        // The whole state is read to check the token, so the bad row is found there first.
        Some(JSON.String("the call's token was not checked")),
      ),
    )
  },
)

test("a bad row is read as a throw naming what it lacks", async () => {
  let sqlite = installed()
  sqlite->exec(`INSERT INTO adopted (name, kind, runs) VALUES ('shop-front', 'function', 'app')`)
  let read = switch await Kept.management(stored(asDatabase(sqlite))).read() {
  | _ => None
  | exception Kept.Unkept(message) => Some(message)
  }
  deepEqual(read, Some("a row of the driver's D1 holds no adopted app's id"))
  let made = installed()
  let columns = "id, kind, bytes, credentials, state"
  made->exec(`INSERT INTO items (${columns}) VALUES (1, 'object', 1, '', 'made')`)
  let read = switch await Kept.management(stored(asDatabase(made))).read() {
  | _ => None
  | exception Kept.Unkept(message) => Some(message)
  }
  deepEqual(read, Some("a row of the driver's D1 holds no made item's address"))
})

test(
  "a Worker listed for a component stands for it by its id, kept and described whole",
  async () => {
    let sqlite = installed()
    let env = envOf(~db=asDatabase(sqlite), ())
    let asked = []
    let restore = await accountHolding(~asked, ["docs-pages"])
    let pages = `{"kind": "function", "name": "docs-pages",
    "for": {"name": "deployment", "runs": ${component("3")}}}`
    let (_, _, applied) = await manage(env, "apply", adopting(1, `[${pages}]`))
    deepEqual(applied, success(`{"generation": 1}`))
    deepEqual(await describedOf(env, "adopted"), Some(JSON.parseOrThrow(`[${pages}]`)))
    ok(rows(sqlite)->String.includes(`"runs":"component","id":3,"component":"pages"`))
    let (_, _, deployed) = await deploying(env, "deploy", await deployInput(component("3")))
    let address =
      deployed
      ->Account.member("data")
      ->Option.flatMap(d => d->Account.member("state"))
      ->Option.flatMap(s => s->Account.member("address"))
    // Another component, or an app, of the same id is never the listed one's.
    let other = await deploying(env, "describe", `{"runs": ${app(3)}}`)
    restore()
    deepEqual(address, Some(JSON.String("docs-pages.my-subdomain.workers.dev")))
    deepEqual(reasonOf(other), (404, Some(JSON.String("not_found"))))
    deepEqual(asked->Array.some(a => a->String.includes("00000003")), false)
  },
)

test("a Worker is not listed for a component already running as its own", async () => {
  let env = envOf()
  let restore = await accountHolding(["docs-pages"])
  ignore(await deploying(env, "deploy", await deployInput(component("3"))))
  let pages = `{"kind": "function", "name": "docs-pages",
    "for": {"name": "deployment", "runs": ${component("3")}}}`
  let answered = await manage(env, "apply", adopting(1, `[${pages}]`))
  restore()
  deepEqual(
    (reasonOf(answered), messageOf(answered)),
    (
      (400, Some(JSON.String("invalid"))),
      Some(
        JSON.String(
          "component pages 3 runs as 00000003 already, so docs-pages waits until it is deleted",
        ),
      ),
    ),
  )
})

test("a deploy reaching another deployment is beyond the host before any call", async () => {
  let sqlite = installed()
  let env = envOf(~db=asDatabase(sqlite), ())
  let asked = []
  let restore = await accountHolding(~asked, [])
  let input =
    (await deployInput(app(1)))->String.replace(`"network"`, `"reaching": [${app(2)}], "network"`)
  let answered = await deploying(env, "deploy", input)
  restore()
  deepEqual(reasonOf(answered), (400, Some(JSON.String("beyond_host"))))
  deepEqual(asked, [])
  ok(!(rows(sqlite)->String.includes(`"00000001"`)), ~message=rows(sqlite))
})

/** Whether the records hold a name, read from the rows. */
let claims = (sqlite, name) =>
  rows(sqlite)->String.includes(`{"name":"${name}","role":"deployment"}`)

test("a first deploy refused or failed after the claim gives the claim back", async () => {
  let sqlite = installed()
  let env = envOf(~db=asDatabase(sqlite), ())
  let account = Account.make(~artifacts=dict{"https://artifacts.example/hello": artifact})
  let large = "https://artifacts.example/large"
  let restore = replaced(async (url, init) =>
    url == large
      ? answerBytes(Uint8Array.fromLength(67_108_865), {status: 200})
      : await account(url, init)
  )
  let base = await deployInput(app(1))
  let hash = Envelope.Hex.encode(await sha256(artifact))
  let other = String.repeat("ff", 32)
  let artifactAt = address => base->String.replace("https://artifacts.example/hello", address)
  let cases = [
    // A form a Worker cannot give, and a secret under the platform's prefix.
    (base->String.replace(`"isolation": ["isolate"]`, `"isolation": ["vm"]`), "beyond_host"),
    (base->String.replace(`"secrets": {}`, `"secrets": {"MONOFLAKE_FOOTING": "AA"}`), "malformed"),
    // A hash not the artifact's, an artifact past the bound, and one nothing serves.
    (base->String.replace(`"hash": "${hash}"`, `"hash": "${other}"`), "hash_mismatch"),
    (artifactAt(large), "too_large"),
    (artifactAt("https://artifacts.example/none"), "unfetchable"),
  ]
  let answers = []
  for at in 0 to Array.length(cases) - 1 {
    let (input, _) = cases->Array.getUnsafe(at)
    let (_, reason) = reasonOf(await deploying(env, "deploy", input))
    answers->Array.push((reason, claims(sqlite, "00000001")))
  }
  restore()
  deepEqual(answers, cases->Array.map(((_, reason)) => (Some(JSON.String(reason)), false)))
})

test("a first deploy whose upload fails with nothing made gives the claim back", async () => {
  let sqlite = installed()
  let account = Account.make(~artifacts=dict{"https://artifacts.example/hello": artifact})
  // Each upload is refused, so nothing is made.
  let restore = replaced(async (url, init) =>
    url->String.endsWith("/workers/scripts/00000001") && init.method == "PUT"
      ? answerText(`{"success": false, "errors": [], "result": null}`, {status: 500})
      : await account(url, init)
  )
  let failed = await deploying(
    envOf(~db=asDatabase(sqlite), ()),
    "deploy",
    await deployInput(app(1)),
  )
  deepEqual(reasonOf(failed), (500, Some(JSON.String("fault"))))
  deepEqual(claims(sqlite, "00000001"), false, ~message=rows(sqlite))
  restore()
})

test(
  "an existence read whose body breaks is a fault, the claim kept, the deployment failed",
  async () => {
    let sqlite = installed()
    let env = envOf(~db=asDatabase(sqlite), ())
    let restore = replaced(async (url, _) =>
      url->String.endsWith("/workers/scripts/00000001")
        ? broken(404)
        : answerText(Documented.notFound, {status: 404})
    )
    let answered = await deploying(env, "deploy", await deployInput(app(1)))
    restore()
    deepEqual(
      (reasonOf(answered), messageOf(answered)),
      (
        (500, Some(JSON.String("fault"))),
        Some(
          JSON.String(
            "whether 00000001 is on the account is not known, its answer of 404 was not read",
          ),
        ),
      ),
    )
    // Absence is not confirmed, so the claim stays, kept failed for a delete to remove.
    deepEqual(claims(sqlite, "00000001"), true, ~message=rows(sqlite))
    ok(rows(sqlite)->String.includes(`"state":"failed"`), ~message=rows(sqlite))
  },
)

test(
  "a delete whose forget fails is healed by the next, the Worker gone and the claim with it",
  async () => {
    let sqlite = installed()
    let asked = []
    let restore = await accountHolding(~asked, [])
    let env = envOf(~db=asDatabase(sqlite), ())
    ignore(await deploying(env, "deploy", await deployInput(app(1))))
    ignore(await deploying(env, "stop", `{"runs": ${app(1)}}`))
    let broken = envOf(~db=failing(asDatabase(sqlite), "DELETE FROM deployments"), ())
    let first = await deploying(broken, "delete", `{"runs": ${app(1)}}`)
    deepEqual(reasonOf(first), (500, Some(JSON.String("fault"))))
    deepEqual(claims(sqlite, "00000001"), true)
    let again = await deploying(env, "delete", `{"runs": ${app(1)}}`)
    restore()
    deepEqual(reasonOf(again), (200, None))
    deepEqual(claims(sqlite, "00000001"), false, ~message=rows(sqlite))
    deepEqual(asked->Array.filter(a => a->String.startsWith("DELETE"))->Array.length, 2)
  },
)

test("a deployment's own name the organization listed for another is beyond the host", async () => {
  let sqlite = installed()
  let env = envOf(~db=asDatabase(sqlite), ())
  let asked = []
  let restore = await accountHolding(~asked, ["00000002"])
  ignore(await manage(env, "apply", adopting(1, `[${listing("00000002", 1)}]`)))
  let before = Array.length(asked)
  let answered = await deploying(env, "deploy", await deployInput(app(2)))
  restore()
  deepEqual(
    (reasonOf(answered), messageOf(answered)),
    (
      (400, Some(JSON.String("beyond_host"))),
      Some(
        JSON.String(
          [
            "00000002 is the organization's Worker listed for app 1,",
            "so this deployment never runs as it",
          ]->Array.join(" "),
        ),
      ),
    ),
  )
  deepEqual(Array.length(asked), before)
  deepEqual(claims(sqlite, "00000002"), false)
})

test("a name the driver did not form is a fault, never acted on", async () => {
  deepEqual(Installed.formed("0000000c"), Ok("0000000c"))
  ["4294967296", "-1", "1.5", "0000000C", "app-1"]->Array.forEach(name =>
    deepEqual(Installed.formed(name)->Result.mapError(r => r.reason), Error("fault"), ~message=name)
  )
})

test("migration 0006 records only the Workers the driver made", async () => {
  let db = openSqlite(":memory:")
  let migrations = fromBlock("migrations")
  let files =
    list(migrations)->Array.filter(n => n->String.endsWith(".sql"))->Array.toSorted(String.compare)
  let apply = name => db->exec(readText(`${migrations}/${name}`))
  files->Array.filter(n => n < "0006")->Array.forEach(apply)
  db->exec(`INSERT INTO deployments (worker, version, state) VALUES
    ('app-1-0a1b2c3d', 'aa', 'stopped'), ('shop-front', 'aa', 'running'),
    ('old-blog', 'aa', 'stopped')`)
  db->exec(`INSERT INTO adopted (name, kind, runs, id) VALUES ('shop-front', 'function', 'app', 2)`)
  db->exec(`INSERT INTO warnings (name, reason, message) VALUES
    ('old-blog', 'delete_by_hand', 'old-blog is no longer managed')`)
  files->Array.filter(n => n >= "0006")->Array.forEach(apply)
  deepEqual(rows(db)->String.includes(`{"name":"app-1-0a1b2c3d","role":"deployment"}`), true)
  deepEqual(rows(db)->String.includes(`"name":"shop-front","role"`), false)
  deepEqual(rows(db)->String.includes(`"name":"old-blog","role"`), false)
})

test(
  "a held Worker is deleted or overwritten only where it carries its deployment's tag",
  async () => {
    let upload: Function.upload = {bundle: Function.stub, bindings: [], tag: "00000001/stopped"}
    let outcomes = async (~tag=?, ~there) => {
      let asked = []
      let exists = _ => Promise.resolve(Ok(there))
      let held =
        reaching(~tag?, asked)->Installed.api(
          ~held=["00000001"],
          ~listed=[],
          ~exists,
          ~install="0a1b2c3d",
          ~owner="00000001",
        )
      let deleted = await held.delete("00000001")
      let uploaded = await held.upload("00000001", upload)
      let message = switch deleted {
      | Error({message}) => message
      | Ok(_) => ""
      }
      ((outcome(deleted), outcome(uploaded)), message)
    }
    let carries = await outcomes(~tag="0a1b2c3d/00000001/version-00", ~there=true)
    let absent = await outcomes(~there=false)
    deepEqual([carries, absent]->Array.map(((o, _)) => o), [("ok", "ok"), ("ok", "ok")])
    let refused = [
      // Another deployment's tag, the same deployment's of another install, and one bare.
      await outcomes(~tag="0a1b2c3d/00000002/version-00", ~there=true),
      await outcomes(~tag="4e5f6a7b/00000001/version-00", ~there=true),
      await outcomes(~tag="00000001/version-00", ~there=true),
      await outcomes(~tag="v1.0.1", ~there=true),
      await outcomes(~there=true),
    ]
    refused->Array.forEach(((o, message)) => {
      deepEqual(o, ("fault", "fault"))
      deepEqual(message, "00000001 carries no tag the driver gave 00000001, so it is never deleted")
    })
  },
)

test("a deployment whose bare name is listed for another is not found, untouched", async () => {
  let sqlite = installed()
  let env = envOf(~db=asDatabase(sqlite), ())
  let asked = []
  let restore = await accountHolding(~asked, ["00000002"])
  ignore(await manage(env, "apply", adopting(1, `[${listing("00000002", 1)}]`)))
  ignore(await deploying(env, "deploy", await deployInput(app(1))))
  let before = Array.length(asked)
  let answers = []
  let operations = ["stop", "resume", "describe"]
  for at in 0 to Array.length(operations) - 1 {
    let operation = operations->Array.getUnsafe(at)
    answers->Array.push(reasonOf(await deploying(env, operation, `{"runs": ${app(2)}}`)))
  }
  let after = Array.length(asked)
  let listed = await deploying(env, "describe", `{"runs": ${app(1)}}`)
  restore()
  deepEqual(answers, operations->Array.map(_ => (404, Some(JSON.String("not_found")))))
  deepEqual(after, before)
  deepEqual(reasonOf(listed), (200, None))
})

test("a delete healing a failed forget never deletes a Worker made by hand since", async () => {
  let sqlite = installed()
  let served = dict{"https://artifacts.example/hello": artifact}
  let account = Account.make(~artifacts=served)
  let asked = []
  let restore = replaced(async (url, init) => {
    asked->Array.push(`${init.method} ${url->String.replace(Account.api, "")}`)
    await account(url, init)
  })
  let env = envOf(~db=asDatabase(sqlite), ())
  ignore(await deploying(env, "deploy", await deployInput(app(1))))
  ignore(await deploying(env, "stop", `{"runs": ${app(1)}}`))
  let broken = envOf(~db=failing(asDatabase(sqlite), "DELETE FROM deployments"), ())
  ignore(await deploying(broken, "delete", `{"runs": ${app(1)}}`))
  // Someone makes a Worker of that name by hand, carrying no tag of the driver's.
  ignore(await account(`${Account.api}/workers/scripts/00000001`, {method: "PUT"}))
  let again = await deploying(env, "delete", `{"runs": ${app(1)}}`)
  // A new version, so the deploy uploads rather than finding it kept.
  let hash = Envelope.Hex.encode(await sha256(artifact))
  let newer = Tar.archive([
    Tar.file("metadata.json", `{"main_module": "main.js", "compatibility_date": "2026-10-21"}`),
    Tar.file("main.js", `export default { fetch: () => new Response("hello again") }`),
  ])
  served->Dict.set("https://artifacts.example/newer", newer)
  let newerHash = Envelope.Hex.encode(await sha256(newer))
  let input =
    (await deployInput(app(1)))
    ->String.replaceAll(hash, newerHash)
    ->String.replace("https://artifacts.example/hello", "https://artifacts.example/newer")
  let redeployed = await deploying(env, "deploy", input)
  restore()
  let never = act => `00000001 carries no tag the driver gave 00000001, so it is never ${act}`
  deepEqual(
    [(reasonOf(again), messageOf(again)), (reasonOf(redeployed), messageOf(redeployed))],
    [
      ((500, Some(JSON.String("fault"))), Some(JSON.String(never("deleted")))),
      ((500, Some(JSON.String("fault"))), Some(JSON.String(never("overwritten")))),
    ],
  )
  deepEqual(asked->Array.filter(a => a == "DELETE /workers/scripts/00000001")->Array.length, 1)
})

test("a throw after the Worker is made keeps the claim, the deployment kept failed", async () => {
  let sqlite = installed()
  let asked = []
  let restore = await accountHolding(~asked, [])
  // The first write of the deployment, once the Worker is made and deployed, throws.
  let env = envOf(~db=failingOnce(asDatabase(sqlite), "INSERT INTO deployments"), ())
  let thrown = await deploying(env, "deploy", await deployInput(app(1)))
  deepEqual(reasonOf(thrown), (500, Some(JSON.String("fault"))))
  deepEqual(claims(sqlite, "00000001"), true, ~message=rows(sqlite))
  ok(rows(sqlite)->String.includes(`"worker":"00000001"`), ~message=rows(sqlite))
  ok(rows(sqlite)->String.includes(`"state":"failed"`), ~message=rows(sqlite))
  // The deployment is deleted, its Worker with it, and the claim given back.
  let deleted = await deploying(envOf(~db=asDatabase(sqlite), ()), "delete", `{"runs": ${app(1)}}`)
  restore()
  deepEqual(reasonOf(deleted), (200, None))
  deepEqual(claims(sqlite, "00000001"), false, ~message=rows(sqlite))
  ok(asked->Array.includes("DELETE /workers/scripts/00000001"))
})

test("the longest tag the driver writes holds within a tag's 100 bytes", async () => {
  let asked = []
  let tags = []
  let account: Function.api = {
    ...reaching(asked),
    upload: (_, upload) => {
      tags->Array.push(upload.tag)
      Promise.resolve(Ok("v1"))
    },
  }
  let exists = _ => Promise.resolve(Ok(false))
  // The longest own name and the longest install id, through the deploy and the prefixing.
  let own = Function.workerOf(App({id: 4294967295.}))
  let held =
    account->Installed.api(~held=[own], ~listed=[], ~exists, ~install="ffffffff", ~owner=own)
  let hash = await sha256(artifact)
  let through: Function.through = {
    api: held,
    store: {
      read: async _ => None,
      write: async (_, _) => (),
      forget: async _ => (),
    },
    fetch: async _ => Ok(artifact),
    listed: _ => None,
    released: async _ => (),
  }
  let deployed = await Function.deploy(
    through,
    {
      runs: App({id: 4294967295.}),
      version: hash,
      form: Modules,
      isolation: [Isolate],
      artifact: {address: "https://artifacts.example/hello", hash},
      footing: "https://footing.invalid",
      secrets: dict{},
      network: [Http, Tcp],
    },
  )
  ok(
    switch deployed {
    | Success(_) => true
    | Error(_) => false
    },
  )
  deepEqual(tags, [`ffffffff/ffffffff/version-${Envelope.Hex.encode(hash)}`])
  deepEqual(tags->Array.map(String.length), [90])
  // A tag past 100 bytes once the install id is before it is refused, never cut.
  let long = `${own}/${String.repeat("a", 83)}`
  let refused = await held.upload(own, {bundle: Function.stub, bindings: [], tag: long})
  deepEqual(outcome(refused), "fault")
  deepEqual(Array.length(tags), 1)
})
