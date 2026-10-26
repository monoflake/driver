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
  address: string => promise<result<string, refused>>,
}

// The runtime's `fetch` is called directly, since workerd refuses one called as a record's method.
let ofAccount = (~accountId, ~token) =>
  Cloudflare.api(~send=(url, init) => Web.fetch(url, init), ~accountId, ~token)

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

type through = {
  api: api,
  store: store,
  fetch: string => promise<result<Uint8Array.t, refused>>,
  listed: Contracts.DeploymentRuns.t => option<string>,
  released: string => promise<unit>,
}

/** The most an artifact may be, a Worker's 64 MiB on every plan, RFC nrs5v. */
let largest = 67_108_864

/** The most a version's tag holds, Cloudflare's `workers/tag` of 100 bytes. */
let tagged = 100

/** The prefix of every name the platform binds, never a deployment's own secret's. */
let reserved = "MONOFLAKE_"

/** What names the footing's address to a Worker, as driver(machine) names it to a worker. */
let footing = "MONOFLAKE_FOOTING"

/** The tag the stub is uploaded with, which no version's tag is. */
let stopping = "stopped"

/** The most a resource id is, 8 hex digits, RFC b8f35. */
let largestId = 4_294_967_295.

/**
 * A deployment's Worker, its resource id bare as 8 lowercase hex digits, an app's or a
 * component's, RFC nrs5v; an id of no such form is written as it came, which no guard holds.
 */
let workerOf = (runs: Contracts.DeploymentRuns.t) => {
  let id = switch runs {
  | App({id}) | Component({id}) => id
  }
  Math.floor(id) == id && id >= 0. && id <= largestId
    ? Float.toString(id, ~radix=16)->String.padStart(8, "0")
    : Float.toString(id)
}

/** The Worker of a deployment, the one an organization listed for it or its own. */
let nameOf = (through, runs) =>
  switch through.listed(runs) {
  | Some(name) => name
  | None => workerOf(runs)
  }

let tagOf = hash => `version-${Envelope.Hex.encode(hash)}`->String.slice(~start=0, ~end=tagged)

/**
 * A version's tag as the driver gives it, the deployment's own name first, so a Worker carries
 * which deployment it was made for, `<own name>/<rest>`, RFC nrs5v's Ledger. It is never cut, the
 * bound of a tag held on the whole tag where the install id is put before it.
 */
let taggedFor = (runs, rest) => `${workerOf(runs)}/${rest}`

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

/** What a deploy's form, runtime, isolation, secrets and network ask that a Worker cannot give. */
let checkedForm = (input: Contracts.DeploymentDeploy.t) =>
  switch (input.form, input.runtime) {
  | (Component | Image, _) => beyond("a function here runs modules alone, as a Worker")
  | (Modules, Some(Workerd | Wasmtime | Runc | Crun | Youki)) =>
    beyond("modules run on Workers alone here")
  | (Modules, None | Some(Workers)) =>
    if !(input.isolation->Array.every(i => i == Contracts.DeploymentIsolation.Isolate)) {
      beyond("a Worker stands on an isolate's isolation alone")
    } else {
      // A Worker's secret binding holds text, and the message names the secret, never its bytes.
      switch input.secrets
      ->Dict.toArray
      ->Array.find(((_, bytes)) => Web.fromUtf8(bytes) == None) {
      | Some((name, _)) => beyond(`the secret ${name} is no UTF-8 text, as a Worker's secret is`)
      | None => outbound(input.network)
      }
    }
  }

/** Each case the platform hands a deployment, its name the contract's, RFC y2xd3. */
let handedName = (handed: Contracts.DeploymentHanded.t) =>
  switch handed {
  | Root(_) => "root"
  | Key(_) => "key"
  | Certificate(_) => "certificate"
  | SigningKey(_) => "signing_key"
  }

/** A case handed twice, which a deploy never holds, RFC y2xd3's Ledger. */
let handedTwice = (handed: array<Contracts.DeploymentHanded.t>) => {
  let names = handed->Array.map(handedName)
  names->Array.filterWithIndex((name, at) => names->Array.indexOf(name) != at)->Array.get(0)
}

/**
 * What a deploy asks that a Worker cannot give, refused before anything is fetched; a deployment
 * reached on the binding waits on this driver's data path, the workspace's `inline-data-path`.
 */
let checked = (input: Contracts.DeploymentDeploy.t) =>
  switch (input.reaching->Option.getOr([]) != [], input.handed->Option.getOr([])->handedTwice) {
  | (true, _) => beyond("a Worker reaches no other deployment on its binding yet")
  | (false, Some(name)) => Error({reason: "invalid", message: `${name} is handed twice`})
  | (false, None) =>
    switch input.secrets->Dict.keysToArray->Array.find(name => name->String.startsWith(reserved)) {
    | Some(name) =>
      Error({reason: "malformed", message: `${name} is a name the platform keeps, ${reserved}`})
    | None => checkedForm(input)
    }
  }

