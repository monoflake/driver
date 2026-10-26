/***
 * The Worker `driver`'s deployments, made Workers of the account from their artifacts, named,
 * claimed in D1 and given back, over node's SQLite through `calls.res`.
 */
open Node
open Calls
module Contracts = Envelope.Contracts

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
  "an existence read Cloudflare's API never answered names the throw, secrets replaced",
  async () => {
    let env = envOf()
    let id = "023e105f4ecef8ad9ca31a8372d0c353"
    let said = `Illegal invocation at https://api.cloudflare.com for ${id} with Bearer t0ken`
    let restore = replaced(async (url, init) =>
      url->String.endsWith("/workers/scripts/00000001") && init.method == "GET"
        ? JsError.TypeError.make(said)->JsError.throw
        : answerText(Documented.notFound, {status: 404})
    )
    let answered = await deploying(env, "deploy", await deployInput(app(1)))
    restore()
    let detail = "TypeError: Illegal invocation at <address> for <account> with Bearer <token>"
    deepEqual(
      (reasonOf(answered), messageOf(answered)),
      (
        (500, Some(JSON.String("fault"))),
        Some(JSON.String(`Cloudflare's API was not reached, ${detail}`)),
      ),
    )
  },
)

test("an artifact's address never reached names the throw, its address replaced", async () => {
  let (answered, _) = await deployedFrom("https://artifacts.example/hello", ~served=url =>
    url->String.startsWith("https://artifacts.example")
      ? JsError.TypeError.make("fetch failed for https://artifacts.example/hello")->JsError.throw
      : None
  )
  deepEqual(
    (reasonOf(answered), messageOf(answered)),
    (
      (503, Some(JSON.String("unfetchable"))),
      Some(
        JSON.String(
          "the artifact's address was not reached, TypeError: fetch failed for <address>",
        ),
      ),
    ),
  )
})

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
