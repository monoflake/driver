/***
 * What install gives the Worker beside its bindings, its install id and the kinds it offers, and
 * the guard holding every name the driver acts on to its records or the list, RFC nrs5v.
 */
module Function = DriverCloudflareFunction.Function
module Management = DriverCloudflareManagement.Management

/** A resource's id bare, 8 lowercase hex digits, as the state D1's own name is. */
let idForm = /^[0-9a-f]{8}$/

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

/**
 * A deployment's own Worker as the driver formed it, a fault where it is not 8 lowercase hex
 * digits, the envelope having held its id to a resource's already, RFC nrs5v's Ledger.
 */
let formed = name =>
  idForm->RegExp.test(name)
    ? Ok(name)
    : Error({
        Function.reason: "fault",
        message: `${name} is not a name the driver forms, so it is never acted on`,
      })

/** The most a version's tag holds, Cloudflare's `workers/tag` of 100 bytes. */
let tagLength = 100

/** A name neither the records nor the list hold, refused untouched. */
let unheld = name => Error({
  Function.reason: "fault",
  message: `${name} is in neither the driver's records nor the list, so it is never acted on`,
})

/** Whether a Worker is on the account, by name. */
type exists = string => promise<result<bool, Function.refused>>

/** The account read for whether a Worker is there, only for a name in `read`. */
let seen = (exists: exists, ~read: array<string>): exists =>
  name => read->Array.includes(name) ? exists(name) : Promise.resolve(unheld(name))

/**
 * Whether a Worker the records hold is the one this install made for this deployment, its version
 * tagged `<install id>/<owner>/...`, or absent, so nothing of another's is deleted or overwritten.
 * It guards against accident, a name anyone holding the account can write, RFC nrs5v.
 */
let carries = async (api: Function.api, name, ~install, ~owner, ~exists: exists, ~act) => {
  let refused = () => Error({
    Function.reason: "fault",
    message: `${name} carries no tag the driver gave ${owner}, so it is never ${act}`,
  })
  switch await api.running(name) {
  | Ok(Some({tag: Some(tag)})) if tag->String.startsWith(`${install}/${owner}/`) => Ok()
  | Ok(Some(_)) => refused()
  | Ok(None) =>
    switch await exists(name) {
    | Ok(false) => Ok()
    | Ok(true) => refused()
    | Error(_) as failed => failed
    }
  | Error(_) as failed => failed
  }
}

/**
 * An account's API on the names the records hold, `held`, and those an organization `listed`; a
 * listed Worker is never deleted and never made, only updated where it is, and a held one is
 * deleted or overwritten only where it carries the tag this install gave `owner`, RFC nrs5v. Each
 * version uploaded is tagged with the install id first, and a tag read back without it is none.
 */
let api = (
  raw: Function.api,
  ~held: array<string>,
  ~listed: array<string>,
  ~exists: exists,
  ~install: string,
  ~owner: string,
): Function.api => {
  let prefix = `${install}/`
  let api = {
    ...raw,
    // The whole tag is held to Cloudflare's 100 bytes, refused rather than cut past them.
    upload: (name, upload) =>
      switch prefix ++ upload.tag {
      | tag if String.length(tag) <= tagLength => raw.upload(name, {...upload, tag})
      | tag =>
        Promise.resolve(
          Error({
            Function.reason: "fault",
            message: `the tag ${tag} is past the ${Int.toString(tagLength)} bytes a tag holds`,
          }),
        )
      },
    running: async name =>
      (await raw.running(name))->Result.map(running =>
        running->Option.map((running): Function.running => {
          ...running,
          tag: running.tag->Option.flatMap(
            tag =>
              tag->String.startsWith(prefix)
                ? Some(tag->String.slice(~start=String.length(prefix)))
                : None,
          ),
        })
      ),
  }
  let may = name => held->Array.includes(name) || listed->Array.includes(name)
  let through = async (name, act) => may(name) ? await act(name) : unheld(name)
  let upload = async (name, upload) =>
    if listed->Array.includes(name) {
      switch await exists(name) {
      | Ok(true) => await api.upload(name, upload)
      | Ok(false) =>
        Error({
          Function.reason: "beyond_host",
          message: `${name} is listed but no Worker on the account, and adoption never makes one`,
        })
      | Error(_) as refused => refused
      }
    } else if held->Array.includes(name) {
      switch await carries(raw, name, ~install, ~owner, ~exists, ~act="overwritten") {
      | Ok() => await api.upload(name, upload)
      | Error(_) as refused => refused
      }
    } else {
      unheld(name)
    }
  let delete = async name =>
    switch (held->Array.includes(name), listed->Array.includes(name)) {
    | (true, false) =>
      switch await carries(raw, name, ~install, ~owner, ~exists, ~act="deleted") {
      | Ok() => await api.delete(name)
      | Error(_) as refused => refused
      }
    | (_, true) =>
      Error({
        Function.reason: "fault",
        message: `${name} is the organization's own, so it is never deleted`,
      })
    | (false, false) => unheld(name)
    }
  {
    upload,
    deploy: (name, version) => through(name, name => api.deploy(name, version)),
    running: name => through(name, name => api.running(name)),
    delete,
    address: name => through(name, name => api.address(name)),
  }
}
