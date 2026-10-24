/***
 * What install gives the Worker beside its bindings, its install id and the kinds it offers, and
 * every name the driver acts on formed from that id, RFC nrs5v's Ledger.
 */
module Function = DriverCloudflareFunction.Function
module Management = DriverCloudflareManagement.Management

let idForm = /^[0-9a-f]{8}$/

/** A name in the id form, a lowercase word or words joined by hyphens, then the install id. */
let nameForm = /^[a-z0-9]+(-[a-z0-9]+)*-[0-9a-f]{8}$/

/** The install id given, None where it is unset or not 8 lowercase hex digits. */
let idOf = env => Vars.read(env).installId->Option.filter(id => idForm->RegExp.test(id))

/** The kinds this driver may offer, as `DRIVER_KINDS` names them. */
let known = ["function", "object", "database"]

/** The kinds offered, `function` alone where KINDS is unset, None where it names another. */
let kindsOf = env =>
  switch Vars.read(env).kinds->Option.map(String.trim) {
  | None | Some("") => Some(["function"])
  | Some(listed) =>
    let kinds = listed->String.split(",")->Array.map(String.trim)
    kinds->Array.every(kind => known->Array.includes(kind)) ? Some(kinds) : None
  }

/** Whether a resource is the driver's own, its name ending in its own install id. */
let owned = (name, ~id) => nameForm->RegExp.test(name) && name->String.endsWith(`-${id}`)

/** A resource's name followed by the install id, refused where the whole is not in the id form. */
let named = (name, ~id): result<string, Function.refused> => {
  let full = `${name}-${id}`
  owned(full, ~id)
    ? Ok(full)
    : Error({
        reason: "beyond_host",
        message: `${full} is not in the driver's id form, so it is never acted on`,
      })
}

/** An account's API acting on owned names alone, each name it is given followed by the id. */
let api = (api: Function.api, ~id): Function.api => {
  let through = async (name, act) =>
    switch named(name, ~id) {
    | Ok(full) => await act(full)
    | Error(_) as refused => refused
    }
  {
    upload: (name, upload) => through(name, full => api.upload(full, upload)),
    deploy: (name, version) => through(name, full => api.deploy(full, version)),
    running: name => through(name, full => api.running(full)),
    delete: name => through(name, full => api.delete(full)),
    address: name => through(name, full => api.address(full)),
  }
}

let kindOf = (item: Management.item) =>
  switch item.capacity {
  | Container(_) => "container"
  | Volume(_) => "volume"
  | Object(_) => "object"
  | Database(_) => "database"
  }

/** The first item of a kind this driver could hold but does not offer, by KINDS. */
let unoffered = (items: array<Management.item>, ~kinds) =>
  items->Array.find(item => {
    let kind = kindOf(item)
    known->Array.includes(kind) && !(kinds->Array.includes(kind))
  })
