/***
 * `Function`'s operations on the fake account and the store in memory of `fake.res`.
 */
open Node
open Fake
module Contracts = Envelope.Contracts

let runs = Contracts.DeploymentRuns.App({id: 1.})

let deployOf = async (~address="hello", ~bytes=artifact, ()): Contracts.DeploymentDeploy.t => {
  runs,
  version: await Web.sha256(bytes),
  form: Modules,
  isolation: [Isolate],
  artifact: {address, hash: await Web.sha256(bytes)},
  footing: "https://footing.invalid",
  secrets: dict{"KEY": Web.utf8("s3cret")},
  network: [Http, Tcp],
}

let reasonOf = (answer: Contracts.Answer.t<_>) =>
  switch answer {
  | Success(_) => None
  | Error(e) => Some((e.failure, e.reason))
  }

let stateOf = (answer: Contracts.Answer.t<Contracts.DeploymentDescribed.t>) =>
  switch answer {
  | Success(d) => Some(d.state)
  | Error(_) => None
  }

let running = Contracts.DeploymentState.Running({
  address: "app-1.my-subdomain.workers.dev",
  runtime: Workers,
  isolation: [Isolate],
})

let of_: Contracts.DeploymentOf.t = {runs: runs}

test(
  "a deployment's Worker is named for what it runs, its version's tag for its hash",
  async () => {
    deepEqual(Function.workerOf(App({id: 12.})), "app-12")
    deepEqual(Function.workerOf(Component({component: "pages"})), "component-pages")
    let tag = Function.tagOf(Uint8Array.fromLength(32))
    deepEqual(tag, "version-" ++ String.repeat("00", 32))
    deepEqual(String.length(tag), 72)
  },
)

test("a deploy a Worker cannot give is beyond the host, and nothing is fetched", async () => {
  let (through, account, _, fetched) = setUp()
  let input = await deployOf()
  let beyond = async input => reasonOf(await Function.deploy(through, input))
  let refused = Some((Contracts.Failure.Rejected, "beyond_host"))
  deepEqual(await beyond({...input, form: Component}), refused)
  deepEqual(await beyond({...input, runtime: Workerd}), refused)
  deepEqual(await beyond({...input, isolation: [Isolate, Vm]}), refused)
  deepEqual(await beyond({...input, network: [Http, Udp]}), refused)
  deepEqual(await beyond({...input, network: [Icmp]}), refused)
  deepEqual(await beyond({...input, runtime: Workers, network: [Tcp, Http]}), None)
  deepEqual(fetched, ["hello"])
  deepEqual(account.asked, ["upload app-1 " ++ Function.tagOf(input.version), "deploy app-1 v1"])
})

test("a network a Worker gives more than is taken, each way out beyond it warned of", async () => {
  let (through, _, _, _) = setUp()
  let input = await deployOf()
  let (said, restore) = warned()
  let states = [
    stateOf(await Function.deploy(through, {...input, network: [Http]})),
    stateOf(await Function.deploy(through, {...input, network: []})),
    stateOf(await Function.deploy(through, {...input, network: [Tcp, Http]})),
  ]
  restore()
  deepEqual(states, [Some(running), Some(running), Some(running)])
  let beyond = "beyond the network it asks, an ordinary account holding no Worker back, RFC nrs5v"
  deepEqual(said, [`app-1 is given tcp ${beyond}`, `app-1 is given http and tcp ${beyond}`])
})

test("an artifact too large, not its hash, unfetchable or no bundle is refused", async () => {
  let large = Uint8Array.fromLength(67_108_865)
  let junk = Web.utf8("not a tar archive at all")
  let (through, account, kept, _) = setUp(~addresses=dict{"large": large, "junk": junk})
  let deployed = async input => reasonOf(await Function.deploy(through, input))
  deepEqual(
    await deployed(await deployOf(~address="large", ~bytes=large, ())),
    Some((Rejected, "too_large")),
  )
  let mismatched = {
    ...await deployOf(~address="junk", ~bytes=junk, ()),
    version: Uint8Array.fromLength(32),
  }
  deepEqual(
    await deployed({
      ...mismatched,
      artifact: {...mismatched.artifact, hash: Uint8Array.fromLength(32)},
    }),
    Some((Rejected, "hash_mismatch")),
  )
  deepEqual(await deployed(await deployOf(~address="gone", ())), Some((Unavailable, "unfetchable")))
  deepEqual(
    await deployed(await deployOf(~address="junk", ~bytes=junk, ())),
    Some((Rejected, "malformed")),
  )
  deepEqual((account.asked, kept->Map.size), ([], 0))
})

