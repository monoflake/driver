/***
 * What install gives the Worker beside its bindings, its install id and the kinds it offers, and
 * the guard holding every name the driver acts on to that id, RFC nrs5v's Ledger.
 */
module Function = DriverCloudflareFunction.Function
module Management = DriverCloudflareManagement.Management

let idForm = /^[0-9a-f]{8}$/

/** A name in the id form, a lowercase word or words joined by hyphens, then the install id. */
let nameForm = /^[a-z0-9]+(-[a-z0-9]+)*-[0-9a-f]{8}$/

/** The install id given, or why install is broken, its message naming the variable. */
let idOf = (given: option<string>) =>
  switch given {
  | Some(id) if idForm->RegExp.test(id) => Ok(id)
  | Some(_) | None => Error("INSTALL_ID is unset or not 8 lowercase hex digits, so install broke")
  }

let kindOf = (name): option<Management.kind> =>
  switch name {
  | "function" => Some(#function)
  | "object" => Some(#object)
  | "database" => Some(#database)
  | _ => None
  }

/** The kinds offered, or why install is broken where KINDS is unset, empty or names another. */
let kindsOf = (given: option<string>) => {
  let broken = why => Error(`KINDS ${why}, so install broke`)
  switch given->Option.map(String.trim) {
  | None => broken("is unset")
  | Some("") => broken("is empty")
  | Some(listed) =>
    let names = listed->String.split(",")->Array.map(String.trim)
    switch names->Array.find(name => kindOf(name) == None) {
    | Some(other) => broken(`names "${other}", where each is function, object or database`)
    | None => Ok(names->Array.filterMap(kindOf))
    }
  }
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

/** An account's API on owned names alone, each followed by the id, as `through` holds no id. */
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
