/***
 * Whether a Worker is on the account, by a read of its script, `GET /workers/scripts/{name}`, gone
 * only where it answers code 10007, never by what it runs, RFC nrs5v's Ledger.
 * https://developers.cloudflare.com/api/resources/workers/subresources/scripts/methods/get/
 */
module Function = DriverCloudflareFunction.Function
module Thrown = DriverCloudflareFunction.Thrown

let origin = "https://api.cloudflare.com/client/v4"

/** Cloudflare's code for a Worker not found. */
let notFound = 10007.

let member = (json, key) =>
  json->JSON.Decode.object->Option.flatMap(fields => fields->Dict.get(key))

/** Each error code an answer names. */
let codesOf = text =>
  switch JSON.parseOrThrow(text) {
  | json =>
    json
    ->member("errors")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.getOr([])
    ->Array.filterMap(error => error->member("code")->Option.flatMap(JSON.Decode.float))
  | exception JsExn(_) => []
  }

let fault = message => Error({Function.reason: "fault", message})

/** Whether the account holds a Worker by its name, its script's body never read. */
let exists = async (~accountId, ~token, name) => {
  let account = Web.encodeURIComponent(accountId)
  let url = `${origin}/accounts/${account}/workers/scripts/${Web.encodeURIComponent(name)}`
  switch await Web.send(url, {method: "GET", headers: dict{"authorization": `Bearer ${token}`}}) {
  | response if response->Web.status >= 200 && response->Web.status < 300 =>
    switch response->Web.body->Nullable.toOption {
    | Some(stream) =>
      switch await stream->Web.discard {
      | () => ()
      | exception JsExn(_) => ()
      }
    | None => ()
    }
    Ok(true)
  | response =>
    let status = Int.toString(response->Web.status)
    let unknown = `whether ${name} is on the account is not known`
    // A body that cannot be read is a fault the caller answers, never a throw past it.
    switch await response->Web.text {
    | text if codesOf(text)->Array.includes(notFound) => Ok(false)
    | _ => fault(`${unknown}, Cloudflare's API answered ${status}`)
    | exception JsExn(_) => fault(`${unknown}, its answer of ${status} was not read`)
    }
  | exception JsExn(e) =>
    fault(Thrown.told("Cloudflare's API was not reached", e, ~account=accountId, ~token))
  }
}
