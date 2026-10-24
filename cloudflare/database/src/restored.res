/***
 * The database restored by D1 Time Travel, as https://developers.cloudflare.com/api/resources/d1/
 * subresources/database/subresources/time_travel/methods/restore/ documents it, RFC nrs5v.
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
    let status = response->Web.status
    let text = await response->Web.text
    let json = try Some(JSON.parseOrThrow(text)) catch {
    | JsExn(_) => None
    }
    let success = json->Option.flatMap(j => j->member("success"))->Option.flatMap(JSON.Decode.bool)
    switch success {
    | Some(true) if status >= 200 && status < 300 => Ok()
    | Some(_) | None =>
      let errors = json->Option.mapOr("", said)
      let after = errors == "" ? "" : `, ${errors}`
      Error(`Time Travel's restore answered ${Int.toString(status)}${after}`)
    }
  | exception JsExn(_) => Error("Cloudflare's API was not reached")
  }
}
