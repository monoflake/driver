/***
 * The organization's own Workers adopted by a list, each standing for its deployment, warned of
 * when dropped, over node's SQLite through `calls.res`.
 */
open Node
open Calls

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
