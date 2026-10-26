/***
 * An account faked as wrangler, curl and rescript show it to install, each command answered from
 * what it holds and what it holds changed as the command would change it.
 */
open Asserted

/** A made-up install id, the first name each faked install draws, its state D1's. */
let id = "0a1b2c3d"

/** The names a first install draws in turn, made up, each part's by its role. */
let drawnNames = ["0a1b2c3d", "1b2c3d4e", "2c3d4e5f", "3d4e5f6a", "4e5f6a7b", "5f6a7b8c"]
let driverName = "1b2c3d4e"
let objectName = "2c3d4e5f"
let bucketName = "3d4e5f6a"
let databaseName = "4e5f6a7b"
let userDatabaseName = "5f6a7b8c"

/** What a Worker on the faked account holds, its versions with their tags and its secrets. */
type held = {
  mutable versions: array<(option<string>, string)>,
  secrets: Dict.t<string>,
  mutable bundle: string,
  mutable deployed: array<string>,
}

/** What the account holds, as wrangler's commands read and write it. */
type account = {
  mutable databases: array<string>,
  mutable buckets: array<string>,
  workers: Dict.t<held>,
  /** The D1s whose migrations were applied, so the driver's tables are there. */
  mutable migrated: array<string>,
  /** The install id each D1's table `install` holds. */
  marks: Dict.t<string>,
  /** The tables a D1 not the driver's holds of its own. */
  own: Dict.t<array<string>>,
  /** The names each D1's table `owned` records, by their roles. */
  records: Dict.t<array<(string, string)>>,
  /** What the faked control answers a bind, and each bind's address, bearer and body. */
  mutable control: option<string>,
  binds: array<(string, string, string)>,
}

/** The faked control's base, a reserved name, RFC 2606. */
let base = "https://control.example.com/v1/app-2"

/** What the control answers where it recorded the origin sent, binding 7 a made-up one. */
let recorded = origin =>
  JSON.stringify(
    JSON.Object(
      dict{
        "status": JSON.String("success"),
        "data": JSON.Object(
          dict{
            "binding": JSON.Number(7.),
            "reached": JSON.Object(
              dict{"name": JSON.String("origin"), "origin": JSON.String(origin)},
            ),
          },
        ),
      },
    ),
  )

let empty = () => {
  databases: [],
  buckets: [],
  migrated: [],
  marks: dict{},
  own: dict{},
  records: dict{},
  control: None,
  binds: [],
  workers: dict{
    "1b2c3d4e": {versions: [], secrets: dict{}, bundle: "the driver's bundle", deployed: []},
    "2c3d4e5f": {versions: [], secrets: dict{}, bundle: "the object's bundle", deployed: []},
    "4e5f6a7b": {
      versions: [],
      secrets: dict{},
      bundle: "the database's bundle",
      deployed: [],
    },
  },
}

/** A D1 the account holds, migrated and marked with `mark`, as a driver's own is. */
let holding = (account, name, ~mark) => {
  account.databases->Array.push(name)
  account.migrated->Array.push(name)
  account.marks->Dict.set(name, mark)
}

/** The names a D1's table `owned` records, by their roles, as an install before wrote them. */
let recording = (account, name, records) => account.records->Dict.set(name, records)

/** A Worker the account holds, one version deployed. */
let running = (account, name) =>
  account.workers->Dict.set(
    name,
    {versions: [(Some("a tag"), "upload")], secrets: dict{}, bundle: "", deployed: []},
  )

/** The tables query and the marker query install runs, and the line of the marker's write. */
let tablesRead = name =>
  `wrangler d1 execute ${name} --remote --command ${Install_ledger.tablesQuery} --json`
let markerRead = name =>
  `wrangler d1 execute ${name} --remote --command ${Install_ledger.markerQuery} --json`
let markerWritten = name =>
  `wrangler d1 execute ${name} --remote --command ${Install_ledger.markerWrite(name)}`
let recordsRead = name =>
  `wrangler d1 execute ${name} --remote --command ${Install_ledger.recordsQuery} --json`
let recordsWritten = (name, records) =>
  `wrangler d1 execute ${name} --remote --command ${Install_ledger.recordsWrite(records)}`

/** The Workers list, by curl and the documented account id. */
let workersListed = [
  "curl -q --silent --show-error --fail-with-body --header @- ",
  "https://api.cloudflare.com/client/v4/accounts/023e105f4ecef8ad9ca31a8372d0c353/workers/scripts",
]->Array.join("")

/** The Worker a configuration of the moment names, read from the file while it is there. */
let heldBy = (account, config) =>
  switch Host.existsSync(config) {
  | false => None
  | true =>
    Install_world.parsed(Host.readFileSync(config))
    ->Option.flatMap(json => json->Install_world.text("name"))
    ->Option.map(name =>
      switch account.workers->Dict.get(name) {
      | Some(held) => held
      // A Worker of another install id is held as the three are, made empty where it is absent.
      | None =>
        let held = {versions: [], secrets: dict{}, bundle: `${name}'s bundle`, deployed: []}
        account.workers->Dict.set(name, held)
        held
      }
    )
  }

