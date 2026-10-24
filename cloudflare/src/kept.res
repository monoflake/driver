/***
 * What the management and the function kind keep, in the driver's D1 by `migrations/`, the list
 * read and written whole, each write one batch and so one transaction, RFC nrs5v.
 */
open Stores
module Management = DriverCloudflareManagement.Management
module Function = DriverCloudflareFunction.Function

type heldRow = {generation: float, policy: float, grace: float, listed: float}

type itemRow = {
  id: float,
  kind: string,
  millicores: Nullable.t<float>,
  bytes: float,
  credentials: string,
  state: string,
  address: Nullable.t<string>,
  reason: Nullable.t<string>,
  message: Nullable.t<string>,
  since: Nullable.t<float>,
}

type tokenRow = {hash: string}

/** An item's columns, in the order `rowOf` binds them. */
let columns = "id, kind, millicores, bytes, credentials, state, address, reason, message, since"

exception Unkept(string)

let text = value => value->Option.mapOr(Null, v => Text(v))
let number = value => value->Option.mapOr(Null, v => Number(v))

let capacityOf = (row: itemRow): Management.capacity =>
  switch row.kind {
  | "container" =>
    Container({
      millicores: row.millicores->Nullable.toOption->Option.getOr(0.)->Float.toInt,
      memory: row.bytes,
    })
  | "volume" => Volume({size: row.bytes})
  | "object" => Object({size: row.bytes})
  | "database" => Database({size: row.bytes})
  | kind => throw(Unkept(`an item of no kind the driver keeps, ${kind}`))
  }

let stateOf = (row: itemRow): Management.state => {
  let address = row.address->Nullable.toOption
  switch row.state {
  | "making" => Making
  | "made" => Made({address: address->Option.getOr("")})
  | "failed" =>
    Failed({
      reason: row.reason->Nullable.toOption->Option.getOr("fault"),
      message: ?(row.message->Nullable.toOption),
    })
  | "unasked" => Unasked({since: row.since->Nullable.toOption->Option.getOr(0.), ?address})
  | state => throw(Unkept(`an item standing nowhere the driver keeps, ${state}`))
  }
}

let itemOf = (row: itemRow): Management.keptItem => {
  item: {
    id: row.id,
    capacity: capacityOf(row),
    credentials: row.credentials->String.split(" ")->Array.filter(c => c != ""),
  },
  state: stateOf(row),
}

/** An item's row, its columns in the order `migrations/` declares them. */
let rowOf = (k: Management.keptItem) => {
  let (kind, millicores, bytes) = switch k.item.capacity {
  | Container({millicores, memory}) => ("container", Some(Int.toFloat(millicores)), memory)
  | Volume({size}) => ("volume", None, size)
  | Object({size}) => ("object", None, size)
  | Database({size}) => ("database", None, size)
  }
  let (state, address, reason, message, since) = switch k.state {
  | Making => ("making", None, None, None, None)
  | Made({address}) => ("made", Some(address), None, None, None)
  | Failed({reason, ?message}) => ("failed", None, Some(reason), message, None)
  | Unasked({since, ?address}) => ("unasked", address, None, None, Some(since))
  }
  [
    Number(k.item.id),
    Text(kind),
    number(millicores),
    Number(bytes),
    Text(k.item.credentials->Array.join(" ")),
    Text(state),
    text(address),
    text(reason),
    text(message),
    number(since),
  ]
}

let management = (db: database): Management.store => {
  read: async () => {
    let held: option<heldRow> = (
      await db
      ->prepare("SELECT generation, policy, grace, listed FROM held WHERE one = 1")
      ->bind([])
      ->first
    )->Nullable.toOption
    let held = switch held {
    | Some(held) => held
    | None => throw(Unkept("the driver's D1 holds no row of held, as its migrations write"))
    }
    let items: rows<itemRow> = await db
    ->prepare(`SELECT ${columns} FROM items ORDER BY id`)
    ->bind([])
    ->all
    let tokens: rows<tokenRow> = await db
    ->prepare("SELECT hash FROM tokens ORDER BY hash")
    ->bind([])
    ->all
    {
      generation: held.generation,
      policy: held.policy,
      grace: held.grace->Float.toInt,
      items: items.results->Array.map(itemOf),
      tokens: held.listed == 1. ? Some(tokens.results->Array.map(t => t.hash)) : None,
    }
  },
  write: kept =>
    db->batch(
      Array.concatMany(
        [
          db
          ->prepare(
            "UPDATE held SET generation = ?, policy = ?, grace = ?, listed = ? WHERE one = 1",
          )
          ->bind([
            Number(kept.generation),
            Number(kept.policy),
            Number(Int.toFloat(kept.grace)),
            Number(kept.tokens == None ? 0. : 1.),
          ]),
          db->prepare("DELETE FROM items")->bind([]),
          db->prepare("DELETE FROM tokens")->bind([]),
        ],
        [
          kept.items->Array.map(k =>
            db
            ->prepare(`INSERT INTO items (${columns}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
            ->bind(rowOf(k))
          ),
          kept.tokens
          ->Option.getOr([])
          ->Array.map(hash =>
            db->prepare("INSERT INTO tokens (hash) VALUES (?)")->bind([Text(hash)])
          ),
        ],
      ),
    ),
}

/** A deployment written whole, made or replaced. */
let upsert = [
  "INSERT INTO deployments (worker, version, state, reason, replaced) VALUES (?, ?, ?, ?, ?)",
  "ON CONFLICT (worker) DO UPDATE SET version = excluded.version, state = excluded.state,",
  "reason = excluded.reason, replaced = excluded.replaced",
]->Array.join(" ")

type deploymentRow = {
  version: string,
  state: string,
  reason: Nullable.t<string>,
  replaced: Nullable.t<string>,
}

let deployments = (db: database): Function.store => {
  read: async worker => {
    let row: option<deploymentRow> = (
      await db
      ->prepare("SELECT version, state, reason, replaced FROM deployments WHERE worker = ?")
      ->bind([Text(worker)])
      ->first
    )->Nullable.toOption
    row->Option.map((row): Function.kept => {
      version: row.version,
      state: switch row.state {
      | "running" => #running
      | "stopped" => #stopped
      | "failed" => #failed
      | state => throw(Unkept(`a deployment standing nowhere the driver keeps, ${state}`))
      },
      reason: ?(row.reason->Nullable.toOption),
      replaced: ?(row.replaced->Nullable.toOption),
    })
  },
  write: async (worker, kept) =>
    await db->batch([
      db
      ->prepare(upsert)
      ->bind([
        Text(worker),
        Text(kept.version),
        Text(
          switch kept.state {
          | #running => "running"
          | #stopped => "stopped"
          | #failed => "failed"
          },
        ),
        text(kept.reason),
        text(kept.replaced),
      ]),
    ]),
  forget: async worker =>
    await db->batch([
      db->prepare("DELETE FROM deployments WHERE worker = ?")->bind([Text(worker)]),
    ]),
}
