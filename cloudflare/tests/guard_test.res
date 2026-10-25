/***
 * The guard on the account's Workers, acting on a name the records hold or the list names and on a
 * Worker carrying its deployment's tag alone, through `calls.res`.
 */
open Node
open Calls
module Function = DriverCloudflareFunction.Function

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

test("a name the driver did not form is a fault, never acted on", async () => {
  deepEqual(Installed.formed("0000000c"), Ok("0000000c"))
  ["4294967296", "-1", "1.5", "0000000C", "app-1"]->Array.forEach(name =>
    deepEqual(Installed.formed(name)->Result.mapError(r => r.reason), Error("fault"), ~message=name)
  )
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
