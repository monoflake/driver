/***
 * `Cloudflare`'s calls, each answered by the example its page of Cloudflare's API reference gives,
 * `documented.res`, and each request held to what that page asks.
 */
open Node

type sent = {url: string, init: Web.init}

/** An account whose requests are answered in turn, each answer its status and its text. */
let account = (answers: array<(int, string)>) => {
  let sent = []
  let left = ref(answers)
  let send = async (url, init) => {
    sent->Array.push({url, init})
    switch left.contents {
    | [] => throw(JsExn.anyToExnInternal("no answer is left"))
    | _ =>
      let (status, text) = left.contents->Array.getUnsafe(0)
      left := left.contents->Array.slice(~start=1)
      response(text, {status: status})
    }
  }
  (Cloudflare.api(~send, ~accountId="023e105f4ecef8ad9ca31a8372d0c353", ~token="t0ken"), sent)
}

let accountPath = "https://api.cloudflare.com/client/v4/accounts/023e105f4ecef8ad9ca31a8372d0c353"

let requested = (sent: array<sent>) => sent->Array.map(s => (s.init.method, s.url))

let bodyJson = (s: sent) => s.init.body->Option.map(b => JSON.parseOrThrow(asText(b)))

let upload: Script.upload = {
  bundle: {
    modules: [
      {name: "main.js", kind: Es, bytes: Web.utf8("export default {}")},
      {name: "add.wasm", kind: Wasm, bytes: Uint8Array.fromArray([0, 97, 115, 109])},
    ],
    compatibilityDate: "2026-10-21",
    compatibilityFlags: ["nodejs_compat"],
  },
  bindings: [
    PlainText({name: "MONOFLAKE_FOOTING", text: "https://footing.invalid"}),
    SecretText({name: "KEY", text: "s3cret"}),
  ],
  tag: "0a1b2c3d/00000001/version-00",
}

let metadataOf = (s: sent) =>
  s.init.body
  ->Option.flatMap(b => asForm(b)->field("metadata")->Nullable.toOption)
  ->Option.map(text => JSON.parseOrThrow(text))

test(
  "a version is uploaded as a form of its metadata and modules, and its id answered",
  async () => {
    let (api, sent) = account([(200, Documented.versionUploaded)])
    deepEqual(await api.upload("app-1", upload), Ok("18f97339-c287-4872-9bdd-e2135c07ec12"))
    deepEqual(requested(sent), [("POST", `${accountPath}/workers/scripts/app-1/versions`)])
    let s = sent->Array.getUnsafe(0)
    deepEqual(s.init.headers, dict{"authorization": "Bearer t0ken"})
    deepEqual(
      metadataOf(s),
      Some(
        JSON.parseOrThrow(`{
        "main_module": "main.js",
        "bindings": [
          {"type": "plain_text", "name": "MONOFLAKE_FOOTING", "text": "https://footing.invalid"},
          {"type": "secret_text", "name": "KEY", "text": "s3cret"}
        ],
        "compatibility_date": "2026-10-21",
        "compatibility_flags": ["nodejs_compat"],
        "annotations": {"workers/tag": "0a1b2c3d/00000001/version-00"}
      }`),
      ),
    )
    let form = s.init.body->Option.getUnsafe->asForm
    let main = form->file("main.js")->Nullable.toOption->Option.getUnsafe
    deepEqual((main->fileName, main->fileType), ("main.js", "application/javascript+module"))
    deepEqual(await main->fileBytes, Web.utf8("export default {}"))
    let wasm = form->file("add.wasm")->Nullable.toOption->Option.getUnsafe
    deepEqual(wasm->fileType, "application/wasm")
  },
)

