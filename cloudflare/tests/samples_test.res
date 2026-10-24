/***
 * The management samples and the deployments lifecycle run through the Worker `driver` on node's
 * SQLite and the fake account of `account.res`, each `send` counted and passed over.
 */
open Node

let lifecycle = "../platform/tests/kinds/deployments/lifecycle.json"

let management = [
  "../platform/tests/kinds/management/lists.json",
  "../platform/tests/kinds/management/graces.json",
  "../platform/tests/kinds/management/ends.json",
]

let secret = Uint8Array.fromLength(32)->TypedArray.fillAll(3)
let token = `1.${Envelope.Base64url.encode(secret)}`

let member = (json, key) => json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key))
let textOf = (json, key) => json->member(key)->Option.flatMap(JSON.Decode.string)

/** The modules `echo-modules` names, each export answering the body it was sent. */
let echo = Tar.archive([
  Tar.file("metadata.json", `{"main_module": "main.js", "compatibility_date": "2026-10-21"}`),
  Tar.file(
    "main.js",
    `export default { fetch: async (request) => new Response(await request.text()) };`,
  ),
])

/** Where a fixture is served from, as an artifact's address a Worker fetches. */
let addressOf = name => `https://artifacts.example/${name}`

/** What an operation answered, as a step's `expect` writes it. */
let expected = (answer: JSON.t) =>
  switch answer->textOf("status") {
  | Some("success") => JSON.Object(dict{"output": answer->member("data")->Option.getOr(JSON.Null)})
  | _ =>
    JSON.Object(
      dict{
        "failure": answer->member("failure")->Option.getOr(JSON.Null),
        "reason": answer->member("reason")->Option.getOr(JSON.Null),
      },
    )
  }

/** Whether a value is as a sample expects it, `$any` and `$capture` standing for any value. */
let rec matches = (expect: JSON.t, actual: JSON.t) =>
  switch (expect->JSON.Decode.object, expect->JSON.Decode.array) {
  | (Some(e), _) if e->Dict.get("$any") != None || e->Dict.get("$capture") != None => true
  | (Some(e), _) =>
    switch actual->JSON.Decode.object {
    | Some(a) =>
      Dict.keysToArray(e)->Array.length == Dict.keysToArray(a)->Array.length &&
        e
        ->Dict.toArray
        ->Array.every(((key, value)) =>
          a->Dict.get(key)->Option.mapOr(false, v => matches(value, v))
        )
    | None => false
    }
  | (None, Some(e)) =>
    switch actual->JSON.Decode.array {
    | Some(a) =>
      Array.length(e) == Array.length(a) &&
        e->Array.everyWithIndex((value, i) => matches(value, a->Array.getUnsafe(i)))
    | None => false
    }
  | (None, None) => expect == actual
  }

/** One case's steps, each call sent to the Worker and answered as it expects; sends counted. */
let ran = async (case: JSON.t, ~interface) => {
  let hash = Envelope.Hex.encode(await sha256(echo))
  let env: Driver.env = {
    db: database(),
    apiToken: "t0ken",
    accountId: "023e105f4ecef8ad9ca31a8372d0c353",
    binding: Envelope.Hex.encode(Keys.Hash.plain(secret)),
  }
  let artifacts = Dict.fromArray([(addressOf("echo-modules"), echo)])
  let restore = replaced(Account.make(~artifacts))
  let steps = case->member("steps")->Option.flatMap(JSON.Decode.array)->Option.getOr([])
  let description = case->textOf("description")->Option.getOr("")
  let sent = ref(0)
  for at in 0 to Array.length(steps) - 1 {
    let step = steps->Array.getUnsafe(at)
    switch (step->member("send"), step->textOf("call")) {
    | (Some(_), _) => sent := sent.contents + 1
    | (None, None) => ok(false, ~message=`${description}, step ${Int.toString(at)} is no call`)
    | (None, Some(operation)) =>
      let input = step->member("input")->Option.flatMap(JSON.Decode.object)->Option.getOr(dict{})
      step
      ->textOf("fixture")
      ->Option.forEach(name => {
        input->Dict.set("version", JSON.String(hash))
        input->Dict.set("form", JSON.String("modules"))
        input->Dict.set(
          "artifact",
          JSON.Object(dict{"address": JSON.String(addressOf(name)), "hash": JSON.String(hash)}),
        )
      })
      let body = JSON.Object(
        dict{
          "interface": JSON.String(interface),
          "operation": JSON.String(operation),
          "input": JSON.Object(input),
        },
      )
      let response = await Driver.fetch(
        request(
          `https://driver.example.workers.dev/${interface}/${operation}`,
          {
            method: "POST",
            headers: dict{
              "authorization": `Bearer ${token}`,
              "content-type": "application/json",
              "accept": "application/json",
            },
            body: Web.utf8(JSON.stringify(body)),
          },
        ),
        env,
      )
      let text = Web.fromUtf8(await response->Web.responseBytes)->Option.getOr("null")
      let answer = JSON.parseOrThrow(text)
      let expect = step->member("expect")->Option.getOr(JSON.Null)
      let told = `${description}, step ${Int.toString(at)}: expected ${JSON.stringify(
          expect,
        )}, answered ${text}`
      ok(matches(expect, expected(answer)), ~message=told)
    }
  }
  restore()
  sent.contents
}

let casesOf = path =>
  fromRoot(path)->member("cases")->Option.flatMap(JSON.Decode.array)->Option.getOr([])

test("the deployments lifecycle holds through the Worker but what it sends", async () => {
  let cases = casesOf(lifecycle)
  let sent = ref(0)
  for c in 0 to Array.length(cases) - 1 {
    sent := sent.contents + (await ran(cases->Array.getUnsafe(c), ~interface="deployments"))
  }
  deepEqual((Array.length(cases), sent.contents), (3, 2))
})

test("the management samples hold through the Worker", async () => {
  let cases = management->Array.flatMap(casesOf)
  let sent = ref(0)
  for c in 0 to Array.length(cases) - 1 {
    sent := sent.contents + (await ran(cases->Array.getUnsafe(c), ~interface="management"))
  }
  deepEqual((Array.length(cases), sent.contents), (11, 0))
})
