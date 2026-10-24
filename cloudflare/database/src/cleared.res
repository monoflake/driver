/***
 * The database emptied for a new item, every table, index, view and trigger a user made dropped in
 * one batch, none of D1's own named `_cf_` nor SQLite's named `sqlite_`, RFC nrs5v.
 */
open Stores

type made = {kind: string, name: string}

/** What a user made, views and triggers first, a virtual table before the tables beneath it. */
let listing = [
  "SELECT type AS kind, name FROM sqlite_master",
  "WHERE type IN ('table', 'index', 'view', 'trigger')",
  "AND substr(name, 1, 4) != '_cf_' AND substr(name, 1, 7) != 'sqlite_'",
  "ORDER BY CASE type WHEN 'trigger' THEN 0 WHEN 'view' THEN 1 WHEN 'index' THEN 2",
  "ELSE CASE WHEN sql LIKE 'CREATE VIRTUAL%' THEN 3 ELSE 4 END END, name",
]->Array.join(" ")

/** A name quoted as SQLite reads an identifier. */
let quoted = name => `"${name->String.replaceAll(`"`, `""`)}"`

let dropOf = (made: made) =>
  switch made.kind {
  | "trigger" => Some("DROP TRIGGER IF EXISTS")
  | "view" => Some("DROP VIEW IF EXISTS")
  | "index" => Some("DROP INDEX IF EXISTS")
  | "table" => Some("DROP TABLE IF EXISTS")
  | _ => None
  }->Option.map(drop => `${drop} ${quoted(made.name)}`)

/**
 * Everything a user made dropped, the foreign keys checked once the batch is done, so a table one
 * names goes with the rest; the database's size after, or its size where nothing was there.
 */
let clear = async database => {
  let found: rows<made> = await database->prepare(listing)->bind([])->all
  let drops = found.results->Array.filterMap(dropOf)
  let statements =
    ["PRAGMA defer_foreign_keys = true", ...drops]->Array.map(sql =>
      database->prepare(sql)->bind([])
    )
  let ran = await database->batch(statements)
  ran->Array.at(-1)->Option.mapOr(0., ran => ran.meta.sizeAfter)
}