let versionsOf = held =>
  JSON.stringify(
    JSON.Array(
      held.versions->Array.mapWithIndex(((tag, trigger), i) => {
        let annotations = dict{"workers/triggered_by": JSON.String(trigger)}
        tag->Option.forEach(t => annotations->Dict.set("workers/tag", JSON.String(t)))
        JSON.Object(
          dict{"id": JSON.String(`v${Int.toString(i)}`), "annotations": JSON.Object(annotations)},
        )
      }),
    ),
  )

/** A command's arguments before the empty env file every wrangler command ends with. */
let argsOf = (command: Install_world.command) => {
  let n = Array.length(command.args)
  command.args->Array.slice(~start=n - 2) == Install_world.noEnvFile
    ? command.args->Array.slice(~start=0, ~end=n - 2)
    : command.args
}

let line = (command: Install_world.command) =>
  [Host.basename(command.program), ...argsOf(command)]->Array.join(" ")

/** What wrangler prints for a Worker the account does not hold. */
let notFound = "This Worker does not exist on your account. [code: 10007]"

/** What `d1 execute --json` prints for one statement answering `rows`. */
let results = rows =>
  JSON.stringify(
    JSON.Array([
      JSON.Object(
        dict{
          "results": JSON.Array(rows->Array.map(row => JSON.Object(row))),
          "success": JSON.Boolean(true),
        },
      ),
    ]),
  )

