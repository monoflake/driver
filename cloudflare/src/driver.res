/***
 * The Worker `driver`, every call held to the binding's token before it is read, answered and swept
 * as driver(machine)'s `served.rs` does, RFC nrs5v.
 */
module Contracts = Envelope.Contracts
module Management = DriverCloudflareManagement.Management
module Function = DriverCloudflareFunction.Function

type database = Stores.database

type env = {
  @as("DB") db: database,
  @as("API_TOKEN") apiToken: string,
  @as("ACCOUNT_ID") accountId: string,
  @as("BINDING") binding: string,
  @as("DRIVER_REVISION") revision?: string,
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

let hex = bytes => bytes->Array.map(Envelope.Hex.encode)

/** A management call on the list kept, its grace swept first. */
let managed = async (env, store, call: Contracts.Interface.Management.call, form) => {
  let now = Date.now()
  // Nothing of an object or a database item is made yet, so a swept item leaves nothing behind.
  ignore(await Management.sweep(store, ~now))
  let held = (generation): Contracts.ManagementHeld.t => {generation: generation}
  switch call {
  | Apply(input) =>
    let items = input.items->Array.map((item): Management.item => {
      id: item.id,
      capacity: capacityOf(item.capacity),
      credentials: hex(item.credentials),
    })
    let result = await Management.apply(
      store,
      ~now,
      ~generation=input.generation,
      ~items,
      ~tokens=input.tokens->Option.map(hex),
    )
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
    | exception JsExn(_) => unfetchable("the artifact's address was not reached")
    }
  | _ => unfetchable("an artifact's address is https:")
  | exception JsExn(_) => unfetchable("an artifact's address is no URL")
  }

let artifact = address => fetchedFrom(address, ~left=hops)

/** A deployments call on the account's Workers. */
let deployed = async (through, call: Contracts.Interface.Deployments.call, form) => {
  let described = answer =>
    answer->Answer.written(
      form,
      ~toJson=Contracts.DeploymentDescribed.toJson,
      ~toCbor=Contracts.DeploymentDescribed.toCbor,
    )
  switch call {
  | Deploy(input) => described(await Function.deploy(through, input))
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

let serve = async (request, env, forms: Answer.forms) => {
  let header = name => request->Web.requestHeaders->Web.header(name)->Nullable.toOption
  let early = error => Answer.refused(error, forms.answer)
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
      | Ok(envelope) => await managed(env, store, envelope.call, forms.answer)
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
      | Ok(envelope) =>
        let through: Function.through = {
          api: Function.ofAccount(~accountId=env.accountId, ~token=env.apiToken),
          store: Kept.deployments(env.db),
          fetch: artifact,
        }
        await deployed(through, envelope.call, forms.answer)
      | Error(error) => early(error)
      }
    | other => early(Answer.malformed(`no interface ${other}, one of ${served}`))
    }
  | (Ok(true), ["", _, _], "POST", None) =>
    early(Answer.malformed("a call's body is application/json or application/cbor"))
  | (Ok(true), _, _, _) => early(Answer.malformed("a call is POST /{interface}/{operation}"))
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