test("a deployment made runs at its Worker's address, its footing and secrets bound", async () => {
  let (through, account, kept, _) = setUp()
  let input = await deployOf()
  let answer = await Function.deploy(through, input)
  deepEqual(answer, Success({runs, version: input.version, state: running}))
  let uploaded = account.versions->Map.get("v1")->Option.getUnsafe
  deepEqual(
    uploaded.bindings,
    [
      PlainText({name: "MONOFLAKE_FOOTING", text: "https://footing.invalid"}),
      SecretText({name: "KEY", text: "s3cret"}),
    ],
  )
  deepEqual(uploaded.bundle.modules->Array.map(m => m.name), ["main.js"])
  deepEqual(
    kept->Map.get("app-1"),
    Some({Function.version: Envelope.Hex.encode(input.version), state: #running}),
  )
  deepEqual(await Function.describe(through, of_), answer)
})

test("deploying the same again is the one deployment, and nothing is fetched", async () => {
  let (through, account, kept, fetched) = setUp()
  let input = await deployOf()
  ignore(await Function.deploy(through, input))
  kept->Map.clear
  deepEqual(stateOf(await Function.deploy(through, input)), Some(running))
  deepEqual((fetched, account.versions->Map.size), (["hello"], 1))
  ok(kept->Map.has("app-1"))
})

test("a deployment stopped runs the stub, and resumed runs the version it replaced", async () => {
  let (through, account, kept, _) = setUp()
  let input = await deployOf()
  ignore(await Function.deploy(through, input))
  deepEqual(stateOf(await Function.stop(through, of_)), Some(Stopped))
  deepEqual(
    account.versions
    ->Map.get("v2")
    ->Option.map(u => (u.bundle.modules->Array.map(m => m.name), u.tag)),
    Some((["stopped.js"], "stopped")),
  )
  deepEqual(account.runs->Map.get("app-1"), Some("v2"))
  deepEqual(kept->Map.get("app-1")->Option.flatMap(k => k.replaced), Some("v1"))
  // Stopped again, or deployed again the same while stopped, nothing changes.
  deepEqual(stateOf(await Function.stop(through, of_)), Some(Stopped))
  deepEqual(stateOf(await Function.deploy(through, input)), Some(Stopped))
  deepEqual(account.versions->Map.size, 2)
  deepEqual(stateOf(await Function.resume(through, of_)), Some(running))
  deepEqual(account.runs->Map.get("app-1"), Some("v1"))
  deepEqual(stateOf(await Function.resume(through, of_)), Some(running))
  deepEqual(
    account.asked->Array.filter(a => a->String.startsWith("deploy")),
    ["deploy app-1 v1", "deploy app-1 v2", "deploy app-1 v1"],
  )
})

test("a deployment is deleted only once stopped, and is then not found", async () => {
  let (through, account, kept, _) = setUp()
  ignore(await Function.deploy(through, await deployOf()))
  deepEqual(reasonOf(await Function.delete(through, of_)), Some((Rejected, "still_running")))
  ignore(await Function.stop(through, of_))
  deepEqual(await Function.delete(through, of_), Success({}))
  deepEqual((kept->Map.size, account.runs->Map.has("app-1")), (0, false))
  deepEqual(reasonOf(await Function.describe(through, of_)), Some((Rejected, "not_found")))
})

test("what was never deployed is not found, and deleting it succeeds", async () => {
  let (through, _, _, _) = setUp()
  let never: Contracts.DeploymentOf.t = {runs: App({id: 9.})}
  let notFound = Some((Contracts.Failure.Rejected, "not_found"))
  deepEqual(reasonOf(await Function.stop(through, never)), notFound)
  deepEqual(reasonOf(await Function.resume(through, never)), notFound)
  deepEqual(reasonOf(await Function.describe(through, never)), notFound)
  deepEqual(await Function.delete(through, never), Success({}))
})

test("a Worker made for a deployment that failed is told failed, and may be deleted", async () => {
  let (through, account, _, _) = setUp()
  account.refusing := Some({reason: "fault", message: "Cloudflare's API answered 500"})
  let input = await deployOf()
  deepEqual(reasonOf(await Function.deploy(through, input)), Some((Unknown, "fault")))
  deepEqual(stateOf(await Function.describe(through, of_)), Some(Failed({reason: "fault"})))
  deepEqual(stateOf(await Function.stop(through, of_)), Some(Failed({reason: "fault"})))
  deepEqual(await Function.delete(through, of_), Success({}))
})

test("the stub answers every request 503 stopped, in the form the call asks", async () => {
  deepEqual(Function.stub.modules->Array.map(m => (m.name, m.kind)), [("stopped.js", Function.Es)])
  let source = Function.stub.modules->Array.getUnsafe(0)
  let worker = (await imported(Web.fromUtf8(source.bytes)->Option.getOrThrow)).default
  let asked = async headers => {
    let answer = worker.fetch(
      request("https://app-1.my-subdomain.workers.dev/echo", {headers: headers}),
    )
    let bytes = Uint8Array.fromBuffer(await answer->answerBytes)
    (answer->answerStatus, answer->answerHeaders->header("content-type")->Nullable.toOption, bytes)
  }
  let error = Contracts.Answer.Error({
    failure: Unavailable,
    reason: "stopped",
    message: "What was called is stopped",
  })
  let json = Contracts.Answer.toJson(error, (_: unit) => JSON.Null)->JSON.stringify->Web.utf8
  deepEqual(await asked(dict{"accept": "application/json"}), (503, Some("application/json"), json))
  deepEqual(
    await asked(dict{"content-type": "application/json; charset=utf-8"}),
    (503, Some("application/json"), json),
  )
  // The error's CBOR, a map of its case 2, failure 2, reason and message, RFC 8949.
  let cbor = Uint8Array.fromArray(
    Array.concat(
      [0xa4, 0x00, 0x02, 0x01, 0x02, 0x02, 0x67],
      Array.concat(
        "stopped"->String.split("")->Array.map(c => c->String.charCodeAt(0)->Option.getOr(0)),
        Array.concat(
          [0x03, 0x78, 0x1a],
          "What was called is stopped"
          ->String.split("")
          ->Array.map(c => c->String.charCodeAt(0)->Option.getOr(0)),
        ),
      ),
    ),
  )
  deepEqual(await asked(dict{}), (503, Some("application/cbor"), cbor))
  deepEqual(
    await asked(dict{"accept": "application/cbor, application/json"}),
    (503, Some("application/cbor"), cbor),
  )
})
