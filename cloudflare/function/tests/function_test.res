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
  address: "00000001.example",
  runtime: Workers,
  isolation: [Isolate],
})

let of_: Contracts.DeploymentOf.t = {runs: runs}

test(
  "a deployment's Worker is named for what it runs, its version's tag for its hash",
  async () => {
    let named = runs => Function.workerOf(runs)
    deepEqual(named(App({id: 12.})), "0000000c")
    deepEqual(named(Component({component: "pages", id: 3735928559.})), "deadbeef")
    deepEqual(named(App({id: 4294967295.})), "ffffffff")
    // An id of no resource's form is written as it came, which no guard holds.
    deepEqual(
      [-1., 1.5, 4294967296.]->Array.map(id => named(App({id: id}))),
      ["-1", "1.5", "4294967296"],
    )
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
  deepEqual(
    account.asked,
    ["upload 00000001 00000001/" ++ Function.tagOf(input.version), "deploy 00000001 v1"],
  )
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
  deepEqual(said, [`00000001 is given tcp ${beyond}`, `00000001 is given http and tcp ${beyond}`])
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
    kept->Map.get("00000001"),
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
  ok(kept->Map.has("00000001"))
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
    Some((["stopped.js"], "00000001/stopped")),
  )
  deepEqual(account.runs->Map.get("00000001"), Some("v2"))
  deepEqual(kept->Map.get("00000001")->Option.flatMap(k => k.replaced), Some("v1"))
  // Stopped again, or deployed again the same while stopped, nothing changes.
  deepEqual(stateOf(await Function.stop(through, of_)), Some(Stopped))
  deepEqual(stateOf(await Function.deploy(through, input)), Some(Stopped))
  deepEqual(account.versions->Map.size, 2)
  deepEqual(stateOf(await Function.resume(through, of_)), Some(running))
  deepEqual(account.runs->Map.get("00000001"), Some("v1"))
  deepEqual(stateOf(await Function.resume(through, of_)), Some(running))
  deepEqual(
    account.asked->Array.filter(a => a->String.startsWith("deploy")),
    ["deploy 00000001 v1", "deploy 00000001 v2", "deploy 00000001 v1"],
  )
})

