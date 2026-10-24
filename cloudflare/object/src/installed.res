/*** The install id install gives the Worker beside its bindings, RFC nrs5v's Ledger. */

let idForm = /^[0-9a-f]{8}$/

/** Whether the install id given is 8 lowercase hex digits, a Worker installed whole. */
let whole = env => Vars.read(env).installId->Option.mapOr(false, id => idForm->RegExp.test(id))
