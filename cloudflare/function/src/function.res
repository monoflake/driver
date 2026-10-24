/***
 * Each deployment a Worker of the bound account, its version kept as a tag so a deploy sent again
 * does nothing, stopped by the stub and resumed by the version it replaced, RFC nrs5v.
 */
module Contracts = Envelope.Contracts

type refused = Script.refused = {reason: string, message: string}

type kind = Script.kind = Es | CommonJs | Wasm | Text | Data | Json

type module_ = Script.module_ = {name: string, kind: kind, bytes: Uint8Array.t}

type bundle = Script.bundle = {
  modules: array<module_>,
  compatibilityDate: string,
  compatibilityFlags: array<string>,
}

let unpack = Archive.unpack

let stub = Stopped.bundle

type bound = Script.bound =
  | PlainText({name: string, text: string})
  | SecretText({name: string, text: string})

type upload = Script.upload = {bundle: bundle, bindings: array<bound>, tag: string}

type running = Script.running = {id: string, tag: option<string>}

type api = Script.api = {
  upload: (string, upload) => promise<result<string, refused>>,
  deploy: (string, string) => promise<result<unit, refused>>,
  running: string => promise<result<option<running>, refused>>,
  delete: string => promise<result<unit, refused>>,
  subdomain: unit => promise<result<string, refused>>,
}

let ofAccount = (~accountId, ~token) => Cloudflare.api(~send=Web.fetch, ~accountId, ~token)

