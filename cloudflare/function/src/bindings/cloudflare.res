/***
 * The calls the function kind makes of Cloudflare's API for one account, its Workers' scripts,
 * versions and deployments and its workers.dev subdomain, as https://developers.cloudflare.com/api/
 * documents them.
 */
open Script

let origin = "https://api.cloudflare.com/client/v4"

/** What Cloudflare's code 10007 names, a Worker or a workers.dev subdomain not found. */
let notFound = 10007.

let fault = message => {reason: "fault", message}

/** What a call answered, its result, nothing of that name, or why it failed. */
type outcome = Done(JSON.t) | Absent | Failed(string)

let member = (json, key) =>
  json->JSON.Decode.object->Option.flatMap(fields => fields->Dict.get(key))

/** Each error Cloudflare answered, by its code and its message. */
let errorsOf = json =>
  json
  ->member("errors")
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])
  ->Array.map(error => (
    error->member("code")->Option.flatMap(JSON.Decode.float),
    error->member("message")->Option.flatMap(JSON.Decode.string)->Option.getOr(""),
  ))

/** An answer's outcome, by its status and its envelope's `success`, `errors` and `result`. */
let outcomeOf = (status, text) => {
  let json = try Some(JSON.parseOrThrow(text)) catch {
  | JsExn(_) => None
  }
  let errors = json->Option.mapOr([], errorsOf)
  let success = json->Option.flatMap(j => j->member("success"))->Option.flatMap(JSON.Decode.bool)
  switch (success, json->Option.flatMap(j => j->member("result"))) {
  | (Some(true), Some(result)) if status >= 200 && status < 300 => Done(result)
  | _ if status == 404 || errors->Array.some(((code, _)) => code == Some(notFound)) => Absent
  | _ =>
    let said =
      errors
      ->Array.map(((code, message)) =>
        `${code->Option.mapOr("", c => Float.toString(c) ++ " ")}${message}`
      )
      ->Array.join("; ")
    Failed(`Cloudflare's API answered ${Int.toString(status)}${said == "" ? "" : `, ${said}`}`)
  }
}

/** The API of one account, its requests sent by `send`. */
type account = {send: Web.send, accountId: string, token: string}

let call = async (account, ~method, path, ~form=?, ~json=?) => {
  let headers = dict{"authorization": `Bearer ${account.token}`}
  let body = switch (form, json) {
  | (Some(form), _) => Some(Web.formBody(form))
  | (None, Some(json)) =>
    headers->Dict.set("content-type", "application/json")
    Some(Web.textBody(JSON.stringify(json)))
  | (None, None) => None
  }
  let url = `${origin}/accounts/${Web.encodeURIComponent(account.accountId)}${path}`
  switch await account.send(url, {method, headers, ?body}) {
  | response => outcomeOf(response->Web.status, await response->Web.text)
  | exception JsExn(_) => Failed("Cloudflare's API was not reached")
  }
}

let script = name => `/workers/scripts/${Web.encodeURIComponent(name)}`

/** The type a module is uploaded as, none for JSON, which Cloudflare's upload takes no type of. */
let contentType = kind =>
  switch kind {
  | Es => Some("application/javascript+module")
  | CommonJs => Some("application/javascript")
  | Wasm => Some("application/wasm")
  | Text => Some("text/plain")
  | Data => Some("application/octet-stream")
  | Json => None
  }

let boundJson = bound =>
  switch bound {
  | PlainText({name, text}) =>
    dict{"type": JSON.String("plain_text"), "name": JSON.String(name), "text": JSON.String(text)}
  | SecretText({name, text}) =>
    dict{"type": JSON.String("secret_text"), "name": JSON.String(name), "text": JSON.String(text)}
  }->JSON.Object

/**
 * The multipart form of an upload, its `metadata` part as
 * https://developers.cloudflare.com/workers/configuration/multipart-upload-metadata/ writes it.
 */
let formOf = (bundle, ~bindings, ~tag) => {
  let metadata = dict{
    "main_module": JSON.String(bundle.modules->Array.get(0)->Option.mapOr("", m => m.name)),
    "bindings": JSON.Array(bindings->Array.map(boundJson)),
    "compatibility_date": JSON.String(bundle.compatibilityDate),
    "compatibility_flags": JSON.Array(bundle.compatibilityFlags->Array.map(f => JSON.String(f))),
  }
  tag->Option.forEach(tag =>
    metadata->Dict.set("annotations", JSON.Object(dict{"workers/tag": JSON.String(tag)}))
  )
  let form = Web.form()
  form->Web.append("metadata", JSON.stringify(JSON.Object(metadata)))
  bundle.modules->Array.forEach(m =>
    form->Web.appendFile(
      m.name,
      Web.blob([m.bytes], {type_: contentType(m.kind)->Option.getOr("")}),
      m.name,
    )
  )
  form
}

let idOf = result => result->member("id")->Option.flatMap(JSON.Decode.string)

