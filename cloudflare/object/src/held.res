/***
 * What the Worker reads and writes of the driver's D1, the binding's tokens, its one `object` item
 * and what the bucket holds, counted in `objects` by `migrations/`, RFC nrs5v.
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

/** The item holding the bucket, by its id and its size in bytes. */
type item = {id: float, size: float}

/** An item that holds the bucket, made, or unasked once made and so within its grace. */
let holding = [
  "SELECT id, bytes FROM items WHERE kind = 'object'",
  "AND (state = 'made' OR (state = 'unasked' AND address IS NOT NULL)) ORDER BY id LIMIT 1",
]->Array.join(" ")

/** The one `object` item, none where the list holds none. */
let item = async db => {
  let row: option<itemRow> = (await db->prepare(holding)->bind([])->first)->Nullable.toOption
  row->Option.map(row => {id: row.id, size: row.bytes})
}

/** The prefix an item's keys stand under, its id and `/`, so no item sees another's objects. */
let prefixOf = (id: float) => `${Float.toString(id)}/`

/** An object counted at a size, written or replaced in one statement, so it is one transaction. */
let taking = [
  "INSERT INTO objects (item, name, size) SELECT ?, ?, ?",
  "WHERE (SELECT coalesce(sum(size), 0) FROM objects WHERE item = ? AND name != ?) + ? <= ?",
  "ON CONFLICT (item, name) DO UPDATE SET size = excluded.size",
]->Array.join(" ")

/** An object counted at its size where the item's others beside it stay within its size, if so. */
let take = async (db, ~item: item, ~name, ~size) => {
  let ran = await db
  ->prepare(taking)
  ->bind([
    Number(item.id),
    Text(name),
    Number(size),
    Number(item.id),
    Text(name),
    Number(size),
    Number(item.size),
  ])
  ->run
  ran.meta.changes > 0.
}

type sizeRow = {size: float}

/** The size an object is counted at, none where it is not counted. */
let counted = async (db, ~item, name) => {
  let sql = "SELECT size FROM objects WHERE item = ? AND name = ?"
  let row: option<sizeRow> =
    (await db->prepare(sql)->bind([Number(item), Text(name)])->first)->Nullable.toOption
  row->Option.map(row => row.size)
}

/** An object no longer counted. */
let forget = async (db, ~item, name) =>
  ignore(
    await db
    ->prepare("DELETE FROM objects WHERE item = ? AND name = ?")
    ->bind([Number(item), Text(name)])
    ->run,
  )

/** An object counted at the size R2 holds for its key, or no longer counted where it holds none. */
let settle = async (db, ~item, ~name, size) =>
  switch size {
  | Some(size) =>
    let put =
      [
        "INSERT INTO objects (item, name, size) VALUES (?, ?, ?)",
        "ON CONFLICT (item, name) DO UPDATE SET size = excluded.size",
      ]->Array.join(" ")
    ignore(await db->prepare(put)->bind([Number(item), Text(name), Number(size)])->run)
  | None => await forget(db, ~item, name)
  }

type idRow = {id: float}

/** The id of every item `items` holds, in whatever state it stands. */
let ids = async db => {
  let rows: rows<idRow> = await db->prepare("SELECT id FROM items")->bind([])->all
  rows.results->Array.map(row => row.id)
}

/** The objects of an item no longer counted, by their names in one statement. */
let forgetAll = async (db, ~item, names: array<string>) => {
  let names = JSON.stringify(JSON.Array(names->Array.map(name => JSON.String(name))))
  let sql = "DELETE FROM objects WHERE item = ? AND name IN (SELECT value FROM json_each(?))"
  ignore(await db->prepare(sql)->bind([Number(item), Text(names)])->run)
}

/**
 * At most `limit` rows of items absent from `items` forgotten, how many, in one statement, so a row
 * is read beside the items as they stand at one moment.
 */
let forgetStale = async (db, ~limit) => {
  let sql =
    [
      "DELETE FROM objects WHERE rowid IN (SELECT rowid FROM objects",
      "WHERE item NOT IN (SELECT id FROM items) LIMIT ?)",
    ]->Array.join(" ")
  (await db->prepare(sql)->bind([Number(Int.toFloat(limit))])->run).meta.changes
}
