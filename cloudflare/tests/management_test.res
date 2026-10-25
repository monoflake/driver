/***
 * The Worker `driver`'s management interface and its calls, the token, the encodings, what install
 * sets and the rows of its D1, over node's SQLite through `calls.res`.
 */
open Node
open Calls
module Contracts = Envelope.Contracts

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
