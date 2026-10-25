/***
 * What the management and the function kind keep, in the driver's D1 by `migrations/`, the list
 * read and written whole, each write one batch and so one transaction, RFC nrs5v.
 */
open Stores
module Management = DriverCloudflareManagement.Management
module Function = DriverCloudflareFunction.Function
module Contracts = Envelope.Contracts

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

type adoptedRow = {
  name: string,
  kind: string,
  runs: string,
  id: Nullable.t<float>,
  component: Nullable.t<string>,
}

type warningRow = {name: string, reason: string, message: string}

/** An item's columns, in the order `rowOf` binds them. */
let columns = "id, kind, millicores, bytes, credentials, state, address, reason, message, since"

exception Unkept(string)

let text = value => value->Option.mapOr(Null, v => Text(v))
let number = value => value->Option.mapOr(Null, v => Number(v))

/** A column a row of its kind always holds, its absence a bad row, never read as a default. */
let needed = (value: Nullable.t<'a>, what) =>
  switch value->Nullable.toOption {
  | Some(value) => value
  | None => throw(Unkept(`a row of the driver's D1 holds no ${what}`))
  }

let capacityOf = (row: itemRow): Management.capacity =>
  switch row.kind {
  | "container" =>
    Container({
      millicores: row.millicores->needed("container's millicores")->Float.toInt,
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
  | "made" => Made({address: row.address->needed("made item's address")})
  | "failed" =>
    Failed({
      reason: row.reason->needed("failed item's reason"),
      message: ?(row.message->Nullable.toOption),
    })
  | "unasked" => Unasked({since: row.since->needed("unasked item's since"), ?address})
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

let adoptedOf = (row: adoptedRow): Management.adopted => {
  kind: switch row.kind {
  | "function" => #function
  | "object" => #object
  | "database" => #database
  | kind => throw(Unkept(`an adopted resource of no kind the driver keeps, ${kind}`))
  },
  name: row.name,
  for_: switch row.runs {
  | "app" => App(row.id->needed("adopted app's id"))
  | "component" =>
    Component({
      component: row.component->needed("adopted component's name"),
      id: row.id->needed("adopted component's id"),
    })
  | "item" => Item(row.id->needed("adopted item's id"))
  | runs => throw(Unkept(`an adopted resource standing for nothing the driver keeps, ${runs}`))
  },
}

/** An adopted resource's row, its columns in the order `migrations/` declares them. */
let adoptedRowOf = (entry: Management.adopted) => {
  let (runs, id, component) = switch entry.for_ {
  | App(id) => ("app", Some(id), None)
  | Component({component, id}) => ("component", Some(id), Some(component))
  | Item(id) => ("item", Some(id), None)
  }
  [
    Text(entry.name),
    Text(
      switch entry.kind {
      | #function => "function"
      | #object => "object"
      | #database => "database"
      },
    ),
    Text(runs),
    number(id),
    text(component),
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
    // Each list is read in the order it was written, as it was held.
    let adopted: rows<adoptedRow> = await db
    ->prepare("SELECT name, kind, runs, id, component FROM adopted ORDER BY rowid")
    ->bind([])
    ->all
    let warnings: rows<warningRow> = await db
    ->prepare("SELECT name, reason, message FROM warnings ORDER BY rowid")
    ->bind([])
    ->all
    {
      generation: held.generation,
      policy: held.policy,
      grace: held.grace->Float.toInt,
      items: items.results->Array.map(itemOf),
      tokens: held.listed == 1. ? Some(tokens.results->Array.map(t => t.hash)) : None,
      adopted: adopted.results->Array.map(adoptedOf),
      warnings: warnings.results->Array.map((w): Management.warning => {
        reason: w.reason,
        message: w.message,
        name: w.name,
      }),
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
          db->prepare("DELETE FROM adopted")->bind([]),
          db->prepare("DELETE FROM warnings")->bind([]),
        ],
        [
          kept.items->Array.map(k =>
            db
            ->prepare(`INSERT INTO items (${columns}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
            ->bind(rowOf(k))
          ),
          // A hash named twice is held once, as the table keeps each once.
          kept.tokens
          ->Option.getOr([])
          ->Array.filterWithIndex((hash, at) =>
            kept.tokens->Option.getOr([])->Array.indexOf(hash) == at
          )
          ->Array.map(hash =>
            db->prepare("INSERT INTO tokens (hash) VALUES (?)")->bind([Text(hash)])
          ),
          kept.adopted->Array.map(entry =>
            db
            ->prepare(
              "INSERT INTO adopted (name, kind, runs, id, component) VALUES (?, ?, ?, ?, ?)",
            )
            ->bind(adoptedRowOf(entry))
          ),
          kept.warnings->Array.map(w =>
            db
            ->prepare("INSERT INTO warnings (name, reason, message) VALUES (?, ?, ?)")
            ->bind([Text(w.name), Text(w.reason), Text(w.message)])
          ),
        ],
      ),
    ),
}

/** A deployment written whole, made or replaced, the deployment it stands for with it. */
let upsert = [
  "INSERT INTO deployments (worker, version, state, reason, replaced, runs)",
  "VALUES (?, ?, ?, ?, ?, ?)",
  "ON CONFLICT (worker) DO UPDATE SET version = excluded.version, state = excluded.state,",
  "reason = excluded.reason, replaced = excluded.replaced, runs = excluded.runs",
]->Array.join(" ")

type deploymentRow = {
  version: string,
  state: string,
  reason: Nullable.t<string>,
  replaced: Nullable.t<string>,
}

/** What a deployment's row stands for, `app <id>` or `component <id>`. */
let runsOf = (runs: Contracts.DeploymentRuns.t) =>
  switch runs {
  | App({id}) => `app ${Float.toString(id)}`
  | Component({id}) => `component ${Float.toString(id)}`
  }

/** The rows by their Worker, and by the deployment they stand for where `runs` names one. */
let deploymentsBy = (db: database, ~runs: option<string>): Function.store => {
  let which = switch runs {
  | Some(runs) => ("worker = ? AND runs = ?", worker => [Text(worker), Text(runs)])
  | None => ("worker = ?", worker => [Text(worker)])
  }
  let (where, bound) = which
  {
    read: async worker => {
      let row: option<deploymentRow> = (
        await db
        ->prepare(`SELECT version, state, reason, replaced FROM deployments WHERE ${where}`)
        ->bind(bound(worker))
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
          text(runs),
        ]),
      ]),
    // A deployment's Worker the driver made is held by its records no more once it is forgotten.
    forget: async worker =>
      await db->batch([
        db->prepare(`DELETE FROM deployments WHERE ${where}`)->bind(bound(worker)),
        db
        ->prepare("DELETE FROM owned WHERE name = ? AND role = 'deployment'")
        ->bind([Text(worker)]),
      ]),
  }
}

/** The rows by their Worker alone, as the list and its warnings read them. */
let deployments = db => deploymentsBy(db, ~runs=None)

/** One deployment's rows, taken by what it runs, never by its Worker's name alone. */
let deploymentOf = (db, runs) => deploymentsBy(db, ~runs=Some(runsOf(runs)))
