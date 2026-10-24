/***
 * The secret a call's bearer token carries, `<id>.<secret>`, held by the BLAKE3 of its 32 bytes, as
 * driver(machine)'s `management/src/tokens.rs` reads it, RFC 3d3nt.
 */

/** A binding's id, decimal digits with no leading zero. */
let id = /^(0|[1-9][0-9]*)$/

/** The BLAKE3 in hex of the secret an `Authorization` header's bearer token carries, if any. */
let hashOf = authorization =>
  authorization->Option.flatMap(header =>
    switch header->String.indexOf(" ") {
    | -1 => None
    | space if header->String.slice(~start=0, ~end=space)->String.toLowerCase == "bearer" =>
      switch header->String.slice(~start=space + 1)->String.split(".") {
      | [binding, secret] if id->RegExp.test(binding) && String.length(secret) == 43 =>
        Envelope.Base64url.decode(secret)
        ->Option.filter(bytes => TypedArray.length(bytes) == 32)
        ->Option.map(bytes => Envelope.Hex.encode(Keys.Hash.plain(bytes)))
      | _ => None
      }
    | _ => None
    }
  )
