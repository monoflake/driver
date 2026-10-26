/***
 * The Worker `driver`, every call held to the binding's token before it is read, answered and swept
 * as driver(machine)'s `served.rs` does, RFC nrs5v.
 */
module Contracts = Envelope.Contracts
module Management = DriverCloudflareManagement.Management
module Function = DriverCloudflareFunction.Function
module Thrown = DriverCloudflareFunction.Thrown

type database = Stores.database

type env = {
  @as("DB") db: database,
  @as("API_TOKEN") apiToken: string,
  @as("ACCOUNT_ID") accountId: string,
  @as("BINDING") binding: string,
  @as("DRIVER_REVISION") revision?: string,
  @as("INSTALL_ID") installId?: string,
  @as("KINDS") kinds?: string,
}

/** The interfaces it serves, as a call names them. */
let served = "management, deployments"

let answered = (operation: Contracts.operation, result: result<'o, Management.refused>) =>
  switch result {
  | Ok(output) => Contracts.Answer.Success(output)
  | Error(r) =>
    Contracts.Answer.Error(Answer.error(~declared=operation.reasons, r.reason, ~message=r.message))
  }

let capacityOf = (c: Contracts.ManagementCapacity.t): Management.capacity =>
  switch c {
  // Past an int a container's cores are refused as any container is, so its wrap tells nothing.
  | Container({millicores, memory}) => Container({millicores: Float.toInt(millicores), memory})
  | Volume({size}) => Volume({size: size})
  | Object({size}) => Object({size: size})
  | Database({size}) => Database({size: size})
  }

let capacityTo = (c: Management.capacity): Contracts.ManagementCapacity.t =>
  switch c {
  | Container({millicores, memory}) => Container({millicores: Int.toFloat(millicores), memory})
  | Volume({size}) => Volume({size: size})
  | Object({size}) => Object({size: size})
  | Database({size}) => Database({size: size})
  }

let stateTo = (s: Management.state): Contracts.ManagementState.t =>
  switch s {
  | Making => Making
  | Made({address}) => Made({address: address})
  | Failed({reason, ?message}) => Failed({reason, ?message})
  | Unasked({since, ?address}) => Unasked({since, ?address})
  }

/** The account's API as the function kind asks it, by the Worker's token. */
let account = env => Function.ofAccount(~accountId=env.accountId, ~token=env.apiToken)

/** Whether a Worker is on the account, by its name. */
let existing = (env, name) => Scripts.exists(~accountId=env.accountId, ~token=env.apiToken, name)

/** The Workers a list kept adopts, by name. */
let listedOf = (kept: Management.kept) =>
  kept.adopted->Array.filter(entry => entry.kind == #function)->Array.map(entry => entry.name)

/** The account read for whether a Worker is there, for a name held, listed or warned of alone. */
let seen = (env, kept: Management.kept, records) =>
  Installed.seen(
    existing(env, _),
    ~read=Array.concatMany(
      Owned.deployments(records),
      [listedOf(kept), kept.warnings->Array.map(w => w.name)],
    ),
  )

/** A Worker's address, the Workers `object` and `database` found by their records, nrs5v. */
let addressOf = async (env, records, role) =>
  switch Owned.named(records, role) {
  | None =>
    Error(
      (
        {
          reason: "fault",
          message: `no ${Owned.roleSaid(role)} is in the driver's records, so install broke`,
        }: Management.refused
      ),
    )
  | Some(name) =>
    // This path calls nothing but the address read.
    let api =
      account(env)->Installed.api(
        ~held=[name],
        ~listed=[],
        ~exists=existing(env, _),
        ~install="",
        ~owner="",
      )
    switch await api.address(name) {
    | Ok(address) => Ok(address)
    | Error({reason, message}) => Error(({reason, message}: Management.refused))
    }
  }

let hex = bytes => bytes->Array.map(Envelope.Hex.encode)

let warningTo = (w: Management.warning): Contracts.ManagementWarning.t => {
  reason: w.reason,
  message: w.message,
  name: w.name,
}

let kindTo = (kind: Management.kind): Contracts.ManagementKind.t =>
  switch kind {
  | #function => Function
  | #object => Object
  | #database => Database
  }

let adoptableOf = (kind: Contracts.ManagementAdoptable.t) =>
  switch kind {
  | Function => #function
  | Object => #object
  | Database => #database
  }

let adoptedOf = (entry: Contracts.ManagementAdopted.t): Management.adopted => {
  kind: adoptableOf(entry.kind),
  name: entry.name,
  for_: switch entry.for_ {
  | Deployment({runs: App({id})}) => App(id)
  | Deployment({runs: Component({component, id})}) => Component({component, id})
  | Item({id}) => Item(id)
  },
}

let adoptedTo = (entry: Management.adopted): Contracts.ManagementAdopted.t => {
  kind: switch entry.kind {
  | #function => Function
  | #object => Object
  | #database => Database
  },
  name: entry.name,
  for_: switch entry.for_ {
  | App(id) => Deployment({runs: App({id: id})})
  | Component({component, id}) => Deployment({runs: Component({component, id})})
  | Item(id) => Item({id: id})
  },
}

/** The Worker an organization listed for a deployment, in place of its own, RFC nrs5v. */
let listedFor = (adopted: array<Management.adopted>, runs: Contracts.DeploymentRuns.t) =>
  adopted->Array.findMap(entry =>
    switch (entry.kind, entry.for_) {
    | (#function, for_) =>
      let stands = switch (for_, runs) {
      // A deployment is its resource id, unique in the organization, RFC y2xd3.
      | (App(id), App({id: asked})) | (Component({id}), Component({id: asked})) => id == asked
      | (App(_) | Component(_) | Item(_), App(_) | Component(_)) => false
      }
      stands ? Some(entry.name) : None
    | (#object | #database, _) => None
    }
  )

/** What a person is told of a listed Worker the driver let go, never deleting it, RFC nrs5v. */
let released = (name): Management.warning => {
  reason: "delete_by_hand",
  name,
  message: `${name} is no longer managed, so delete it by hand in Cloudflare's dashboard`,
}

/** What a person is told of a listed Worker the account no longer holds. */
let missing = (name): Management.warning => {
  reason: "missing",
  name,
  message: `${name} is listed but is no Worker on the account, so nothing runs as it`,
}

let warned = (kept: Management.kept, name) => kept.warnings->Array.some(w => w.name == name)

/** A listed Worker the driver took over let go, warned of once. */
let release = async (store: Management.store, name) => {
  let kept = await store.read()
  if !warned(kept, name) {
    await store.write({...kept, warnings: kept.warnings->Array.concat([released(name)])})
  }
}

/** A warning's Worker deployed again, so it is managed once more and its warning cleared. */
let redeployed = async (store: Management.store, name) => {
  let kept = await store.read()
  if warned(kept, name) {
    await store.write({...kept, warnings: kept.warnings->Array.filter(w => w.name != name)})
  }
}

/** Each warning whose Worker is gone, its script answering 10007, none where it was not read. */
let goneOf = async (env, kept: Management.kept, records) => {
  let seen = seen(env, kept, records)
  let gone = await Promise.all(
    kept.warnings->Array.map(async w =>
      switch await seen(w.name) {
      | Ok(false) => true
      | Ok(true) | Error(_) => false
      }
    ),
  )
  kept.warnings->Array.filterWithIndex((_, at) => gone[at] == Some(true))->Array.map(w => w.name)
}

/**
 * Each warning whose Worker is gone removed, with the row a release kept for it, as a management
 * request other than describe arrives, written only where one is, RFC nrs5v's Ledger.
 */
let cleared = async (env, store: Management.store, records) => {
  let kept = await store.read()
  switch await goneOf(env, kept, records) {
  | [] => ()
  | gone =>
    let warnings = kept.warnings->Array.filter(w => !(gone->Array.includes(w.name)))
    await store.write({...kept, warnings})
    let listed = listedOf(kept)
    let deployments = Kept.deployments(env.db)
    for at in 0 to Array.length(gone) - 1 {
      let name = gone->Array.getUnsafe(at)
      if !(listed->Array.includes(name)) {
        await deployments.forget(name)
      }
    }
  }
}

/** The warnings describe answers, each gone left out and each listed Worker missing named. */
let standing = async (env, kept: Management.kept, records) => {
  let seen = seen(env, kept, records)
  let gone = await goneOf(env, kept, records)
  let listed = listedOf(kept)
  let absent = await Promise.all(listed->Array.map(async name => (await seen(name)) == Ok(false)))
  Array.concat(
    kept.warnings->Array.filter(w => !(gone->Array.includes(w.name))),
    listed->Array.filterWithIndex((_, at) => absent[at] == Some(true))->Array.map(missing),
  )
}

/** Why a list cannot adopt a Worker it newly names, raised from the store's write. */
exception Unadoptable(Management.refused)

/** What an adopted entry stands for, as a message names it. */
let forSaid = (for_: Management.adoptedFor) =>
  switch for_ {
  | App(id) => `app ${Float.toString(id)}`
  | Component({component, id}) => `component ${component} ${Float.toString(id)}`
  | Item(id) => `item ${Float.toString(id)}`
  }

/** A deployment's own Worker, by its resource id. */
let ownOf = (for_: Management.adoptedFor) =>
  switch for_ {
  | App(id) => Some(Function.workerOf(App({id: id})))
  | Component({component, id}) => Some(Function.workerOf(Component({component, id})))
  | Item(_) => None
  }

/**
 * Why a Worker the list newly adopts cannot be, read before anything is written, one the records
 * hold, one for a deployment already running as a Worker, or one the account does not hold.
 */
let unadoptable = async (env, before: Management.kept, records, adopted) => {
  let rows = Kept.deployments(env.db)
  let invalid = message => Some(({reason: "invalid", message}: Management.refused))
  let added =
    adopted->Array.filter((entry: Management.adopted) =>
      entry.kind == #function && !(before.adopted->Array.some(held => held.name == entry.name))
    )
  let found = ref(None)
  for at in 0 to Array.length(added) - 1 {
    if found.contents == None {
      let entry: Management.adopted = added->Array.getUnsafe(at)
      let name = entry.name
      // The deployment's own Worker, and the one it was listed with before.
      let before =
        before.adopted
        ->Array.find(held => held.for_ == entry.for_ && held.name != name)
        ->Option.map(held => held.name)
      let runsAs = async worker =>
        switch worker {
        | Some(worker) => (await rows.read(worker))->Option.map(_ => worker)
        | None => None
        }
      found :=
        switch Owned.roleIn(records, name) {
        | Some(#deployment) =>
          invalid(`${name} is a deployment's Worker the driver made, so it is never listed`)
        | Some(role) => invalid(`${name} is the driver's own ${Owned.roleSaid(role)}, never listed`)
        | None =>
          let running = switch await runsAs(ownOf(entry.for_)) {
          | Some(worker) => Some(worker)
          | None => await runsAs(before)
          }
          switch running {
          | Some(worker) =>
            let runs = forSaid(entry.for_)
            invalid(`${runs} runs as ${worker} already, so ${name} waits until it is deleted`)
          | None =>
            switch await existing(env, name) {
            | Ok(true) => None
            | Ok(false) =>
              invalid(`${name} is no Worker on the account, and adoption takes only what is there`)
            | Error({reason, message}) => Some({reason, message})
            }
          }
        }
    }
  }
  found.contents
}

/**
 * The store an apply writes through, refusing a Worker it cannot adopt and warning of each listed
 * Worker it drops that the driver took over, its row kept, in that one write.
 */
let adopting = (env, store: Management.store, before: Management.kept, records) => {
  Management.read: store.read,
  write: async kept => {
    switch await unadoptable(env, before, records, kept.adopted) {
    | Some(refused) => throw(Unadoptable(refused))
    | None => ()
    }
    let rows = Kept.deployments(env.db)
    let dropped =
      listedOf(before)->Array.filter(name =>
        !(kept.adopted->Array.some(entry => entry.name == name)) && !warned(kept, name)
      )
    let taken = await Promise.all(dropped->Array.map(async name => (await rows.read(name)) != None))
    let raised =
      dropped->Array.filterWithIndex((_, at) => taken[at] == Some(true))->Array.map(released)
    await store.write({...kept, warnings: Array.concat(kept.warnings, raised)})
  },
}

/** A management call on the list kept, its grace swept first. */
let managed = async (env, store, call: Contracts.Interface.Management.call, form, ~kinds) => {
  let now = Date.now()
  // A swept item's store is cleared by its Worker, `object` or `database`, as requests come.
  ignore(await Management.sweep(store, ~now))
  let records = await Owned.read(env.db)
  switch call {
  | Describe(_) => ()
  | Apply(_) | SetPolicy(_) | End(_) => await cleared(env, store, records)
  }
  let held = (generation): Contracts.ManagementHeld.t => {generation: generation}
  switch call {
  | Apply(input) =>
    let before = await store.read()
    let items = input.items->Array.map((item): Management.item => {
      id: item.id,
      capacity: capacityOf(item.capacity),
      credentials: hex(item.credentials),
    })
    let result = switch await Management.apply(
      adopting(env, store, before, records),
      ~offered=kinds,
      ~now,
      ~generation=input.generation,
      ~items,
      ~tokens=input.tokens->Option.map(hex),
      ~adopted=input.adopted->Option.map(adopted => adopted->Array.map(adoptedOf)),
      ~objects=() => addressOf(env, records, #object),
      ~databases=() => addressOf(env, records, #database),
    ) {
    | result => result
    | exception Unadoptable(refused) => Error(refused)
    }
    answered(Contracts.Interface.Management.apply, result->Result.map(held))->Answer.written(
      form,
      ~toJson=Contracts.ManagementHeld.toJson,
      ~toCbor=Contracts.ManagementHeld.toCbor,
    )
  | SetPolicy(input) =>
    let grace = Math.min(input.grace, 2147483647.)->Float.toInt
    let result = await Management.setPolicy(store, ~now, ~generation=input.generation, ~grace)
    answered(Contracts.Interface.Management.setPolicy, result->Result.map(held))->Answer.written(
      form,
      ~toJson=Contracts.ManagementHeld.toJson,
      ~toCbor=Contracts.ManagementHeld.toCbor,
    )
  | Describe(_) =>
    let kept = await Management.describe(store, ~now)
    let warnings = await standing(env, kept, records)
    let described: Contracts.ManagementDescribed.t = {
      generation: kept.generation,
      policy: kept.policy,
      grace: Int.toFloat(kept.grace),
      items: kept.items->Array.map((k): Contracts.ManagementHolding.t => {
        id: k.item.id,
        capacity: capacityTo(k.item.capacity),
        state: stateTo(k.state),
      }),
      revision: ?env.revision,
      kinds: kinds->Array.map(kindTo),
      adopted: kept.adopted->Array.map(adoptedTo),
      warnings: ?(warnings == [] ? None : Some(warnings->Array.map(warningTo))),
    }
    Contracts.Answer.Success(described)->Answer.written(
      form,
      ~toJson=Contracts.ManagementDescribed.toJson,
      ~toCbor=Contracts.ManagementDescribed.toCbor,
    )
  | End(input) =>
    let result = await Management.end_(store, ~id=input.id)
    let ended = (): Contracts.ManagementEnded.t => {}
    answered(Contracts.Interface.Management.end, result->Result.map(ended))->Answer.written(
      form,
      ~toJson=Contracts.ManagementEnded.toJson,
      ~toCbor=Contracts.ManagementEnded.toCbor,
    )
  }
}

let unfetchable = message => Error({Function.reason: "unfetchable", message})

let largest = Function.largest

/** The redirects a fetch follows, as many as driver(machine)'s client follows by default. */
let hops = 10

let tooLarge = () => Error({
  Function.reason: "too_large",
  message: `an artifact is at most ${Int.toString(largest)} bytes`,
})

/** A body read as it comes, held to the bound on what came, which may be more than it said. */
let bounded = async response =>
  switch response->Web.body->Nullable.toOption {
  | None => Ok(Uint8Array.fromLength(0))
  | Some(stream) =>
    let reader = stream->Web.reader
    let chunks = []
    let total = ref(0)
    let over = ref(false)
    let ended = ref(false)
    while !ended.contents && !over.contents {
      let chunk = await reader->Web.read
      switch chunk.value->Nullable.toOption {
      | Some(bytes) if !chunk.done =>
        total := total.contents + TypedArray.length(bytes)
        total.contents > largest ? over := true : chunks->Array.push(bytes)
      | Some(_) | None => ended := true
      }
    }
    if over.contents {
      await reader->Web.cancel
      tooLarge()
    } else {
      let whole = Uint8Array.fromLength(total.contents)
      chunks
      ->Array.reduce(0, (at, bytes) => {
        whole->Web.copyInto(bytes, at)
        at + TypedArray.length(bytes)
      })
      ->ignore
      Ok(whole)
    }
  }

/** A body not to be read closed, so its connection is not held open past the answer. */
let dropped = async response =>
  switch response->Web.body->Nullable.toOption {
  | Some(stream) =>
    switch await stream->Web.discard {
    | () => ()
    | exception JsExn(_) => ()
    }
  | None => ()
  }

/**
 * An artifact fetched from its address by https alone, each redirect followed only to https, and
 * refused past the bound by its length before it is read, as machine's `container/src/fetch.rs`.
 */
let rec fetchedFrom = async (address, ~left) =>
  switch Web.parts(address)->Web.protocol {
  | "https:" =>
    switch await Web.fetch(address, {method: "GET", redirect: "manual"}) {
    | response =>
      let status = response->Web.status
      let header = name => response->Web.responseHeaders->Web.header(name)->Nullable.toOption
      switch (status, header("location")) {
      | (301 | 302 | 303 | 307 | 308, Some(location)) =>
        await dropped(response)
        switch Web.partsIn(location, address)->Web.href {
        | next if left > 0 => await fetchedFrom(next, ~left=left - 1)
        | _ => unfetchable("the artifact's address redirects too often")
        | exception JsExn(_) => unfetchable("the artifact's address redirects to no URL")
        }
      | _ if status < 200 || status >= 300 =>
        await dropped(response)
        unfetchable(`the artifact's address answered ${Int.toString(status)}`)
      | _ =>
        switch header("content-length")->Option.flatMap(n => Float.fromString(n)) {
        | Some(length) if length > Int.toFloat(largest) =>
          await dropped(response)
          tooLarge()
        | Some(_) | None =>
          switch await bounded(response) {
          | read => read
          | exception JsExn(_) => unfetchable("the artifact's body was not read whole")
          }
        }
      }
    | exception JsExn(e) => unfetchable(Thrown.told("the artifact's address was not reached", e))
    }
  | _ => unfetchable("an artifact's address is https:")
  | exception JsExn(_) => unfetchable("an artifact's address is no URL")
  }

let artifact = address => fetchedFrom(address, ~left=hops)

/** A deployments call refused by a reason its operation declares, Cloudflare not reached. */
let refusedAs = (call: Contracts.Interface.Deployments.call, form, reason, message) => {
  let described = operation =>
    answered(operation, Error(({reason, message}: Management.refused)))->Answer.written(
      form,
      ~toJson=Contracts.DeploymentDescribed.toJson,
      ~toCbor=Contracts.DeploymentDescribed.toCbor,
    )
  switch call {
  | Deploy(_) => described(Contracts.Interface.Deployments.deploy)
  | Stop(_) => described(Contracts.Interface.Deployments.stop)
  | Resume(_) => described(Contracts.Interface.Deployments.resume)
  | Describe(_) => described(Contracts.Interface.Deployments.describe)
  | Delete(_) => described(Contracts.Interface.Deployments.delete)
  }
}

/** A delete answered done, where the driver holds nothing of the deployment to delete. */
let nothingDeleted = form =>
  Contracts.Answer.Success(({}: Contracts.DeploymentDeleted.t))->Answer.written(
    form,
    ~toJson=Contracts.DeploymentDeleted.toJson,
    ~toCbor=Contracts.DeploymentDeleted.toCbor,
  )

/** A deployments call on the account's Workers, a listed Worker deployed to warned of no more. */
let deployed = async (through: Function.through, store, call, form) => {
  let described = answer =>
    answer->Answer.written(
      form,
      ~toJson=Contracts.DeploymentDescribed.toJson,
      ~toCbor=Contracts.DeploymentDescribed.toCbor,
    )
  switch (call: Contracts.Interface.Deployments.call) {
  | Deploy(input) =>
    let answer = await Function.deploy(through, input)
    switch (answer, through.listed(input.runs)) {
    | (Success(_), Some(name)) => await redeployed(store, name)
    | (Success(_), None) | (Error(_), _) => ()
    }
    described(answer)
  | Stop(input) => described(await Function.stop(through, input))
  | Resume(input) => described(await Function.resume(through, input))
  | Describe(input) => described(await Function.describe(through, input))
  | Delete(input) =>
    (await Function.delete(through, input))->Answer.written(
      form,
      ~toJson=Contracts.DeploymentDeleted.toJson,
      ~toCbor=Contracts.DeploymentDeleted.toCbor,
    )
  }
}

/**
 * A deployments call where `function` is not offered, answered by reasons the contract declares,
 * RFC nrs5v's Ledger. No deployment can exist, so delete finds none, and Cloudflare is not reached.
 */
let unoffered = (call: Contracts.Interface.Deployments.call, form) => {
  let none = "no deployment is kept, function not being offered, by KINDS"
  switch call {
  | Deploy(_) => refusedAs(call, form, "beyond_host", "function is not offered, by KINDS")
  | Stop(_) | Resume(_) | Describe(_) => refusedAs(call, form, "not_found", none)
  | Delete(_) => nothingDeleted(form)
  }
}

/**
 * A deployment's own Worker claimed for its first deploy and given back only once the Worker is
 * confirmed absent; where it may be there, the claim stays and the deployment is kept failed, so a
 * delete can still remove it, RFC nrs5v's Ledger.
 */
let claimed = async (env, own, ~runs, ~version, deploy) => {
  await Owned.claim(env.db, own)
  let rows = Kept.deploymentOf(env.db, runs)
  let settled = async () =>
    // A claim given back already, by a refusal of a Worker another made, is left as it is.
    if Owned.roleIn(await Owned.read(env.db), own) == Some(#deployment) {
      switch await rows.read(own) {
      | Some(_) => ()
      | None =>
        switch await existing(env, own) {
        | Ok(false) => await Owned.unclaim(env.db, own)
        | Ok(true) | Error(_) =>
          await rows.write(
            own,
            {version: Envelope.Hex.encode(version), state: #failed, reason: "fault"},
          )
        }
      }
    }
  switch await deploy() {
  | answer =>
    await settled()
    answer
  | exception error =>
    await settled()
    throw(error)
  }
}

let runsOf = (call: Contracts.Interface.Deployments.call) =>
  switch call {
  | Deploy({runs}) | Stop({runs}) | Resume({runs}) | Describe({runs}) | Delete({runs}) => runs
  }

/**
 * A deployments call held to the records, a deployment's own Worker claimed before its first deploy
 * and given back where it ends with nothing kept, and a name unheld never acted on.
 */
let deployment = async (env, store: Management.store, call, form, ~id) => {
  let kept = await store.read()
  let records = await Owned.read(env.db)
  let runs = runsOf(call)
  let listed = listedFor(kept.adopted, runs)
  let own = Function.workerOf(runs)
  let through = held => {
    Function.api: account(env)->Installed.api(
      ~held,
      ~listed=listedOf(kept),
      ~exists=existing(env, _),
      ~install=id,
      ~owner=own,
    ),
    store: Kept.deploymentOf(env.db, runs),
    fetch: artifact,
    listed: listedFor(kept.adopted, _),
    released: name => release(store, name),
  }
  let deployments = Owned.deployments(records)
  let refuse = refusedAs(call, form, ...)
  // Where a deployment's own name is one of the driver's own parts, no deployment runs as it.
  let held: [#deployment | #part(Owned.role) | #none] = switch Owned.roleIn(records, own) {
  | Some(#deployment) => #deployment
  | Some(role) => #part(role)
  | None => #none
  }
  switch (call, listed, held) {
  // A deployment reached on the binding waits on this driver's data path, `inline-data-path`.
  | (Deploy({reaching: ?Some(reaching)}), _, _) if reaching != [] =>
    refuse("beyond_host", "a Worker reaches no other deployment on its binding yet")
  | (_, None, _) if Installed.formed(own)->Result.isError =>
    let message = switch Installed.formed(own) {
    | Error({message}) => message
    | Ok(_) => ""
    }
    refuse("fault", message)
  | (Deploy(_), None, #part(role)) =>
    let message = `${own} is the driver's own ${Owned.roleSaid(role)}, so nothing runs as it`
    refuse("beyond_host", message)
  | (Deploy(_), None, _) if listedOf(kept)->Array.includes(own) =>
    let stands =
      kept.adopted->Array.find(entry => entry.name == own)->Option.mapOr("", e => forSaid(e.for_))
    let message = `${own} is the organization's Worker listed for ${stands}`
    refuse("beyond_host", `${message}, so this deployment never runs as it`)
  | (Delete(_), None, #part(_) | #none) => nothingDeleted(form)
  | (Deploy({version}), None, #none) =>
    await claimed(env, own, ~runs, ~version, async () =>
      switch await existing(env, own) {
      | Ok(false) => await deployed(through([own, ...deployments]), store, call, form)
      | Ok(true) =>
        await Owned.unclaim(env.db, own)
        let message = `the account holds a Worker ${own} the driver did not make`
        refuse("beyond_host", `${message}, so it is never overwritten`)
      | Error({reason, message}) => refuse(reason, message)
      }
    )
  | (Deploy(_) | Delete(_), Some(_), _)
  | (Deploy(_) | Delete(_), None, #deployment)
  | (Stop(_) | Resume(_) | Describe(_), _, _) =>
    await deployed(through(deployments), store, call, form)
  }
}

let managementOperation = (call: Contracts.Interface.Management.call) =>
  switch call {
  | Apply(_) => "apply"
  | SetPolicy(_) => "set_policy"
  | Describe(_) => "describe"
  | End(_) => "end"
  }

let deploymentsOperation = (call: Contracts.Interface.Deployments.call) =>
  switch call {
  | Deploy(_) => "deploy"
  | Stop(_) => "stop"
  | Resume(_) => "resume"
  | Describe(_) => "describe"
  | Delete(_) => "delete"
  }

/** The call a body holds, the operation its path names. */
let read = (form, bytes, operation, ~fromJson, ~fromCbor, ~named) =>
  switch Answer.call(form, bytes, ~fromJson, ~fromCbor) {
  | Ok(envelope) if named(envelope) == operation => Ok(envelope)
  | Ok(envelope) =>
    Error(Answer.malformed(`the path names ${operation} and the call ${named(envelope)}`))
  | Error(_) as refused => refused
  }

/** A call of a Worker installed whole, held to the binding's token before it is read. */
let held = async (request, env, forms: Answer.forms, ~header, ~early, ~id, ~kinds) => {
  let store = Kept.management(env.db)
  let given = env.binding->String.trim->String.toLowerCase
  // A caller not yet held to a token is told nothing of why its token could not be read.
  let held = switch Bearer.hashOf(header("authorization")) {
  | Some(hash) =>
    switch await Management.holds(store, ~given, hash) {
    | held => Ok(held)
    | exception Kept.Unkept(_) => Error()
    | exception JsExn(_) => Error()
    }
  | None => Ok(false)
  }
  let path = Web.parts(request->Web.url)->Web.pathname
  let parts = path->String.split("/")
  switch (held, parts, request->Web.method_, forms.body) {
  | (Error(), _, _, _) => early(Answer.error("fault", ~message="the call's token was not checked"))
  | (Ok(false), _, _, _) => early(Answer.error("denied"))
  | (Ok(true), ["", interface, operation], "POST", Some(form)) =>
    let bytes = await request->Web.bytesOf
    switch interface {
    | "management" =>
      switch read(
        form,
        bytes,
        operation,
        ~fromJson=Contracts.Interface.Management.fromJson,
        ~fromCbor=Contracts.Interface.Management.fromCbor,
        ~named=e => managementOperation(e.call),
      ) {
      | Ok(envelope) => await managed(env, store, envelope.call, forms.answer, ~kinds)
      | Error(error) => early(error)
      }
    | "deployments" =>
      switch read(
        form,
        bytes,
        operation,
        ~fromJson=Contracts.Interface.Deployments.fromJson,
        ~fromCbor=Contracts.Interface.Deployments.fromCbor,
        ~named=e => deploymentsOperation(e.call),
      ) {
      | Ok(envelope) if !(kinds->Array.includes(#function)) =>
        unoffered(envelope.call, forms.answer)
      | Ok(envelope) => await deployment(env, store, envelope.call, forms.answer, ~id)
      | Error(error) => early(error)
      }
    | other => early(Answer.malformed(`no interface ${other}, one of ${served}`))
    }
  | (Ok(true), ["", _, _], "POST", None) =>
    early(Answer.malformed("a call's body is application/json or application/cbor"))
  | (Ok(true), _, _, _) => early(Answer.malformed("a call is POST /{interface}/{operation}"))
  }
}

let serve = async (request, env, forms: Answer.forms) => {
  let header = name => request->Web.requestHeaders->Web.header(name)->Nullable.toOption
  let early = error => Answer.refused(error, forms.answer)
  // A Worker not installed whole is the implementation's fault, never the caller's, nrs5v.
  switch (Installed.idOf(env.installId), Installed.kindsOf(env.kinds)) {
  | (Ok(id), Ok(kinds)) => await held(request, env, forms, ~header, ~early, ~id, ~kinds)
  | (Error(message), _) | (_, Error(message)) => early(Answer.error("fault", ~message))
  }
}

let fetch = async (request, env) => {
  let header = name => request->Web.requestHeaders->Web.header(name)->Nullable.toOption
  let forms = Answer.formsOf(~contentType=header("content-type"), ~accept=header("accept"))
  let fault = message => Answer.refused(Answer.error("fault", ~message), forms.answer)
  switch await serve(request, env, forms) {
  | response => response
  | exception Kept.Unkept(message) => fault(message)
  | exception JsExn(e) => fault(e->JsExn.message->Option.getOr("the driver failed while answering"))
  }
}
