/*** The install id install gives the Worker beside its bindings, RFC nrs5v's Ledger. */

let idForm = /^[0-9a-f]{8}$/

/** The install id given, or why install is broken, its message naming the variable. */
let idOf = (given: option<string>) =>
  switch given {
  | Some(id) if idForm->RegExp.test(id) => Ok(id)
  | Some(_) | None => Error("INSTALL_ID is unset or not 8 lowercase hex digits, so install broke")
  }