/** The Worker made with the stub answering stopped, and served at its workers.dev address. */
let made = async (account, name) =>
  switch await call(
    account,
    ~method="PUT",
    script(name),
    ~form=formOf(Stopped.bundle, ~bindings=[], ~tag=None),
  ) {
  | Done(_) =>
    let json = JSON.Object(dict{"enabled": JSON.Boolean(true)})
    switch await call(account, ~method="POST", `${script(name)}/subdomain`, ~json) {
    | Done(_) => Ok()
    | Absent => Error(fault(`the Worker ${name} was made and then not found`))
    | Failed(why) => Error(fault(why))
    }
  | Absent => Error(fault(`the Worker ${name} could not be made`))
  | Failed(why) => Error(fault(why))
  }

let uploaded = async (account, name, upload) => {
  let send = () =>
    call(
      account,
      ~method="POST",
      `${script(name)}/versions`,
      ~form=formOf(upload.bundle, ~bindings=upload.bindings, ~tag=Some(upload.tag)),
    )
  let versioned = outcome =>
    switch outcome {
    | Done(result) =>
      idOf(result)->Option.mapOr(Error(fault("an uploaded version names no id")), id => Ok(id))
    | Absent => Error(fault(`the Worker ${name} was not found`))
    | Failed(why) => Error(fault(why))
    }
  switch upload.bundle.modules->Array.find(m => contentType(m.kind) == None) {
  | Some(m) =>
    Error({
      reason: "beyond_host",
      message: `${m.name}: Cloudflare's upload takes no JSON module`,
    })
  | None =>
    switch await send() {
    | Absent =>
      switch await made(account, name) {
      | Ok() => versioned(await send())
      | Error(_) as refused => refused
      }
    | (Done(_) | Failed(_)) as outcome => versioned(outcome)
    }
  }
}

let deployed = async (account, name, id) => {
  let json = JSON.Object(
    dict{
      "strategy": JSON.String("percentage"),
      "versions": JSON.Array([
        JSON.Object(dict{"percentage": JSON.Number(100.), "version_id": JSON.String(id)}),
      ]),
    },
  )
  switch await call(account, ~method="POST", `${script(name)}/deployments`, ~json) {
  | Done(_) => Ok()
  | Absent => Error(fault(`the Worker ${name} was not found`))
  | Failed(why) => Error(fault(why))
  }
}

/** The version most of the latest deployment's requests reach, the latest listed first. */
let versionOf = deployments =>
  deployments
  ->member("deployments")
  ->Option.flatMap(JSON.Decode.array)
  ->Option.flatMap(listed => listed->Array.get(0))
  ->Option.flatMap(latest => latest->member("versions"))
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])
  ->Array.reduce(None, (most, version) => {
    let percentage =
      version->member("percentage")->Option.flatMap(JSON.Decode.float)->Option.getOr(0.)
    switch (version->member("version_id")->Option.flatMap(JSON.Decode.string), most) {
    | (Some(id), None) => Some((id, percentage))
    | (Some(id), Some((_, before))) if percentage > before => Some((id, percentage))
    | (Some(_), Some(_)) | (None, _) => most
    }
  })
  ->Option.map(((id, _)) => id)

let tagOf = version =>
  version
  ->member("annotations")
  ->Option.flatMap(annotations => annotations->member("workers/tag"))
  ->Option.flatMap(JSON.Decode.string)

let ran = async (account, name) =>
  switch await call(account, ~method="GET", `${script(name)}/deployments`) {
  | Absent => Ok(None)
  | Failed(why) => Error(fault(why))
  | Done(deployments) =>
    switch versionOf(deployments) {
    | None => Ok(None)
    | Some(id) =>
      // The scripts' own version answer documents no annotations, so the tag is read here.
      let path = `/workers/workers/${Web.encodeURIComponent(
          name,
        )}/versions/${Web.encodeURIComponent(id)}`
      switch await call(account, ~method="GET", path) {
      | Done(version) => Ok(Some({id, tag: tagOf(version)}))
      | Absent => Ok(None)
      | Failed(why) => Error(fault(why))
      }
    }
  }

let deleted = async (account, name) =>
  switch await call(account, ~method="DELETE", script(name)) {
  | Done(_) | Absent => Ok()
  | Failed(why) => Error(fault(why))
  }

let subdomain = async account =>
  switch await call(account, ~method="GET", "/workers/subdomain") {
  | Done(result) =>
    switch result->member("subdomain")->Option.flatMap(JSON.Decode.string) {
    | Some(subdomain) => Ok(subdomain)
    | None => Error(fault("the account's workers.dev subdomain is named nowhere"))
    }
  | Absent => Error(fault("the account has no workers.dev subdomain"))
  | Failed(why) => Error(fault(why))
  }

let api = (~send, ~accountId, ~token): api => {
  let account = {send, accountId, token}
  {
    upload: (name, upload) => uploaded(account, name, upload),
    deploy: (name, id) => deployed(account, name, id),
    running: name => ran(account, name),
    delete: name => deleted(account, name),
    subdomain: () => subdomain(account),
  }
}