test("a deployment is deleted only once stopped, and is then not found", async () => {
  let (through, account, kept, _) = setUp()
  ignore(await Function.deploy(through, await deployOf()))
  deepEqual(reasonOf(await Function.delete(through, of_)), Some((Rejected, "still_running")))
  ignore(await Function.stop(through, of_))
  deepEqual(await Function.delete(through, of_), Success({}))
  deepEqual((kept->Map.size, account.runs->Map.has("00000001")), (0, false))
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

let failing: Function.refused = {reason: "fault", message: "Cloudflare's API answered 500"}

test("a Worker made for a deployment that failed is told failed, and may be deleted", async () => {
  let (through, account, _, _) = setUp()
  account.refusing := Some((Deploy, failing))
  let input = await deployOf()
  deepEqual(reasonOf(await Function.deploy(through, input)), Some((Unknown, "fault")))
  deepEqual(stateOf(await Function.describe(through, of_)), Some(Failed({reason: "fault"})))
  deepEqual(stateOf(await Function.stop(through, of_)), Some(Failed({reason: "fault"})))
  deepEqual(await Function.delete(through, of_), Success({}))
})

test(
  "a first deploy failing where the Worker may be made is told failed, as one made is",
  async () => {
    let (through, account, _, _) = setUp()
    account.refusing := Some((Deploy, failing))
    account.seeing := Some(1)
    deepEqual(reasonOf(await Function.deploy(through, await deployOf())), Some((Unknown, "fault")))
    account.seeing := None
    deepEqual(stateOf(await Function.describe(through, of_)), Some(Failed({reason: "fault"})))
  },
)

test("a first deploy refused before any Worker is made keeps nothing", async () => {
  let (through, account, kept, _) = setUp()
  account.refusing := Some((Upload, failing))
  deepEqual(reasonOf(await Function.deploy(through, await deployOf())), Some((Unknown, "fault")))
  deepEqual(kept->Map.size, 0)
  deepEqual(reasonOf(await Function.describe(through, of_)), Some((Rejected, "not_found")))
})

test("a secret that is no UTF-8 text is beyond the host, named but never shown", async () => {
  let (through, account, kept, fetched) = setUp()
  let input = await deployOf()
  let secrets = dict{"KEY": Web.utf8("s3cret"), "RAW": Uint8Array.fromArray([0xff, 0xfe])}
  switch await Function.deploy(through, {...input, secrets}) {
  | Error(e) =>
    deepEqual(
      (e.reason, e.message),
      ("beyond_host", "the secret RAW is no UTF-8 text, as a Worker's secret is"),
    )
  | Success(_) => ok(false, ~message="a secret of no text was deployed")
  }
  deepEqual((fetched, account.asked, kept->Map.size), ([], [], 0))
})

test("a stop finding another version running, or none, keeps nothing and is a fault", async () => {
  let (through, account, kept, _) = setUp()
  let input = await deployOf()
  ignore(await Function.deploy(through, input))
  let before = kept->Map.get("00000001")
  let notKept = Some((
    Contracts.Failure.Unknown,
    "fault",
    "the version running on 00000001 is not the one kept, so nothing is stopped",
  ))
  let refusal = answer =>
    switch answer {
    | Contracts.Answer.Error(e) => Some((e.failure, e.reason, e.message))
    | Success(_) => None
    }
  account.versions->Map.set("v9", {bundle: Function.stub, bindings: [], tag: "version-other"})
  account.runs->Map.set("00000001", "v9")
  deepEqual(refusal(await Function.stop(through, of_)), notKept)
  account.runs->Map.delete("00000001")->ignore
  deepEqual(refusal(await Function.stop(through, of_)), notKept)
  deepEqual(kept->Map.get("00000001"), before)
  deepEqual(account.asked->Array.filter(a => a->String.includes("stopped")), [])
})

test("the stub answers every request 503 stopped, in the form the call asks", async () => {
  deepEqual(Function.stub.modules->Array.map(m => (m.name, m.kind)), [("stopped.js", Function.Es)])
  let source = Function.stub.modules->Array.getUnsafe(0)
  let worker = (await imported(Web.fromUtf8(source.bytes)->Option.getOrThrow)).default
  let asked = async headers => {
    let answer = worker.fetch(request("https://00000001.example/echo", {headers: headers}))
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
  // Its CBOR is read by the codec in the driver's tests, this block taking no codec.
  let media = async headers => {
    let (status, media, _) = await asked(headers)
    (status, media)
  }
  deepEqual(await media(dict{}), (503, Some("application/cbor")))
  deepEqual(
    await media(dict{"accept": "application/cbor, application/json"}),
    (503, Some("application/cbor")),
  )
})

/** The Worker an organization listed for app 1, a made-up name of its own. */
let listedFor = (runs: Contracts.DeploymentRuns.t) =>
  switch runs {
  | App({id: 1.}) => Some("shop-front")
  | App(_) | Component(_) => None
  }

test(
  "a listed Worker stands for its deployment, deployed, stopped and resumed in place",
  async () => {
    let (through, account, kept, _) = setUp(~listed=listedFor)
    let input = await deployOf()
    let listedRunning = Contracts.DeploymentState.Running({
      address: "shop-front.example",
      runtime: Workers,
      isolation: [Isolate],
    })
    deepEqual(stateOf(await Function.deploy(through, input)), Some(listedRunning))
    deepEqual(stateOf(await Function.stop(through, of_)), Some(Stopped))
    deepEqual(stateOf(await Function.resume(through, of_)), Some(listedRunning))
    deepEqual(stateOf(await Function.describe(through, of_)), Some(listedRunning))
    deepEqual(
      account.asked->Array.filter(a => a->String.startsWith("deploy")),
      ["deploy shop-front v1", "deploy shop-front v2", "deploy shop-front v1"],
    )
    deepEqual((kept->Map.has("shop-front"), kept->Map.has("00000001")), (true, false))
  },
)

test(
  "a listed Worker's deployment deleted lets the Worker go, released and never deleted",
  async () => {
    let released = []
    let (through, account, kept, _) = setUp(~listed=listedFor, ~released)
    ignore(await Function.deploy(through, await deployOf()))
    ignore(await Function.stop(through, of_))
    deepEqual(await Function.delete(through, of_), Success({}))
    deepEqual(released, ["shop-front"])
    deepEqual(account.asked->Array.filter(a => a->String.startsWith("delete")), [])
    deepEqual((kept->Map.size, account.runs->Map.has("shop-front")), (0, true))
  },
)

test(
  "a listed Worker the driver never took over, deleted, is left as it is and not released",
  async () => {
    let released = []
    let (through, account, kept, _) = setUp(~listed=listedFor, ~released)
    deepEqual(await Function.delete(through, of_), Success({}))
    deepEqual((released, account.asked, kept->Map.size), ([], [], 0))
  },
)

test("each case handed is bound under its reserved name, bytes as hex text", async () => {
  let (through, account, _, _) = setUp()
  let bytes = n => Uint8Array.fromLength(2)->TypedArray.fillAll(n)
  let input = {
    ...await deployOf(),
    handed: [
      Root({value: bytes(1)}),
      Key({value: bytes(2)}),
      Certificate({value: bytes(3)}),
      SigningKey({value: bytes(4)}),
    ],
  }
  deepEqual(stateOf(await Function.deploy(through, input)), Some(running))
  let bindings =
    account.versions
    ->Map.values
    ->Iterator.toArray
    ->Array.flatMap(upload => upload.bindings)
    ->Array.filter(bound =>
      switch bound {
      | PlainText({name}) | SecretText({name}) => name != "MONOFLAKE_FOOTING" && name != "KEY"
      }
    )
  deepEqual(
    bindings,
    [
      PlainText({name: "MONOFLAKE_ROOT", text: "0101"}),
      SecretText({name: "MONOFLAKE_KEY", text: "0202"}),
      PlainText({name: "MONOFLAKE_CERTIFICATE", text: "0303"}),
      SecretText({name: "MONOFLAKE_SIGNING_KEY", text: "0404"}),
    ],
  )
})

test("a case handed twice is invalid, and nothing is fetched or asked", async () => {
  let (through, account, _, fetched) = setUp()
  let root = Contracts.DeploymentHanded.Root({value: Uint8Array.fromLength(1)})
  let input = {...await deployOf(), handed: [root, Key({value: Uint8Array.fromLength(1)}), root]}
  let answer = await Function.deploy(through, input)
  deepEqual(
    switch answer {
    | Error(e) => Some((e.reason, e.message))
    | Success(_) => None
    },
    Some(("invalid", "root is handed twice")),
  )
  deepEqual((fetched, account.asked), ([], []))
})

test(
  "a deployment reaching another is beyond the host, an empty list changing nothing",
  async () => {
    let (through, account, _, fetched) = setUp()
    let input = await deployOf()
    let reaching = {...input, reaching: [App({id: 2.})]}
    deepEqual(
      reasonOf(await Function.deploy(through, reaching)),
      Some((Contracts.Failure.Rejected, "beyond_host")),
    )
    deepEqual((fetched, account.asked), ([], []))
    deepEqual(stateOf(await Function.deploy(through, {...input, reaching: []})), Some(running))
  },
)

test(
  "a deployment's own secret under the platform's prefix is malformed, nothing fetched",
  async () => {
    let (through, account, _, fetched) = setUp()
    let input = await deployOf()
    let reasons = []
    let names = ["MONOFLAKE_FOOTING", "MONOFLAKE_KEY", "MONOFLAKE_"]
    for at in 0 to Array.length(names) - 1 {
      let secrets = dict{}
      secrets->Dict.set(names->Array.getUnsafe(at), Web.utf8("x"))
      reasons->Array.push(reasonOf(await Function.deploy(through, {...input, secrets})))
    }
    deepEqual(
      reasons->Array.map(r => r->Option.map(((_, reason)) => reason)),
      [Some("malformed"), Some("malformed"), Some("malformed")],
    )
    deepEqual((fetched, account.asked), ([], []))
    let secrets = dict{"MONOFLAKEX": Web.utf8("x"), "monoflake_key": Web.utf8("x")}
    deepEqual(reasonOf(await Function.deploy(through, {...input, secrets})), None)
  },
)