type kept = {
  version: string,
  state: [#running | #stopped | #failed],
  reason?: string,
  replaced?: string,
}

type store = {
  read: string => promise<option<kept>>,
  write: (string, kept) => promise<unit>,
  forget: string => promise<unit>,
}

type through = {api: api, store: store, fetch: string => promise<result<Uint8Array.t, refused>>}

/** The most an artifact may be, a Worker's 64 MiB on every plan, RFC nrs5v. */
let largest = 67_108_864

/** The most a version's tag holds, Cloudflare's `workers/tag` of 100 bytes. */
let tagged = 100

/** What names the footing's address to a Worker, as driver(machine) names it to a worker. */
let footing = "MONOFLAKE_FOOTING"

/** The tag the stub is uploaded with, which no version's tag is. */
let stopping = "stopped"

let workerOf = (runs: Contracts.DeploymentRuns.t) =>
  switch runs {
  | App({id}) => `app-${Float.toString(id)}`
  | Component({component}) => `component-${component}`
  }

let tagOf = hash => `version-${Envelope.Hex.encode(hash)}`->String.slice(~start=0, ~end=tagged)

/** An error by its reason, its failure and message the operation's or every operation's. */
let answer = (operation: Contracts.operation, refused: refused) => {
  let known =
    Array.concat(operation.reasons, Contracts.reasons)->Array.find(r => r.name == refused.reason)
  Contracts.Answer.Error({
    failure: known->Option.mapOr(Contracts.Failure.Unknown, r => r.failure),
    reason: refused.reason,
    message: refused.message != ""
      ? refused.message
      : Contracts.messages->Dict.get(refused.reason)->Option.getOr(refused.reason),
  })
}

let beyond = message => Error({reason: "beyond_host", message})

/** The ways out a Worker has, fetch and connect, neither held back on an ordinary account. */
let ways: array<Contracts.DeploymentNetwork.t> = [Http, Tcp]

let wayName = (way: Contracts.DeploymentNetwork.t) =>
  switch way {
  | Http => "http"
  | Tcp => "tcp"
  | Udp => "udp"
  | Icmp => "icmp"
  }

/**
 * Each way out a Worker is given beyond what a deployment's network asks, or why it is refused,
 * the network rule of RFC nrs5v.
 */
let outbound = (network: array<Contracts.DeploymentNetwork.t>) =>
  switch network->Array.find(way => !(ways->Array.includes(way))) {
  | Some(way) => beyond(`a Worker reaches out by http and tcp alone, never ${wayName(way)}`)
  | None => Ok(ways->Array.filter(way => !(network->Array.includes(way))))
  }

/** What a deploy asks that a Worker cannot give, refused before anything is fetched. */
let checked = (input: Contracts.DeploymentDeploy.t) =>
  switch (input.form, input.runtime) {
  | (Component | Image, _) => beyond("a function here runs modules alone, as a Worker")
  | (Modules, Some(Workerd | Wasmtime | Runc | Crun | Youki)) =>
    beyond("modules run on Workers alone here")
  | (Modules, None | Some(Workers)) =>
    if !(input.isolation->Array.every(i => i == Contracts.DeploymentIsolation.Isolate)) {
      beyond("a Worker stands on an isolate's isolation alone")
    } else {
      outbound(input.network)
    }
  }

/** A deployment described as it is kept, its address the account's workers.dev subdomain. */
let described = async (through, runs, kept: kept): result<Contracts.DeploymentDescribed.t, _> => {
  let version = Envelope.Hex.decode(kept.version)->Option.getOr(Uint8Array.fromLength(32))
  switch kept.state {
  | #stopped => Ok({runs, version, state: Stopped})
  | #failed => Ok({runs, version, state: Failed({reason: kept.reason->Option.getOr("fault")})})
  | #running =>
    switch await through.api.subdomain() {
    | Ok(subdomain) =>
      Ok({
        runs,
        version,
        state: Running({
          address: `${workerOf(runs)}.${subdomain}.workers.dev`,
          runtime: Workers,
          isolation: [Isolate],
        }),
      })
    | Error(_) as refused => refused
    }
  }
}

let answered = (operation, result) =>
  switch result {
  | Ok(output) => Contracts.Answer.Success(output)
  | Error(refused) => answer(operation, refused)
  }

/** The artifact fetched and held to its bound and its hash, SHA-256 as the driver checks it. */
let fetched = async (through, artifact: Contracts.DeploymentArtifact.t) =>
  switch await through.fetch(artifact.address) {
  | Error(_) as refused => refused
  | Ok(bytes) if TypedArray.length(bytes) > largest =>
    Error({reason: "too_large", message: `an artifact is at most ${Int.toString(largest)} bytes`})
  | Ok(bytes) =>
    let hash = await Web.sha256(bytes)
    Envelope.Hex.encode(hash) == Envelope.Hex.encode(artifact.hash)
      ? Ok(bytes)
      : Error({reason: "hash_mismatch", message: ""})
  }

/** The footing's address and each secret, its bytes read as UTF-8 text. */
let bindingsOf = (input: Contracts.DeploymentDeploy.t) =>
  Array.concat(
    [PlainText({name: footing, text: input.footing})],
    input.secrets
    ->Dict.toArray
    ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
    ->Array.map(((name, bytes)) => SecretText({
      name,
      text: Web.fromUtf8(bytes)->Option.getOr(""),
    })),
  )

let deploying = async (through, input: Contracts.DeploymentDeploy.t) => {
  let worker = workerOf(input.runs)
  let version = Envelope.Hex.encode(input.version)
  let tag = tagOf(input.version)
  let kept = await through.store.read(worker)
  switch kept {
  // Deployed again the same, it is the one deployment, and nothing is fetched for it.
  | Some({version: before, state: #stopped} as kept) if before == version =>
    await described(through, input.runs, kept)
  | Some(_) | None =>
    switch await through.api.running(worker) {
    | Error(_) as refused => refused
    | Ok(Some({tag: Some(running)})) if running == tag =>
      let kept = {version, state: #running}
      await through.store.write(worker, kept)
      await described(through, input.runs, kept)
    | Ok(_) =>
      switch await fetched(through, input.artifact) {
      | Error(_) as refused => refused
      | Ok(bytes) =>
        switch unpack(bytes) {
        | Error(_) as refused => refused
        | Ok(bundle) =>
          let made = switch await through.api.upload(
            worker,
            {bundle, bindings: bindingsOf(input), tag},
          ) {
          | Ok(id) => await through.api.deploy(worker, id)
          | Error(_) as refused => refused
          }
          switch made {
          | Ok() =>
            let kept = {version, state: #running}
            await through.store.write(worker, kept)
            await described(through, input.runs, kept)
          | Error(refused) =>
            // A Worker made for nothing kept is told failed, so deleting it removes it.
            if kept == None {
              await through.store.write(worker, {version, state: #failed, reason: refused.reason})
            }
            Error(refused)
          }
        }
      }
    }
  }
}

let deploy = async (through, input: Contracts.DeploymentDeploy.t) =>
  answered(
    Contracts.Interface.Deployments.deploy,
    switch checked(input) {
    | Error(_) as refused => refused
    | Ok(given) =>
      if given != [] {
        let named = given->Array.map(wayName)->Array.join(" and ")
        let worker = workerOf(input.runs)
        let why = "an ordinary account holding no Worker back, RFC nrs5v"
        Console.warn(`${worker} is given ${named} beyond the network it asks, ${why}`)
      }
      await deploying(through, input)
    },
  )

let notFound = (runs: Contracts.DeploymentRuns.t) => Error({
  reason: "not_found",
  message: `no deployment of ${workerOf(runs)} is kept`,
})

let stopping_ = async (through, runs) => {
  let worker = workerOf(runs)
  switch await through.store.read(worker) {
  | None => notFound(runs)
  | Some({state: #stopped | #failed} as kept) => await described(through, runs, kept)
  | Some({state: #running} as kept) =>
    switch await through.api.running(worker) {
    | Error(_) as refused => refused
    | Ok(running) =>
      let stubbed = switch await through.api.upload(
        worker,
        {bundle: stub, bindings: [], tag: stopping},
      ) {
      | Ok(id) => await through.api.deploy(worker, id)
      | Error(_) as refused => refused
      }
      switch stubbed {
      | Error(_) as refused => refused
      | Ok() =>
        let kept = {
          version: kept.version,
          state: #stopped,
          replaced: ?(running->Option.map(r => r.id)),
        }
        await through.store.write(worker, kept)
        await described(through, runs, kept)
      }
    }
  }
}

let stop = async (through, input: Contracts.DeploymentOf.t) =>
  answered(Contracts.Interface.Deployments.stop, await stopping_(through, input.runs))

let resuming = async (through, runs) => {
  let worker = workerOf(runs)
  switch await through.store.read(worker) {
  | None => notFound(runs)
  | Some({state: #running | #failed} as kept) => await described(through, runs, kept)
  | Some({state: #stopped} as kept) =>
    switch kept.replaced {
    | None =>
      Error({reason: "fault", message: `the version a stop of ${worker} replaced is not kept`})
    | Some(replaced) =>
      switch await through.api.deploy(worker, replaced) {
      | Error(_) as refused => refused
      | Ok() =>
        let kept = {version: kept.version, state: #running}
        await through.store.write(worker, kept)
        await described(through, runs, kept)
      }
    }
  }
}

let resume = async (through, input: Contracts.DeploymentOf.t) =>
  answered(Contracts.Interface.Deployments.resume, await resuming(through, input.runs))

let describe = async (through, input: Contracts.DeploymentOf.t) =>
  answered(
    Contracts.Interface.Deployments.describe,
    switch await through.store.read(workerOf(input.runs)) {
    | None => notFound(input.runs)
    | Some(kept) => await described(through, input.runs, kept)
    },
  )

let deleting = async (through, runs) => {
  let worker = workerOf(runs)
  switch await through.store.read(worker) {
  | Some({state: #running}) =>
    Error({reason: "still_running", message: `${worker} is running; stop it first`})
  | Some({state: #stopped | #failed}) | None =>
    switch await through.api.delete(worker) {
    | Error(_) as refused => refused
    | Ok() =>
      await through.store.forget(worker)
      Ok(({}: Contracts.DeploymentDeleted.t))
    }
  }
}

let delete = async (through, input: Contracts.DeploymentOf.t) =>
  answered(Contracts.Interface.Deployments.delete, await deleting(through, input.runs))
