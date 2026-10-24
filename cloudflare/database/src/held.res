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
 * apply names the tokens, as the management's `holds` reads them.
 */
let holds = async (db, ~given, hash) => {
  let held: option<heldRow> =
    (await db->prepare("SELECT listed FROM held WHERE one = 1")->bind([])->first)->Nullable.toOption
  let tokens = switch held {
  | Some({listed}) if listed == 1. =>
    let rows: rows<tokenRow> = await db->prepare("SELECT hash FROM tokens")->bind([])->all
    rows.results->Array.map(t => t.hash)
  | Some(_) => [given]
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

/** Which item the database is held for, since when in milliseconds, and its size after a batch. */
type held = {item: float, since: float, size: float}

/** What `database_held` records, none before the database was first held for an item. */
let held = async db => {
  let sql = "SELECT item, since, size FROM database_held WHERE one = 1"
  let row: option<held> = (await db->prepare(sql)->bind([])->first)->Nullable.toOption
  row
}

/** The database recorded as held for an item since a moment, at a size. */
let hold = async (db, held: held) => {
  let sql =
    [
      "INSERT INTO database_held (one, item, since, size) VALUES (1, ?, ?, ?)",
      "ON CONFLICT (one) DO UPDATE SET item = excluded.item, since = excluded.since,",
      "size = excluded.size",
    ]->Array.join(" ")
  ignore(
    await db
    ->prepare(sql)
    ->bind([Number(held.item), Number(held.since), Number(held.size)])
    ->run,
  )
}

/** The database's size after a batch, recorded only while it is held for that item still. */
let sized = async (db, ~item, size) => {
  let sql = "UPDATE database_held SET size = ? WHERE one = 1 AND item = ?"
  ignore(await db->prepare(sql)->bind([Number(size), Number(item)])->run)
}