test(
  "a Worker absent is made with the stub, served on workers.dev, then given the version",
  async () => {
    let (api, sent) = account([
      (404, Documented.notFound),
      (200, Documented.scriptUploaded),
      (200, Documented.subdomainEnabled),
      (200, Documented.versionUploaded),
    ])
    deepEqual(await api.upload("app-1", upload), Ok("18f97339-c287-4872-9bdd-e2135c07ec12"))
    let script = `${accountPath}/workers/scripts/app-1`
    deepEqual(
      requested(sent),
      [
        ("POST", `${script}/versions`),
        ("PUT", script),
        ("POST", `${script}/subdomain`),
        ("POST", `${script}/versions`),
      ],
    )
    let made = sent->Array.getUnsafe(1)
    deepEqual(
      metadataOf(made),
      Some(
        JSON.parseOrThrow(`{"main_module": "stopped.js", "bindings": [],
        "compatibility_date": "2026-10-21", "compatibility_flags": [],
        "annotations": {"workers/tag": "0a1b2c3d/00000001/made"}}`),
      ),
    )
    deepEqual(bodyJson(sent->Array.getUnsafe(2)), Some(JSON.parseOrThrow(`{"enabled": true}`)))
    deepEqual(
      (sent->Array.getUnsafe(2)).init.headers->Dict.get("content-type"),
      Some("application/json"),
    )
  },
)

test("a JSON module is beyond what Cloudflare's upload takes, and nothing is sent", async () => {
  let (api, sent) = account([])
  let json = {...upload.bundle, modules: [{name: "main.json", kind: Json, bytes: Web.utf8("{}")}]}
  deepEqual(
    await api.upload("app-1", {...upload, bundle: json}),
    Error({reason: "beyond_host", message: "main.json: Cloudflare's upload takes no JSON module"}),
  )
  deepEqual(sent, [])
})

test("a version is deployed to every request", async () => {
  let (api, sent) = account([(200, Documented.deploymentCreated)])
  deepEqual(await api.deploy("app-1", "023e105f-2a42-4f8b-a1c1-73f6a2a30c0f"), Ok())
  deepEqual(requested(sent), [("POST", `${accountPath}/workers/scripts/app-1/deployments`)])
  deepEqual(
    bodyJson(sent->Array.getUnsafe(0)),
    Some(
      JSON.parseOrThrow(`{"strategy": "percentage",
        "versions": [{"percentage": 100, "version_id": "023e105f-2a42-4f8b-a1c1-73f6a2a30c0f"}]}`),
    ),
  )
})

test("the version running is the latest deployment's, its tag read from the version", async () => {
  let (api, sent) = account([(200, Documented.deploymentsListed), (200, Documented.versionGot)])
  deepEqual(
    await api.running("app-1"),
    Ok(Some({id: "023e105f-2a42-4f8b-a1c1-73f6a2a30c0f", tag: Some("v1.0.1")})),
  )
  deepEqual(
    requested(sent),
    [
      ("GET", `${accountPath}/workers/scripts/app-1/deployments`),
      ("GET", `${accountPath}/workers/workers/app-1/versions/023e105f-2a42-4f8b-a1c1-73f6a2a30c0f`),
    ],
  )
  let (absent, _) = account([(404, Documented.notFound)])
  deepEqual(await absent.running("app-1"), Ok(None))
})

test("a Worker is deleted, and one absent is deleted already", async () => {
  let (api, sent) = account([(200, Documented.scriptDeleted), (404, Documented.notFound)])
  deepEqual(await api.delete("component-pages"), Ok())
  deepEqual(await api.delete("component-pages"), Ok())
  deepEqual(
    requested(sent),
    [
      ("DELETE", `${accountPath}/workers/scripts/component-pages`),
      ("DELETE", `${accountPath}/workers/scripts/component-pages`),
    ],
  )
})

test("a Worker's address is its name on the account's workers.dev subdomain", async () => {
  let (api, sent) = account([(200, Documented.subdomainGot)])
  deepEqual(await api.address("app-1"), Ok("app-1.my-subdomain.workers.dev"))
  deepEqual(requested(sent), [("GET", `${accountPath}/workers/subdomain`)])
})

test(
  "a failure is a fault saying what Cloudflare answered, and one unreached says so",
  async () => {
    let refusal = `{"errors": [{"code": 10000, "message": "Authentication error"}], "messages": [],
    "result": null, "success": false}`
    let (api, _) = account([(403, refusal)])
    deepEqual(
      await api.address("app-1"),
      Error({
        reason: "fault",
        message: "Cloudflare's API answered 403, 10000 Authentication error",
      }),
    )
    let (unreached, _) = account([])
    deepEqual(
      await unreached.deploy("app-1", "1"),
      Error({reason: "fault", message: "Cloudflare's API was not reached"}),
    )
  },
)
