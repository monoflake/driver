/***
 * driver(cloudflare)'s management, the list the control sends whole by generation, its grace and
 * the binding's tokens, kept in the driver's D1, RFCs vr5lw and nrs5v. This file is its interface.
 */

/** Why a call answered nothing, a reason the management contract names and its message. */
type refused = {reason: string, message: string}

/** What an item holds, cores in thousandths and every size in bytes. */
type capacity =
  | Container({millicores: int, memory: float})
  | Volume({size: float})
  | Object({size: float})
  | Database({size: float})

/** An item of the list, by its `capacity` id, its credentials each a BLAKE3 in hex. */
type item = {id: float, capacity: capacity, credentials: array<string>}

/** Where an item stands, `since` the time in milliseconds it was first found unasked. */
type state =
  | Making
  | Made({address: string})
  | Failed({reason: string, message?: string})
  | Unasked({since: float, address?: string})

/** An item of the list as it is kept, with where it stands. */
type keptItem = {item: item, state: state}

/** What the management keeps, its generations, its grace in seconds, its items and its tokens. */
type kept = {
  generation: float,
  policy: float,
  grace: int,
  items: array<keptItem>,
  tokens: option<array<string>>,
}

/** Where it is kept, read and written whole, the driver's D1 `held`, `items` and `tokens`. */
type store = {read: unit => promise<kept>, write: kept => promise<unit>}

/**
 * The list taken where its generation is not behind, `tokens` the binding's in force by hash, and
 * the Workers `object`'s and `database`'s addresses, each asked only where the list holds its item.
 */
let apply: (
  store,
  ~now: float,
  ~generation: float,
  ~items: array<item>,
  ~tokens: option<array<string>>,
  ~objects: unit => promise<result<string, refused>>,
  ~databases: unit => promise<result<string, refused>>,
) => promise<result<float, refused>>

/** The grace taken where its generation is not behind, 0 removing at once and a year at most. */
let setPolicy: (
  store,
  ~now: float,
  ~generation: float,
  ~grace: int,
) => promise<result<float, refused>>

/** What is held now. */
let describe: (store, ~now: float) => promise<kept>

/** An item ended, succeeding where absent, refused as `still_asked` where the list holds it. */
let end_: (store, ~id: float) => promise<result<unit, refused>>

/**
 * Each unasked item whose grace passed by `now` forgotten and answered, as each management request
 * arrives, the store written only where one is.
 */
let sweep: (store, ~now: float) => promise<array<item>>

/**
 * Whether a token's secret by its BLAKE3 in hex is held, compared in constant time, `given` the
 * secret `BINDING` until an apply names the tokens.
 */
let holds: (store, ~given: string, string) => promise<bool>
