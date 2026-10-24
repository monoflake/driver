/***
 * The database named by its id and restored by D1 Time Travel, as the pages below document them,
 * RFC nrs5v.
 * https://developers.cloudflare.com/api/resources/d1/subresources/database/methods/get/
 * https://developers.cloudflare.com/api/resources/d1/subresources/database/subresources/time_travel/methods/restore/
 */

let origin = "https://api.cloudflare.com/client/v4"

let member = (json, key) =>
  json->JSON.Decode.object->Option.flatMap(fields => fields->Dict.get(key))

/** Each error an answer names, its code before its message. */
let said = json =>
  json
  ->member("errors")
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])
  ->Array.map(error => {
    let code = error->member("code")->Option.flatMap(JSON.Decode.float)
    let message = error->member("message")->Option.flatMap(JSON.Decode.string)->Option.getOr("")
    `${code->Option.mapOr("", c => Float.toString(c) ++ " ")}${message}`
  })
  ->Array.join("; ")

/** The address of one database of one account, as its get reads it. */
let databaseAddress = (~accountId, ~databaseId) => {
  let account = Web.encodeURIComponent(accountId)
  let database = Web.encodeURIComponent(databaseId)
  `${origin}/accounts/${account}/d1/database/${database}`
}

/** An answer's JSON and whether it says it succeeded, none where it is not JSON. */
let read = async response => {
  let status = response->Web.status
  let text = await response->Web.text
  let json = try Some(JSON.parseOrThrow(text)) catch {
  | JsExn(_) => None
  }
  let success = json->Option.flatMap(j => j->member("success"))->Option.flatMap(JSON.Decode.bool)
  let failed = what => {
    let errors = json->Option.mapOr("", said)
    let after = errors == "" ? "" : `, ${errors}`
    Error(`${what} answered ${Int.toString(status)}${after}`)
  }
  (success == Some(true) && status >= 200 && status < 300, json, failed)
}

/** The name the account gives a database by its id, as D1's get documents it. */
let nameOf = async (~accountId, ~databaseId, ~token) => {
  let headers = dict{"authorization": `Bearer ${token}`}
  switch await Web.send(databaseAddress(~accountId, ~databaseId), {method: "GET", headers}) {
  | response =>
    switch await read(response) {
    | (true, json, _) =>
      switch json
      ->Option.flatMap(j => j->member("result"))
      ->Option.flatMap(r => r->member("name"))
      ->Option.flatMap(JSON.Decode.string) {
      | Some(name) => Ok(name)
      | None => Error("D1's get answered no database's name")
      }
    | (false, _, failed) => failed("D1's get")
    }
  | exception JsExn(_) => Error("Cloudflare's API was not reached")
  }
}

/** The address restoring one database of one account to a moment in milliseconds. */
let address = (~accountId, ~databaseId, ~to) => {
  let account = Web.encodeURIComponent(accountId)
  let database = Web.encodeURIComponent(databaseId)
  let timestamp = Web.encodeURIComponent(Date.fromTime(to)->Date.toISOString)
  `${origin}/accounts/${account}/d1/database/${database}/time_travel/restore?timestamp=${timestamp}`
}

/** The database restored to `to`, or why Cloudflare's API did not, as its answer says. */
let restore = async (~accountId, ~databaseId, ~token, ~to) => {
  let url = address(~accountId, ~databaseId, ~to)
  let headers = dict{"authorization": `Bearer ${token}`}
  switch await Web.send(url, {method: "POST", headers}) {
  | response =>
    switch await read(response) {
    | (true, _, _) => Ok()
    | (false, _, failed) => failed("Time Travel's restore")
    }
  | exception JsExn(_) => Error("Cloudflare's API was not reached")
  }
}
