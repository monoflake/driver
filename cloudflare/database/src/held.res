/***
 * What the Worker reads and writes of the driver's D1, the binding's tokens, its one `database`
 * item and which item the database is held for, in `database_held` by `migrations/`, RFC nrs5v.
 */
open Stores

exception Unkept(string)

type heldRow = {listed: float}
type tokenRow = {hash: string}

/** Whether two texts are one, every character read, so the time it takes names no match. */
let same = (a, b) => {
  let code = (text, at) =>
    text->String.charCodeAt(Int.mod(at, Math.Int.max(1, String.length(text))))->Option.getOr(0)
  let differ = ref(String.length(a) == String.length(b) ? 0 : 1)
  for at in 0 to Math.Int.max(String.length(a), String.length(b)) - 1 {
    differ := differ.contents ||| code(a, at) ^^^ code(b, at)
  }
  differ.contents == 0
}

/**
 * Whether a token's secret by its BLAKE3 in hex is held, `given` the secret `BINDING` until an
 * apply names the tokens, as the management's `holds` reads them, none where `BINDING` is unset.
 */
let holds = async (db, ~given, hash) => {
  let held: option<heldRow> =
    (await db->prepare("SELECT listed FROM held WHERE one = 1")->bind([])->first)->Nullable.toOption
  let tokens = switch held {
  | Some({listed}) if listed == 1. =>
    let rows: rows<tokenRow> = await db->prepare("SELECT hash FROM tokens")->bind([])->all
    rows.results->Array.map(t => t.hash)
  | Some(_) => given->Option.mapOr([], given => [given])
  | None => throw(Unkept("the driver's D1 holds no row of held, as its migrations write"))
  }
  tokens->Array.reduce(false, (found, held) => same(held, hash) || found)
}

type itemRow = {id: float, bytes: float}

/** The item holding the database, by its id and its size in bytes. */
type item = {id: float, size: float}

/** An item that holds the database, made, or unasked once made and so within its grace. */
let holding = [
  "SELECT id, bytes FROM items WHERE kind = 'database'",
  "AND (state = 'made' OR (state = 'unasked' AND address IS NOT NULL)) ORDER BY id LIMIT 1",
]->Array.join(" ")

/** The one `database` item, none where the list holds none. */
let item = async db => {
  let row: option<itemRow> = (await db->prepare(holding)->bind([])->first)->Nullable.toOption
  row->Option.map(row => {id: row.id, size: row.bytes})
}

/** How long a call emptying the database holds it before another may take its lease over. */
let lease = 30_000.

/**
 * Which item the database is held for, since when in milliseconds it was emptied, its size after a
 * batch, whether it was emptied, and since when the call emptying it held its lease.
 */
type held = {item: float, since: float, size: float, cleared: bool, clearingSince: float}

type heldRecord = {
  item: float,
  since: float,
  size: float,
  cleared: float,
  @as("clearing_since") clearingSince: float,
}

/** What `database_held` records, none before the database was first held for an item. */
let held = async db => {
  let sql = "SELECT item, since, size, cleared, clearing_since FROM database_held WHERE one = 1"
  let row: option<heldRecord> = (await db->prepare(sql)->bind([])->first)->Nullable.toOption
  row->Option.map((row): held => {
    item: row.item,
    since: row.since,
    size: row.size,
    cleared: row.cleared == 1.,
    clearingSince: row.clearingSince,
  })
}

/**
 * The database taken for an item from the one `was` recorded, none for none, its lease from `now`,
 * and whether this call took it, so only one call of several clears it.
 */
let handed = async (db, ~was, ~item, ~now) => {
  let sql =
    [
      "INSERT INTO database_held (one, item, since, size, cleared, clearing_since)",
      "VALUES (1, ?, ?, 0, 0, ?) ON CONFLICT (one) DO UPDATE SET item = excluded.item,",
      "cleared = 0, clearing_since = excluded.clearing_since WHERE database_held.item IS ?",
    ]->Array.join(" ")
  let was = was->Option.mapOr(Null, item => Number(item))
  let ran = await db->prepare(sql)->bind([Number(item), Number(now), Number(now), was])->run
  ran.meta.changes > 0.
}

/** A lease taken from one that passed, `was` its start as read, and whether this call took it. */
let leased = async (db, ~item, ~was, ~now) => {
  let sql =
    [
      "UPDATE database_held SET clearing_since = ?",
      "WHERE one = 1 AND item = ? AND cleared = 0 AND clearing_since = ?",
    ]->Array.join(" ")
  let ran = await db->prepare(sql)->bind([Number(now), Number(item), Number(was)])->run
  ran.meta.changes > 0.
}

/** The database recorded emptied for an item while the lease is still this call's, and whether. */
let cleared = async (db, ~item, ~lease, ~since, ~size) => {
  let sql =
    [
      "UPDATE database_held SET cleared = 1, since = ?, size = ?",
      "WHERE one = 1 AND item = ? AND cleared = 0 AND clearing_since = ?",
    ]->Array.join(" ")
  let ran = await db
  ->prepare(sql)
  ->bind([Number(since), Number(size), Number(item), Number(lease)])
  ->run
  ran.meta.changes > 0.
}

/** The database's size after a batch, recorded only while it is held for that item still. */
let sized = async (db, ~item, size) => {
  let sql = "UPDATE database_held SET size = ? WHERE one = 1 AND item = ? AND cleared = 1"
  ignore(await db->prepare(sql)->bind([Number(size), Number(item)])->run)
}