let answered = (account, command: Install_world.command) => {
  let worker = config =>
    switch heldBy(account, config) {
    | Some(held) => Ok(held)
    | None => Error(`no configuration of the moment at ${config}`)
    }
  let missing = Error(notFound)
  let program = Host.basename(command.program)
  switch (program, List.fromArray(argsOf(command))) {
  | ("wrangler", _) if argsOf(command) == command.args => Error(`reads a .env, ${line(command)}`)
  | ("wrangler", list{"d1", "list", "--json"}) =>
    Ok(
      JSON.stringify(
        JSON.Array(
          account.databases->Array.map(name => JSON.Object(
            dict{"name": JSON.String(name), "uuid": JSON.String(`uuid-${name}`)},
          )),
        ),
      ),
    )
  | ("rescript", list{"build"}) => Ok("")
  | ("curl", _) if command.args->Array.at(-1)->Option.getOr("")->String.endsWith("/subdomain") =>
    Ok(`{"success": true, "errors": [], "messages": [], "result": {"subdomain": "my-subdomain"}}`)
  | ("curl", _) if command.args->Array.at(-1)->Option.getOr("")->String.startsWith(base) =>
    let at = command.args->Array.indexOf("--data")
    account.binds->Array.push((
      command.args->Array.at(-1)->Option.getOr(""),
      command.input->Option.getOr(""),
      command.args->Array.get(at + 1)->Option.getOr(""),
    ))
    let sent =
      command.args
      ->Array.get(at + 1)
      ->Option.flatMap(Install_world.parsed)
      ->Option.flatMap(json =>
        json
        ->Install_world.member("input")
        ->Install_world.member("reach")
        ->Install_world.text("origin")
      )
      ->Option.getOr("")
    Ok(account.control->Option.getOr(recorded(sent)))
  | ("curl", _) =>
    Ok(
      JSON.stringify(
        JSON.Object(
          dict{
            "success": JSON.Boolean(true),
            "result": JSON.Array(
              account.workers
              ->Dict.toArray
              ->Array.filter(((_, held)) => held.versions != [])
              ->Array.map(((name, _)) => JSON.Object(dict{"id": JSON.String(name)})),
            ),
          },
        ),
      ),
    )
  | ("wrangler", list{"d1", "execute", name, "--remote", "--command", _, "--json"})
  | ("wrangler", list{"d1", "execute", name, "--remote", "--command", _})
    if !(account.databases->Array.includes(name)) =>
    Error(`Couldn't find a D1 DB with the name or binding '${name}' [code: 7404]`)
  | ("wrangler", list{"d1", "execute", name, "--remote", "--command", query, "--json"})
    if query == Install_ledger.tablesQuery =>
    let tables = [
      "_cf_KV",
      ...account.marks->Dict.get(name)->Option.mapOr([], _ => ["install"]),
      ...account.migrated->Array.includes(name) ? ["d1_migrations", "held", "items", "owned"] : [],
      ...account.own->Dict.get(name)->Option.getOr([]),
    ]
    Ok(results(tables->Array.map(table => dict{"name": JSON.String(table)})))
  | ("wrangler", list{"d1", "execute", name, "--remote", "--command", query, "--json"})
    if query == Install_ledger.markerQuery =>
    switch account.marks->Dict.get(name) {
    | Some(mark) => Ok(results([dict{"id": JSON.String(mark)}]))
    | None => Error("no such table: install: SQLITE_ERROR [code: 7500]")
    }
  | ("wrangler", list{"d1", "execute", name, "--remote", "--command", query, "--json"})
    if query == Install_ledger.recordsQuery =>
    Ok(
      results(
        account.records
        ->Dict.get(name)
        ->Option.getOr([])
        ->Array.map(((held, role)) => dict{"name": JSON.String(held), "role": JSON.String(role)}),
      ),
    )
  | ("wrangler", list{"d1", "execute", name, "--remote", "--command", query})
    if query->String.startsWith("INSERT INTO owned ") =>
    if !(account.migrated->Array.includes(name)) {
      Error("no such table: owned: SQLITE_ERROR [code: 7500]")
    } else {
      let written =
        query
        ->String.split("), (")
        ->Array.filterMap(pair =>
          switch /'([0-9a-f]{8})', '([a-z_]+)'/->RegExp.exec(pair) {
          | Some(found) =>
            switch found->RegExp.Result.matches {
            | [Some(held), Some(role)] => Some((held, role))
            | _ => None
            }
          | None => None
          }
        )
      let before = account.records->Dict.get(name)->Option.getOr([])
      account.records->Dict.set(name, [...before, ...written])
      Ok("")
    }
  | ("wrangler", list{"d1", "execute", name, "--remote", "--command", query})
    if query->String.startsWith("CREATE TABLE install (") =>
    if account.migrated->Array.includes(name) {
      Error(`the marker written into ${name} after a migration`)
    } else if account.marks->Dict.get(name) != None {
      Error("table install already exists: SQLITE_ERROR [code: 7500]")
    } else {
      account.marks->Dict.set(name, query->String.slice(~start=-10, ~end=-2))
      Ok("")
    }
  | ("wrangler", list{"d1", "create", name, "--location", "wnam" | "apac"}) =>
    account.databases->Array.push(name)
    Ok("")
  | ("wrangler", list{"d1", "migrations", "apply", name, "--remote", "--config", config})
    if account.databases->Array.includes(name) =>
    worker(config)->Result.map(_ => {
      if !(account.migrated->Array.includes(name)) {
        account.migrated->Array.push(name)
      }
      ""
    })
  | ("wrangler", list{"versions", "list", "--json", "--name", name}) =>
    switch account.workers->Dict.get(name) {
    | Some(held) if held.versions != [] => Ok(versionsOf(held))
    | Some(_) | None => missing
    }
  | ("wrangler", list{"r2", "bucket", "list"}) =>
    Ok(
      account.buckets
      ->Array.map(name => `name:           ${name}\ncreation_date:  2026-10-23T00:00:00.000Z`)
      ->Array.join("\n\n"),
    )
  | ("wrangler", list{"r2", "bucket", "create", name, "--location", "wnam" | "apac"}) =>
    account.buckets->Array.push(name)
    Ok("")
  | ("wrangler", list{"deploy", "--dry-run", "--outdir", out, "--config", config}) =>
    worker(config)->Result.map(held => {
      mkdirSync(out, {recursive: true})
      Host.writeFileSync(Host.join([out, "worker.res.js"]), held.bundle)
      ""
    })
  | ("wrangler", list{"versions", "list", "--json", "--config", config}) =>
    worker(config)->Result.flatMap(held => held.versions == [] ? missing : Ok(versionsOf(held)))
  | ("wrangler", list{"deploy", "--config", config, "--tag", tag}) =>
    worker(config)->Result.map(held => {
      held.versions->Array.push((Some(tag), "upload"))
      held.deployed->Array.push(Host.readFileSync(config))
      ""
    })
  | ("wrangler", list{"secret", "list", "--config", config}) =>
    worker(config)->Result.flatMap(held =>
      held.versions == []
        ? missing
        : Ok(
            JSON.stringify(
              JSON.Array(
                held.secrets
                ->Dict.keysToArray
                ->Array.map(name => JSON.Object(
                  dict{"name": JSON.String(name), "type": JSON.String("secret_text")},
                )),
              ),
            ),
          )
    )
  | ("wrangler", list{"secret", "put", name, "--config", config}) =>
    worker(config)->Result.flatMap(held =>
      // A put before the Worker exists would make an empty one.
      if held.versions == [] {
        Error("an empty Worker made")
      } else {
        held.secrets->Dict.set(name, command.input->Option.getOr(""))
        held.versions->Array.push((None, "secret"))
        Ok("")
      }
    )
  | _ => Error(`not expected, ${line(command)}`)
  }
}