/** A deployment described as it is kept, its address the one its Worker answers at. */
let described = async (through, runs, kept: kept): result<Contracts.DeploymentDescribed.t, _> => {
  let version = Envelope.Hex.decode(kept.version)->Option.getOr(Uint8Array.fromLength(32))
  switch kept.state {
  | #stopped => Ok({runs, version, state: Stopped})
  | #failed => Ok({runs, version, state: Failed({reason: kept.reason->Option.getOr("fault")})})
  | #running =>
    switch await through.api.address(nameOf(through, runs)) {
    | Ok(address) =>
      Ok({runs, version, state: Running({address, runtime: Workers, isolation: [Isolate]})})
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

/**
 * What the platform hands a deployment bound under its reserved name, bytes as hex in plain text
 * and a secret as secret text, its bytes in hex too, RFC y2xd3.
 */
let handedBound = (handed: Contracts.DeploymentHanded.t) =>
  switch handed {
  | Root({value}) => PlainText({name: "MONOFLAKE_ROOT", text: Envelope.Hex.encode(value)})
  | Key({value}) => SecretText({name: "MONOFLAKE_KEY", text: Envelope.Hex.encode(value)})
  | Certificate({value}) =>
    PlainText({name: "MONOFLAKE_CERTIFICATE", text: Envelope.Hex.encode(value)})
  | SigningKey({value}) =>
    SecretText({name: "MONOFLAKE_SIGNING_KEY", text: Envelope.Hex.encode(value)})
  }

/** The footing's address, each case handed, and each secret, UTF-8 text as `checked` holds it. */
let bindingsOf = (input: Contracts.DeploymentDeploy.t) =>
  Array.concatMany(
    [PlainText({name: footing, text: input.footing})],
    [
      input.handed->Option.getOr([])->Array.map(handedBound),
      input.secrets
      ->Dict.toArray
      ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
      ->Array.map(((name, bytes)) => SecretText({
        name,
        text: Web.fromUtf8(bytes)->Option.getOr(""),
      })),
    ],
  )

let deploying = async (through, input: Contracts.DeploymentDeploy.t) => {
  let worker = nameOf(through, input.runs)
  let version = Envelope.Hex.encode(input.version)
  let tag = taggedFor(input.runs, tagOf(input.version))
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
            // A Worker made, or not known to be absent, for nothing kept is told failed for delete.
            switch (kept, await through.api.running(worker)) {
            | (None, Ok(Some(_)) | Error(_)) =>
              await through.store.write(worker, {version, state: #failed, reason: refused.reason})
            | (Some(_), _) | (None, Ok(None)) => ()
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
        let worker = nameOf(through, input.runs)
        let why = "an ordinary account holding no Worker back, RFC nrs5v"
        Console.warn(`${worker} is given ${named} beyond the network it asks, ${why}`)
      }
      await deploying(through, input)
    },
  )

let notFound = worker => Error({reason: "not_found", message: `no deployment of ${worker} is kept`})

/** A stop finding the Worker running another version than the one kept, which it never keeps. */
let notRunning = worker => Error({
  reason: "fault",
  message: `the version running on ${worker} is not the one kept, so nothing is stopped`,
})

let stopping_ = async (through, runs) => {
  let worker = nameOf(through, runs)
  switch await through.store.read(worker) {
  | None => notFound(worker)
  | Some({state: #stopped | #failed} as kept) => await described(through, runs, kept)
  | Some({state: #running} as kept) =>
    let keptTag =
      Envelope.Hex.decode(kept.version)->Option.map(hash => taggedFor(runs, tagOf(hash)))
    switch await through.api.running(worker) {
    | Error(_) as refused => refused
    | Ok(None) | Ok(Some({tag: None})) => notRunning(worker)
    | Ok(Some({tag: Some(tag)})) if Some(tag) != keptTag => notRunning(worker)
    | Ok(Some(running)) =>
      let stubbed = switch await through.api.upload(
        worker,
        {bundle: stub, bindings: [], tag: taggedFor(runs, stopping)},
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
          replaced: running.id,
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
  let worker = nameOf(through, runs)
  switch await through.store.read(worker) {
  | None => notFound(worker)
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
    switch await through.store.read(nameOf(through, input.runs)) {
    | None => notFound(nameOf(through, input.runs))
    | Some(kept) => await described(through, input.runs, kept)
    },
  )

let deleting = async (through, runs) => {
  let worker = nameOf(through, runs)
  switch await through.store.read(worker) {
  | Some({state: #running}) =>
    Error({reason: "still_running", message: `${worker} is running; stop it first`})
  // A listed Worker the driver took over is let go untouched, to be deleted by hand, RFC nrs5v.
  | Some({state: #stopped | #failed}) if through.listed(runs) != None =>
    await through.released(worker)
    await through.store.forget(worker)
    Ok(({}: Contracts.DeploymentDeleted.t))
  // One it never took over is left as it is, and named to nobody.
  | None if through.listed(runs) != None => Ok(({}: Contracts.DeploymentDeleted.t))
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
