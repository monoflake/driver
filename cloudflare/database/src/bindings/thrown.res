/*** A fault's fixed text told with the class and the message of the throw behind it. */

/** Whether a throw is an Error, the one kind whose class and message are told. */
let isError: JsExn.t => bool = %raw(`thrown => thrown instanceof Error`)

/** The most of a throw's class and message a fault keeps. */
let longest = 200

/** Each value given and its trimmed form, as a header echoes it, beside its placeholder. */
let heldOf = (value, placeholder) =>
  switch value {
  | Some(value) =>
    [value, String.trim(value)]
    ->Array.filter(held => held != "")
    ->Array.map(held => (held, placeholder))
  | None => []
  }

/**
 * A fault's fixed text, then the class and the message of the throw behind it, each URL of an http
 * or https scheme, the account id and the token given replaced and that detail cut to `longest`.
 * A throw that is no Error, or tells neither, leaves the text alone.
 */
let told = (text, thrown, ~account=?, ~token=?) => {
  let parts =
    [thrown->JsExn.name, thrown->JsExn.message]->Array.filterMap(part =>
      part->Option.filter(said => said != "")
    )
  if !isError(thrown) || Array.length(parts) == 0 {
    text
  } else {
    // The longer first, so a trimmed value never splits the whole it stands in.
    let longer = ((a, _), (b, _)) => Int.toFloat(String.length(b) - String.length(a))
    let held =
      [...heldOf(account, "<account>"), ...heldOf(token, "<token>")]->Array.toSorted(longer)
    let detail =
      held->Array.reduce(
        parts->Array.join(": ")->String.replaceRegExp(/https?:\S+/gi, "<address>"),
        (detail, (value, placeholder)) => detail->String.replaceAll(value, placeholder),
      )
    `${text}, ${detail->String.slice(~start=0, ~end=longest)}`
  }
}
