/***
 * `install` against an account faked as wrangler shows it, its plan dry, its first run making each
 * part in order and a second changing nothing, every name followed by the install id.
 */
open Asserted

/** A made-up install id, the one each faked draw answers. */
let id = "0a1b2c3d"
let full = name => `${name}-${id}`

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
}

let empty = () => {
  databases: [],
  buckets: [],
  migrated: [],
  marks: dict{},
  own: dict{},
  workers: dict{
    "driver-0a1b2c3d": {versions: [], secrets: dict{}, bundle: "the driver's bundle", deployed: []},
    "object-0a1b2c3d": {versions: [], secrets: dict{}, bundle: "the object's bundle", deployed: []},
    "database-0a1b2c3d": {
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

/** A Worker the account holds, one version deployed. */
let running = (account, name) =>
  account.workers->Dict.set(
    name,
    {versions: [(Some("a tag"), "upload")], secrets: dict{}, bundle: "", deployed: []},
  )

/** The tables query and the marker query install runs, and the line of the marker's write. */
let tablesRead = name =>
  `wrangler d1 execute ${name} --remote --command ${Install.tablesQuery} --json`
let markerRead = name =>
  `wrangler d1 execute ${name} --remote --command ${Install.markerQuery} --json`
let markerWritten = name =>
  `wrangler d1 execute ${name} --remote --command ${Install.markerWrite(id)}`

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
    Install.parsed(Host.readFileSync(config))
    ->Option.flatMap(json => json->Install.text("name"))
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
let argsOf = (command: Install.command) => {
  let n = Array.length(command.args)
  command.args->Array.slice(~start=n - 2) == Install.noEnvFile
    ? command.args->Array.slice(~start=0, ~end=n - 2)
    : command.args
}

let line = (command: Install.command) =>
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

let answered = (account, command: Install.command) => {
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
    if query == Install.tablesQuery =>
    let tables = [
      "_cf_KV",
      ...account.marks->Dict.get(name)->Option.mapOr([], _ => ["install"]),
      ...account.migrated->Array.includes(name) ? ["d1_migrations", "held", "items"] : [],
      ...account.own->Dict.get(name)->Option.getOr([]),
    ]
    Ok(results(tables->Array.map(table => dict{"name": JSON.String(table)})))
  | ("wrangler", list{"d1", "execute", name, "--remote", "--command", query, "--json"})
    if query == Install.markerQuery =>
    switch account.marks->Dict.get(name) {
    | Some(mark) => Ok(results([dict{"id": JSON.String(mark)}]))
    | None => Error("no such table: install: SQLITE_ERROR [code: 7500]")
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
  | ("wrangler", list{"d1", "create", name})
  | ("wrangler", list{"d1", "create", name, "--location", _}) =>
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
  | ("wrangler", list{"r2", "bucket", "create", name})
  | ("wrangler", list{"r2", "bucket", "create", name, "--location", _}) =>
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

/** A root of its own holding the three Workers' configurations as the repository holds them. */
let fixtures = []
let fixture = () => {
  let root = Host.mkdtempSync(Host.join([Host.tmpdir(), "install-root-"]))
  fixtures->Array.push(root)
  mkdirSync(Host.join([root, "cloudflare", "object"]), {recursive: true})
  mkdirSync(Host.join([root, "cloudflare", "database"]), {recursive: true})
  ["cloudflare", "cloudflare/object", "cloudflare/database"]->Array.forEach(dir =>
    copyFileSync(
      Host.join([Install.root, dir, "wrangler.json"]),
      Host.join([root, dir, "wrangler.json"]),
    )
  )
  root
}

/** The secret 0 to 31, its token, and its BLAKE3 as b3sum gives it. */
let secret = Uint8Array.fromLength(32)
for i in 0 to 31 {
  secret->TypedArray.set(i, i)
}
let token = "7.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
let hashed = "e528e95798037df410543d9f31e396ecdd458d71b157d6014398bae32fb56c65"

/** Cloudflare's documented example account ids. */
let accountId = "023e105f4ecef8ad9ca31a8372d0c353"
let anotherAccount = "699d98642c564d2e855e9661899b7252"

/** Install's own inputs, every kind offered. */
let credentials = [
  ("DRIVER_ACCOUNT_ID", accountId),
  ("DRIVER_INSTALL_TOKEN", "the-install-token"),
  ("DRIVER_API_TOKEN", "the-driver-token"),
  ("DATABASE_API_TOKEN", "the-database-token"),
  ("DRIVER_KINDS", "function,object,database"),
]

/** What the environment holds besides, which install never reads. */
let ambient = [
  ("CLOUDFLARE_API_TOKEN", "the-ambient-token"),
  ("CLOUDFLARE_ACCOUNT_ID", anotherAccount),
  ("CLOUDFLARE_EMAIL", "author@example.com"),
]

/** Every value no argument and no line said may hold. */
let secrets = [
  "the-install-token",
  "the-ambient-token",
  "the-driver-token",
  "the-database-token",
  token,
  hashed,
]

type faked = {
  world: Install.world,
  ran: array<Install.command>,
  said: array<string>,
  scratched: array<string>,
}

let make = (~env=credentials, ~stdin=token, ~drawn=id, ~draws=[], ~answer) => {
  let ran = []
  let queued = draws->Array.copy
  let said = []
  let scratched = []
  let world: Install.world = {
    run: command => {
      ran->Array.push(command)
      answer(command)
    },
    env: Dict.fromArray(env),
    say: line => said->Array.push(line),
    stdin: () => stdin,
    scratch: () => {
      let made = Host.mkdtempSync(Host.join([Host.tmpdir(), "install-scratch-"]))
      scratched->Array.push(made)
      made
    },
    draw: () => queued->Array.shift->Option.getOr(drawn),
  }
  {world, ran, said, scratched}
}

/** Each line run with the paths a run makes written as names, a build beside its Worker's. */
let plain = faked =>
  faked.ran->Array.map(command => {
    let within = switch Host.basename(command.program) {
    | "rescript" if command.cwd->String.endsWith("/cloudflare/object") => " in <object>"
    | "rescript" if command.cwd->String.endsWith("/cloudflare/database") => " in <database>"
    | "rescript" if command.cwd->String.endsWith("/cloudflare") => " in <driver>"
    | _ => ""
    }
    let words = line(command)->String.split(" ")
    words
    ->Array.mapWithIndex((word, i) =>
      if word->String.endsWith("/cloudflare/wrangler.install.json") {
        "<driver>"
      } else if word->String.endsWith("/object/wrangler.install.json") {
        "<object>"
      } else if word->String.endsWith("/database/wrangler.install.json") {
        "<database>"
      } else if word->String.includes("install-scratch-") {
        "<out>"
      } else if i > 0 && words->Array.get(i - 1) == Some("--tag") {
        "<tag>"
      } else {
        word
      }
    )
    ->Array.join(" ") ++ within
  })

/** Whether any argument run or any line said holds a secret. */
let shows = faked =>
  secrets->Array.some(s =>
    faked.ran->Array.some(c => c.args->Array.some(a => a->String.includes(s))) ||
      faked.said->Array.some(l => l->String.includes(s))
  )

let installed = (~env=?, ~stdin=?, ~drawn=?, ~draws=?, account, root) => {
  let faked = make(~env?, ~stdin?, ~drawn?, ~draws?, ~answer=command => answered(account, command))
  let result = Install.install(faked.world, ~dry=false, ~root)
  (faked, result)
}

let first = [
  "wrangler d1 list --json",
  workersListed,
  "wrangler d1 list --json",
  "wrangler d1 create driver-0a1b2c3d",
  markerWritten("driver-0a1b2c3d"),
  "wrangler d1 list --json",
  "wrangler d1 migrations apply driver-0a1b2c3d --remote --config <driver>",
  "wrangler d1 list --json",
  "wrangler d1 create database-0a1b2c3d",
  "wrangler d1 list --json",
  "wrangler r2 bucket list",
  "wrangler r2 bucket create objects-0a1b2c3d",
  "rescript build in <driver>",
  "wrangler deploy --dry-run --outdir <out> --config <driver>",
  "wrangler versions list --json --config <driver>",
  "wrangler deploy --config <driver> --tag <tag>",
  "wrangler secret list --config <driver>",
  "wrangler secret put API_TOKEN --config <driver>",
  "wrangler secret put BINDING --config <driver>",
  "rescript build in <object>",
  "wrangler deploy --dry-run --outdir <out> --config <object>",
  "wrangler versions list --json --config <object>",
  "wrangler deploy --config <object> --tag <tag>",
  "wrangler secret list --config <object>",
  "wrangler secret put BINDING --config <object>",
  "rescript build in <database>",
  "wrangler deploy --dry-run --outdir <out> --config <database>",
  "wrangler versions list --json --config <database>",
  "wrangler deploy --config <database> --tag <tag>",
  "wrangler secret list --config <database>",
  "wrangler secret put API_TOKEN --config <database>",
  "wrangler secret put BINDING --config <database>",
]

let again = [
  "wrangler d1 list --json",
  tablesRead("driver-0a1b2c3d"),
  markerRead("driver-0a1b2c3d"),
  "wrangler d1 list --json",
  "wrangler d1 migrations apply driver-0a1b2c3d --remote --config <driver>",
  "wrangler d1 list --json",
  "wrangler r2 bucket list",
  "rescript build in <driver>",
  "wrangler deploy --dry-run --outdir <out> --config <driver>",
  "wrangler versions list --json --config <driver>",
  "wrangler secret list --config <driver>",
  "rescript build in <object>",
  "wrangler deploy --dry-run --outdir <out> --config <object>",
  "wrangler versions list --json --config <object>",
  "wrangler secret list --config <object>",
  "rescript build in <database>",
  "wrangler deploy --dry-run --outdir <out> --config <database>",
  "wrangler versions list --json --config <database>",
  "wrangler secret list --config <database>",
]

let moments = root => [
  Host.join([root, "cloudflare", Install.moment]),
  Host.join([root, "cloudflare", "object", Install.moment]),
  Host.join([root, "cloudflare", "database", Install.moment]),
]

/** The reads a dry run may run, the D1 list, the tables queries and the marker queries. */
let reads = command => {
  let l = line(command)
  l == "wrangler d1 list --json" ||
    (l->String.startsWith("wrangler d1 execute ") &&
      [Install.tablesQuery, Install.markerQuery]->Array.some(q =>
        l->String.endsWith(`${q} --json`)
      ))
}

/** A dry run whose commands are answered by `account`, any but the reads refused. */
let dryOn = (~env=?, ~answer=?, account, root) => {
  let answer =
    answer->Option.getOr(command =>
      reads(command) ? answered(account, command) : Error(`ran ${line(command)}`)
    )
  let faked = make(~env?, ~answer)
  (faked, Install.install(faked.world, ~dry=true, ~root))
}

test("a dry run reads the D1 list alone, writes nothing and shows no secret", () => {
  let root = fixture()
  let (faked, result) = dryOn(empty(), root)
  deepEqual(result, Ok())
  deepEqual((plain(faked), faked.scratched), (["wrangler d1 list --json"], []))
  ok(!shows(faked), ~message="a secret was said")
  ok(moments(root)->Array.every(path => !Host.existsSync(path)))
  ok(
    [
      "d1 list names no driver's D1 holding its marker, so a new install id would be drawn",
      "wrangler d1 execute driver-<install id> --remote --command CREATE TABLE install",
      "wrangler d1 create driver-<install id>",
      "wrangler d1 create database-<install id>",
      "wrangler d1 migrations apply driver-<install id> --remote",
      "wrangler r2 bucket create objects-<install id>",
      "rescript build in cloudflare",
      "rescript build in cloudflare/object",
      "rescript build in cloudflare/database",
      "the variables INSTALL_ID, ACCOUNT_ID, KINDS filled in",
      "the variables INSTALL_ID, ACCOUNT_ID, DATABASE_ID filled in",
      "wrangler deploy --config",
      "wrangler secret put API_TOKEN",
      "wrangler secret put BINDING",
    ]->Array.every(said => faked.said->Array.some(l => l->String.includes(said))),
    ~message=faked.said->Array.join("\n"),
  )
})

test("a dry run says which install id it would reuse, and refuses where two are marked", () => {
  let account = empty()
  account.databases = ["other"]
  account->holding("driver-0a1b2c3d", ~mark=id)
  let (faked, result) = dryOn(account, fixture())
  deepEqual(result, Ok())
  ok(
    faked.said->Array.includes(
      "d1 list names driver-0a1b2c3d, so the install id 0a1b2c3d would be reused",
    ),
  )
  ok(
    faked.said->Array.some(l => l->String.includes("wrangler d1 migrations apply driver-0a1b2c3d")),
  )
  account->holding("driver-4e5f6a7b", ~mark="4e5f6a7b")
  let (faked, result) = dryOn(account, fixture())
  ok(result->Result.isError)
  deepEqual(
    plain(faked),
    [
      "wrangler d1 list --json",
      tablesRead("driver-0a1b2c3d"),
      markerRead("driver-0a1b2c3d"),
      tablesRead("driver-4e5f6a7b"),
      markerRead("driver-4e5f6a7b"),
    ],
  )
})

test("a dry run that cannot read the account prints the rule and says why", () => {
  let rule =
    [
      "  it reuses the install id of the one driver-<8 hex> holding the driver's marker, ",
      "draws a",
    ]->Array.join("")
  let (failed, result) = dryOn(~answer=_ => Error("the list failed"), empty(), fixture())
  deepEqual(result, Ok())
  ok(failed.said->Array.includes(rule), ~message=failed.said->Array.join("\n"))
  ok(failed.said->Array.some(l => l == "the install id is not known, as the list failed;"))
  let (unread, result) = dryOn(~answer=_ => Ok("not JSON"), empty(), fixture())
  deepEqual(result, Ok())
  ok(unread.said->Array.some(l => l->String.includes("d1 list printed no JSON array")))
  let env = credentials->Array.filter(((name, _)) => name != "DRIVER_INSTALL_TOKEN")
  let (unset, result) = dryOn(~env, empty(), fixture())
  deepEqual(result, Ok())
  deepEqual(unset.ran, [])
  ok(unset.said->Array.includes("the install id is not known, as DRIVER_INSTALL_TOKEN unset;"))
  ok(unset.said->Array.includes(rule))
  ok(
    unset.said->Array.includes(
      "DRIVER_INSTALL_TOKEN unset in the environment, so a run not dry refuses",
    ),
  )
})

test("a missing input is refused by its name before anything runs, none read in its stead", () => {
  let root = fixture()
  let env = [...ambient, ("DRIVER_ACCOUNT_ID", "")]
  let faked = make(~env, ~answer=_ => Ok(""))
  let names = "DRIVER_ACCOUNT_ID, DRIVER_INSTALL_TOKEN, DRIVER_API_TOKEN"
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root),
    Error(`${names} unset in the environment, which alone gives them`),
  )
  deepEqual(faked.ran, [])
  // A dry run names them, and reads nothing, the account being unknown.
  let faked = make(~env, ~answer=_ => Ok(""))
  deepEqual(Install.install(faked.world, ~dry=true, ~root), Ok())
  deepEqual(faked.ran, [])
  ok(faked.said->Array.includes(`${names} unset in the environment, so a run not dry refuses`))
})

test("DRIVER_ACCOUNT_ID unset is refused, though CLOUDFLARE_ACCOUNT_ID is set", () => {
  let root = fixture()
  let env = [...credentials->Array.filter(((name, _)) => name != "DRIVER_ACCOUNT_ID"), ...ambient]
  let faked = make(~env, ~answer=_ => Ok(""))
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root),
    Error("DRIVER_ACCOUNT_ID unset in the environment, which alone gives them"),
  )
  deepEqual(faked.ran, [])
  let faked = make(~env, ~answer=_ => Ok(""))
  deepEqual(Install.install(faked.world, ~dry=true, ~root), Ok())
  deepEqual(faked.ran, [])
})

test("DATABASE_API_TOKEN missing is refused by its name alone, and said in a dry run", () => {
  let root = fixture()
  let env = credentials->Array.filter(((name, _)) => name != "DATABASE_API_TOKEN")
  let faked = make(~env, ~answer=_ => Ok(""))
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root),
    Error("DATABASE_API_TOKEN unset in the environment, which alone gives them"),
  )
  deepEqual(faked.ran, [])
  let (faked, result) = dryOn(~env, empty(), root)
  deepEqual(result, Ok())
  ok(
    faked.said->Array.includes(
      "DATABASE_API_TOKEN unset in the environment, so a run not dry refuses",
    ),
  )
})

test("a first install makes each part in order, and a second changes nothing", () => {
  let root = fixture()
  let account = empty()
  let (made, result) = installed(account, root)
  deepEqual(result, Ok())
  deepEqual(plain(made), first)
  deepEqual(account.marks->Dict.get(full("driver")), Some(id))
  let (kept, result) = installed(account, root)
  deepEqual(result, Ok())
  deepEqual(plain(kept), again)
  ok(moments(root)->Array.every(path => !Host.existsSync(path)), ~message="a moment was left")
  ok(
    [...made.scratched, ...kept.scratched]->Array.every(path => !Host.existsSync(path)),
    ~message="a scratch directory was left",
  )
})

test("each part the account holds already is passed over", () => {
  let root = fixture()
  let account = empty()
  account.databases = ["other", "driver", "database-0a1b2c3d"]
  account->holding("driver-0a1b2c3d", ~mark=id)
  account.buckets = ["objects", "objects-0a1b2c3d"]
  let (faked, result) = installed(account, root)
  deepEqual(result, Ok())
  let lines = plain(faked)
  ok(lines->Array.every(l => !(l->String.includes(" create "))), ~message=lines->Array.join("\n"))
  ok(faked.said->Array.includes("the database driver-0a1b2c3d is there already"))
  ok(faked.said->Array.includes("the database database-0a1b2c3d is there already"))
  ok(faked.said->Array.includes("the bucket objects-0a1b2c3d is there already"))
})

test("a Worker is deployed again only where its bundle or its configuration changed", () => {
  let root = fixture()
  let account = empty()
  let _ = installed(account, root)
  let object = account.workers->Dict.getUnsafe(full("object"))
  let driver = account.workers->Dict.getUnsafe(full("driver"))
  object.bundle = "the object's bundle, changed"
  let (faked, result) = installed(account, root)
  deepEqual(result, Ok())
  deepEqual(
    plain(faked)->Array.filter(l => l->String.startsWith("wrangler deploy --config")),
    ["wrangler deploy --config <object> --tag <tag>"],
  )
  deepEqual((driver.deployed->Array.length, object.deployed->Array.length), (1, 2))
  // The account's id is the configuration's, so a new one deploys each again.
  let env = [...credentials, ("DRIVER_ACCOUNT_ID", anotherAccount)]
  let (faked, _) = installed(~env, account, root)
  deepEqual(
    plain(faked)->Array.filter(l => l->String.startsWith("wrangler deploy --config")),
    [
      "wrangler deploy --config <driver> --tag <tag>",
      "wrangler deploy --config <object> --tag <tag>",
      "wrangler deploy --config <database> --tag <tag>",
    ],
  )
})

test("each configuration of the moment holds its databases' ids and the account's", () => {
  let root = fixture()
  let account = empty()
  let _ = installed(account, root)
  let configOf = name =>
    (account.workers->Dict.getUnsafe(name)).deployed
    ->Array.get(0)
    ->Option.flatMap(Install.parsed)
    ->Option.getOr(JSON.Null)
  let seen = name => {
    let config = configOf(name)
    let ids =
      config
      ->Install.member("d1_databases")
      ->JSON.Decode.array
      ->Option.getOr([])
      ->Array.map(db => (db->Install.text("binding"), db->Install.text("database_id")))
    let vars = config->Install.member("vars")
    (
      config->Install.text("name"),
      ids,
      vars->Install.text("ACCOUNT_ID"),
      vars->Install.text("DATABASE_ID"),
    )
  }
  let driver = (Some("DB"), Some("uuid-driver-0a1b2c3d"))
  let account = Some(accountId)
  deepEqual(seen(full("driver")), (Some(full("driver")), [driver], account, None))
  deepEqual(seen(full("object")), (Some(full("object")), [driver], account, None))
  deepEqual(
    seen(full("database")),
    (
      Some(full("database")),
      [driver, (Some("DATABASE"), Some("uuid-database-0a1b2c3d"))],
      account,
      Some("uuid-database-0a1b2c3d"),
    ),
  )
  let named = (name, key, field) =>
    configOf(full(name))
    ->Install.member(key)
    ->JSON.Decode.array
    ->Option.getOr([])
    ->Array.map(entry => entry->Install.text(field))
  deepEqual(named("driver", "d1_databases", "database_name"), [Some(full("driver"))])
  deepEqual(
    named("database", "d1_databases", "database_name"),
    [Some(full("driver")), Some(full("database"))],
  )
  deepEqual(named("object", "r2_buckets", "bucket_name"), [Some(full("objects"))])
  let varOf = (name, var) => configOf(full(name))->Install.member("vars")->Install.text(var)
  deepEqual(
    ["driver", "object", "database"]->Array.map(name => varOf(name, "INSTALL_ID")),
    [Some(id), Some(id), Some(id)],
  )
  deepEqual(
    ["driver", "object", "database"]->Array.map(name => varOf(name, "KINDS")),
    [Some("function,object,database"), None, None],
  )
})

test("a secret is put only where its name is missing, on stdin and never in an argument", () => {
  let root = fixture()
  let account = empty()
  let (made, _) = installed(account, root)
  ok(!shows(made), ~message="a secret was in an argument or said")
  let driver = account.workers->Dict.getUnsafe(full("driver"))
  let object = account.workers->Dict.getUnsafe(full("object"))
  let database = account.workers->Dict.getUnsafe(full("database"))
  deepEqual(
    (driver.secrets, object.secrets, database.secrets),
    (
      dict{"API_TOKEN": "the-driver-token", "BINDING": hashed},
      dict{"BINDING": hashed},
      dict{"API_TOKEN": "the-database-token", "BINDING": hashed},
    ),
  )
  driver.secrets->Dict.delete("API_TOKEN")
  database.secrets->Dict.delete("API_TOKEN")
  let (faked, _) = installed(account, root)
  deepEqual(
    plain(faked)->Array.filter(l => l->String.includes("secret put")),
    [
      "wrangler secret put API_TOKEN --config <driver>",
      "wrangler secret put API_TOKEN --config <database>",
    ],
  )
  deepEqual(database.secrets->Dict.get("API_TOKEN"), Some("the-database-token"))
  ok(!shows(faked))
})

test("with nothing on stdin BINDING is passed over and said so", () => {
  let root = fixture()
  let account = empty()
  let (faked, result) = installed(~stdin=" \n", account, root)
  deepEqual(result, Ok())
  deepEqual(
    plain(faked)->Array.filter(l => l->String.includes("secret put")),
    [
      "wrangler secret put API_TOKEN --config <driver>",
      "wrangler secret put API_TOKEN --config <database>",
    ],
  )
  ok(faked.said->Array.includes("BINDING of driver-0a1b2c3d passed over, nothing on stdin"))
  ok(faked.said->Array.includes("BINDING of object-0a1b2c3d passed over, nothing on stdin"))
  ok(faked.said->Array.includes("BINDING of database-0a1b2c3d passed over, nothing on stdin"))
})

test("BINDING is keys' own BLAKE3 of the token's secret, in lowercase hex", () => {
  let own = Host.fromBytes(Keys.Hash.plain(secret))->Host.encoded("hex")
  deepEqual((Install.bindingHash(token), own), (Ok(hashed), hashed))
})

test("a token not of a binding's form is refused before anything runs", () => {
  let root = fixture()
  [
    "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
    "07.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
    "7.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh",
    "7.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh9",
    "7.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
  ]->Array.forEach(stdin => {
    let faked = make(~stdin, ~answer=_ => Ok(""))
    ok(Install.install(faked.world, ~dry=false, ~root)->Result.isError, ~message=stdin)
    deepEqual(faked.ran, [])
  })
})

test("each Worker is built in its own directory before it is bundled", () => {
  let root = fixture()
  let (faked, result) = installed(empty(), root)
  deepEqual(result, Ok())
  let lines = plain(faked)
  let at = line => lines->Array.indexOf(line)
  ["driver", "object", "database"]->Array.forEach(name => {
    let built = at(`rescript build in <${name}>`)
    ok(
      built >= 0 && built < at(`wrangler deploy --dry-run --outdir <out> --config <${name}>`),
      ~message=lines->Array.join("\n"),
    )
  })
})

test("DRIVER_API_TOKEN and DATABASE_API_TOKEN are in no command's environment", () => {
  let root = fixture()
  let (faked, result) = installed(empty(), root)
  deepEqual(result, Ok())
  ok(faked.ran->Array.length > 0)
  faked.ran->Array.forEach(command => {
    deepEqual(command.env->Dict.get("DRIVER_API_TOKEN"), None, ~message=line(command))
    deepEqual(command.env->Dict.get("DATABASE_API_TOKEN"), None, ~message=line(command))
    let values = command.env->Dict.valuesToArray
    ok(
      !(values->Array.includes("the-driver-token") || values->Array.includes("the-database-token")),
      ~message=line(command),
    )
    let wrangler =
      Host.basename(command.program) == "wrangler" && !(command.args->Array.includes("--dry-run"))
    deepEqual(
      (
        command.env->Dict.get("CLOUDFLARE_API_TOKEN"),
        command.env->Dict.get("CLOUDFLARE_ACCOUNT_ID"),
      ),
      wrangler ? (Some("the-install-token"), Some(accountId)) : (None, None),
      ~message=line(command),
    )
  })
  deepEqual(faked.world.env->Dict.get("DRIVER_API_TOKEN"), Some("the-driver-token"))
  deepEqual(faked.world.env->Dict.get("DATABASE_API_TOKEN"), Some("the-database-token"))
})

/** An install whose commands are answered by the account, the one `failing` names failed. */
let failedAt = (root, failing) => {
  let account = empty()
  let faked = make(~answer=command =>
    line(command)->String.includes(failing)
      ? Error(`${failing} failed`)
      : answered(account, command)
  )
  (faked, Install.install(faked.world, ~dry=false, ~root))
}

test("a step failing after a configuration of the moment is written leaves it removed", () => {
  let root = fixture()
  ["d1 migrations apply", "deploy --dry-run", "secret put BINDING"]->Array.forEach(failing => {
    let (faked, result) = failedAt(root, failing)
    deepEqual(result, Error(`${failing} failed`))
    ok(moments(root)->Array.every(path => !named(path)), ~message=failing)
    ok(faked.scratched->Array.every(path => !Host.existsSync(path)), ~message=failing)
  })
})

test("a configuration that cannot be read or written is answered, and nothing is left", () => {
  let root = fixture()
  Host.rmSync(
    Host.join([root, "cloudflare", "object", "wrangler.json"]),
    {recursive: false, force: true},
  )
  let (faked, result) = installed(empty(), root)
  ok(result->Result.isError && faked.scratched != [])
  ok(moments(root)->Array.every(path => !named(path)))
  ok(faked.scratched->Array.every(path => !Host.existsSync(path)))
  // A configuration of the moment linked into no directory cannot be written.
  let root = fixture()
  let object = Host.join([root, "cloudflare", "object", Install.moment])
  symlinkSync(Host.join([root, "nowhere", Install.moment]), object)
  let (faked, result) = installed(empty(), root)
  ok(result->Result.isError && faked.scratched != [])
  ok(moments(root)->Array.every(path => !named(path)))
  ok(faked.scratched->Array.every(path => !Host.existsSync(path)))
})

test("the databases and the bucket are placed by DRIVER_LOCATION, or by Cloudflare", () => {
  let creates = faked =>
    plain(faked)->Array.filter(l =>
      l->String.includes(" create ") && l->String.startsWith("wrangler")
    )
  let placed = [...credentials, ("DRIVER_LOCATION", "weur")]
  let (faked, result) = installed(~env=placed, empty(), fixture())
  deepEqual(result, Ok())
  deepEqual(
    creates(faked),
    [
      "wrangler d1 create driver-0a1b2c3d --location weur",
      "wrangler d1 create database-0a1b2c3d --location weur",
      "wrangler r2 bucket create objects-0a1b2c3d --location weur",
    ],
  )
  let (faked, result) = installed(empty(), fixture())
  deepEqual(result, Ok())
  deepEqual(
    creates(faked),
    [
      "wrangler d1 create driver-0a1b2c3d",
      "wrangler d1 create database-0a1b2c3d",
      "wrangler r2 bucket create objects-0a1b2c3d",
    ],
  )
  let dry = env => {
    let faked = make(~env, ~answer=command => Error(`ran ${line(command)}`))
    deepEqual(Install.install(faked.world, ~dry=true, ~root=fixture()), Ok())
    faked.said
  }
  let said = dry(placed)
  ok(said->Array.includes("the databases and the bucket placed by the hint weur, DRIVER_LOCATION"))
  let includes = text => said->Array.some(l => l->String.includes(text))
  ok(includes("wrangler d1 create driver-<install id> --location weur"))
  ok(includes("wrangler d1 create database-<install id> --location weur"))
  ok(includes("wrangler r2 bucket create objects-<install id> --location weur"))
  let said = dry(credentials)
  ok(said->Array.includes("no DRIVER_LOCATION, so Cloudflare places the databases and the bucket"))
  ok(said->Array.every(l => !(l->String.includes("--location"))), ~message=said->Array.join("\n"))
})

test("the install id is drawn where no driver-<8 hex> is listed, and reused where one is", () => {
  let account = empty()
  account.databases = ["driver", "driver-0A1B2C3D", "driver-0a1b2c3d-old", "objects-4e5f6a7b"]
  let (drawn, result) = installed(account, fixture())
  deepEqual(result, Ok())
  ok(
    drawn.said->Array.includes(
      "no driver's D1 holding its marker on the account, so the install id 0a1b2c3d is drawn",
    ),
  )
  ok(account.databases->Array.includes(full("driver")))
  // A second install draws another, which is never taken while one is listed.
  let (reused, result) = installed(~drawn="4e5f6a7b", account, fixture())
  deepEqual(result, Ok())
  ok(
    reused.said->Array.includes(
      "the install id 0a1b2c3d is reused, the account holding driver-0a1b2c3d",
    ),
  )
  ok(plain(reused)->Array.every(l => !(l->String.includes("4e5f6a7b"))))
})

test("more than one driver-<8 hex> is refused by name, and nothing is made", () => {
  let account = empty()
  account.databases = ["other"]
  account->holding("driver-0a1b2c3d", ~mark=id)
  account->holding("driver-4e5f6a7b", ~mark="4e5f6a7b")
  let (faked, result) = installed(account, fixture())
  deepEqual(
    result,
    Error(
      [
        "the account holds more than one driver's D1, driver-0a1b2c3d, driver-4e5f6a7b, ",
        "so none is chosen",
      ]->Array.join(""),
    ),
  )
  deepEqual(
    plain(faked),
    [
      "wrangler d1 list --json",
      tablesRead("driver-0a1b2c3d"),
      markerRead("driver-0a1b2c3d"),
      tablesRead("driver-4e5f6a7b"),
      markerRead("driver-4e5f6a7b"),
    ],
  )
})

test("a drawn id not of the id form is refused before anything is made", () => {
  let (faked, result) = installed(~drawn="0A1B2C3D", empty(), fixture())
  deepEqual(result, Error("an install id drawn is not 8 lowercase hex digits, 0A1B2C3D"))
  deepEqual(plain(faked), ["wrangler d1 list --json", workersListed])
})

let only = (kinds: option<string>) =>
  [
    ...credentials->Array.filter(((name, _)) =>
      name != "DRIVER_KINDS" && name != "DATABASE_API_TOKEN"
    ),
    ...kinds->Option.mapOr([], k => [("DRIVER_KINDS", k)]),
  ]

test(
  "function alone by default makes the driver's Worker and D1, and asks no database token",
  () => {
    let account = empty()
    let (faked, result) = installed(~env=only(None), account, fixture())
    deepEqual(result, Ok())
    deepEqual(
      plain(faked),
      [
        "wrangler d1 list --json",
        workersListed,
        "wrangler versions list --json --name object-0a1b2c3d",
        "wrangler versions list --json --name database-0a1b2c3d",
        "wrangler d1 list --json",
        "wrangler d1 create driver-0a1b2c3d",
        markerWritten("driver-0a1b2c3d"),
        "wrangler d1 list --json",
        "wrangler d1 migrations apply driver-0a1b2c3d --remote --config <driver>",
        "rescript build in <driver>",
        "wrangler deploy --dry-run --outdir <out> --config <driver>",
        "wrangler versions list --json --config <driver>",
        "wrangler deploy --config <driver> --tag <tag>",
        "wrangler secret list --config <driver>",
        "wrangler secret put API_TOKEN --config <driver>",
        "wrangler secret put BINDING --config <driver>",
      ],
    )
    ok(faked.said->Array.includes("the kinds offered are function, DRIVER_KINDS"))
    deepEqual((account.databases, account.buckets), ([full("driver")], []))
    let driver = account.workers->Dict.getUnsafe(full("driver"))
    let kinds =
      driver.deployed
      ->Array.get(0)
      ->Option.flatMap(Install.parsed)
      ->Option.map(config => config->Install.member("vars")->Install.text("KINDS"))
    deepEqual(kinds, Some(Some("function")))
  },
)

test("a kind listed on a rerun is added, and one dropped is named and left as it is", () => {
  let account = empty()
  let root = fixture()
  let _ = installed(~env=only(None), account, root)
  let (added, result) = installed(~env=only(Some("object,function")), account, root)
  deepEqual(result, Ok())
  deepEqual(
    plain(added)->Array.filter(l =>
      l->String.includes(" create ") || l->String.startsWith("wrangler deploy --config")
    ),
    [
      "wrangler r2 bucket create objects-0a1b2c3d",
      "wrangler deploy --config <driver> --tag <tag>",
      "wrangler deploy --config <object> --tag <tag>",
    ],
  )
  ok(added.said->Array.includes("the kinds offered are function, object, DRIVER_KINDS"))
  let (dropped, result) = installed(~env=only(Some("function")), account, root)
  deepEqual(result, Ok())
  ok(plain(dropped)->Array.every(l => !(l->String.includes("delete"))))
  deepEqual(account.buckets, [full("objects")])
  ok(
    dropped.said->Array.includes(
      [
        "object is not offered, and object-0a1b2c3d and the bucket objects-0a1b2c3d ",
        "are left as they are;",
      ]->Array.join(""),
    ),
    ~message=dropped.said->Array.join("\n"),
  )
  ok(dropped.said->Array.every(l => !(l->String.includes("database-0a1b2c3d and"))))
})

test("DRIVER_KINDS naming anything but function, object and database is refused", () => {
  ["function,instance", "function,", "Function", "function object"]->Array.forEach(kinds => {
    let faked = make(~env=only(Some(kinds)), ~answer=_ => Ok(""))
    ok(Install.install(faked.world, ~dry=false, ~root=fixture())->Result.isError, ~message=kinds)
    deepEqual(faked.ran, [])
  })
})

test("no ambient CLOUDFLARE_ name reaches a command, wrangler given install's own", () => {
  let (faked, result) = installed(~env=[...ambient, ...credentials], empty(), fixture())
  deepEqual(result, Ok())
  ok(!shows(faked))
  faked.ran->Array.forEach(command => {
    let values = command.env->Dict.valuesToArray
    ok(
      !(values->Array.includes("the-ambient-token") || values->Array.includes(anotherAccount)),
      ~message=line(command),
    )
    deepEqual(command.env->Dict.get("CLOUDFLARE_EMAIL"), None)
    deepEqual(command.env->Dict.get("DRIVER_INSTALL_TOKEN"), None)
  })
  ok(
    faked.ran->Array.some(c =>
      c.env->Dict.get("CLOUDFLARE_API_TOKEN") == Some("the-install-token")
    ),
  )
})

test("no CF_ name reaches a command, and wrangler is pointed at an empty env file", () => {
  let root = fixture()
  // A .env wrangler would load from where it runs, were it not given the empty file instead.
  let dotEnv = "CLOUDFLARE_API_KEY=the-dotenv-key\nCLOUDFLARE_EMAIL=dotenv@example.com\n"
  ["", "cloudflare", "cloudflare/object", "cloudflare/database"]->Array.forEach(dir =>
    Host.writeFileSync(Host.join([root, dir, ".env"]), dotEnv)
  )
  let legacy = [
    ("CF_API_KEY", "the-legacy-key"),
    ("CF_EMAIL", "legacy@example.com"),
    ("CF_API_BASE_URL", "https://api.example/client/v4"),
  ]
  let (faked, result) = installed(~env=[...legacy, ...credentials], empty(), root)
  deepEqual(result, Ok())
  faked.ran->Array.forEach(command => {
    let names = command.env->Dict.keysToArray
    deepEqual(
      names->Array.filter(name => name->String.startsWith("CF_")),
      [],
      ~message=line(command),
    )
    let values = command.env->Dict.valuesToArray
    ok(legacy->Array.every(((_, v)) => !(values->Array.includes(v))), ~message=line(command))
    if Host.basename(command.program) == "wrangler" {
      deepEqual(command.args->Array.slice(~start=-2), ["--env-file", "/dev/null"])
    }
  })
})

test("the bundle is written in the quiet environment, given no account and no token", () => {
  let (faked, result) = installed(empty(), fixture())
  deepEqual(result, Ok())
  let bundles = faked.ran->Array.filter(c => c.args->Array.includes("--dry-run"))
  deepEqual(Array.length(bundles), 3)
  bundles->Array.forEach(command =>
    deepEqual(
      (
        command.env->Dict.get("CLOUDFLARE_API_TOKEN"),
        command.env->Dict.get("CLOUDFLARE_ACCOUNT_ID"),
      ),
      (None, None),
    )
  )
})

test("a D1 list that is no JSON array is an error, never an empty account", () => {
  let lists = ref(0)
  let account = empty()
  let unreadAt = at =>
    command =>
      if line(command) == "wrangler d1 list --json" {
        lists := lists.contents + 1
        lists.contents == at ? Ok("not JSON") : answered(account, command)
      } else {
        answered(account, command)
      }
  let refused = Error("d1 list printed no JSON array, so the account's databases are not known")
  // The first list is recovery's, the second the driver's D1's, after the checks.
  [1, 2]->Array.forEach(at => {
    lists := 0
    let faked = make(~answer=unreadAt(at))
    deepEqual(Install.install(faked.world, ~dry=false, ~root=fixture()), refused)
    ok(plain(faked)->Array.every(l => !(l->String.includes(" create "))))
  })
})

/** Whether a line run changes anything, on the account or in the checkout. */
let writes = l =>
  [
    " create ",
    "migrations apply",
    "CREATE TABLE",
    "deploy",
    "secret put",
    "rescript build",
  ]->Array.some(w => l->String.includes(w))

/** That nothing was changed, no line written and no scratch directory made. */
let unchanged = faked => {
  let lines = plain(faked)
  ok(lines->Array.every(l => !writes(l)), ~message=lines->Array.join("\n"))
  deepEqual(faked.scratched, [])
}

test("a dropped kind's lookup failing otherwise than not found stops install, nothing run", () => {
  let account = empty()
  let answer = command =>
    line(command) == "wrangler versions list --json --name object-0a1b2c3d"
      ? Error("Authentication error [code: 10000]")
      : answered(account, command)
  let faked = make(~env=only(None), ~answer)
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("whether object-0a1b2c3d is there is not known, Authentication error [code: 10000]"),
  )
  unchanged(faked)
  deepEqual((account.databases, account.buckets, account.marks), ([], [], dict{}))
})

test("a driver-<8 hex> holding no marker is foreign, passed over and never written", () => {
  let root = fixture()
  let account = empty()

  // One holds a table of its own and no marker, another a marker naming another install.
  account.databases = ["driver-20261024"]
  account.own->Dict.set("driver-20261024", ["notes"])
  account->holding("driver-4e5f6a7b", ~mark="0a1b2c3d")
  let foreign = ["driver-20261024", "driver-4e5f6a7b"]
  let (dry, result) = dryOn(account, root)
  deepEqual(result, Ok())
  foreign->Array.forEach(name =>
    ok(
      dry.said->Array.includes(
        `${name} holds no driver's marker, so it is passed over and never written`,
      ),
      ~message=dry.said->Array.join("\n"),
    )
  )
  ok(dry.said->Array.some(l => l->String.includes("so a new install id would be drawn")))
  let (faked, result) = installed(~draws=["5c6d7e8f"], account, root)
  deepEqual(result, Ok())
  let lines = plain(faked)
  deepEqual(
    foreign->Array.map(name => lines->Array.filter(l => l->String.includes(name))),
    [
      [tablesRead("driver-20261024")],
      [tablesRead("driver-4e5f6a7b"), markerRead("driver-4e5f6a7b")],
    ],
  )
  ok(
    faked.said->Array.includes(
      "no driver's D1 holding its marker on the account, so the install id 5c6d7e8f is drawn",
    ),
  )
  deepEqual(
    (account.marks->Dict.get("driver-20261024"), account.marks->Dict.get("driver-4e5f6a7b")),
    (None, Some("0a1b2c3d")),
  )
  deepEqual(account.marks->Dict.get("driver-5c6d7e8f"), Some("5c6d7e8f"))
  // The next install reuses the one marked, the foreign ones still passed over.
  let (again, result) = installed(~draws=["6e7f8a9b"], account, root)
  deepEqual(result, Ok())
  ok(
    again.said->Array.includes(
      "the install id 5c6d7e8f is reused, the account holding driver-5c6d7e8f",
    ),
  )
})

test("a driver-<8 hex> holding no table is said as possibly interrupted, and never touched", () => {
  let root = fixture()
  let account = empty()
  account.databases = ["driver-4e5f6a7b"]
  let said =
    [
      "driver-4e5f6a7b holds no tables, possibly an interrupted install of this driver;",
      " delete it by hand if it is yours",
    ]->Array.join("")
  let (dry, result) = dryOn(account, root)
  deepEqual(result, Ok())
  ok(dry.said->Array.includes(said), ~message=dry.said->Array.join("\n"))
  ok(dry.said->Array.some(l => l->String.includes("so a new install id would be drawn")))
  let (faked, result) = installed(~draws=["4e5f6a7b", "5c6d7e8f"], account, root)
  deepEqual(result, Ok())
  ok(faked.said->Array.includes(said), ~message=faked.said->Array.join("\n"))
  deepEqual(
    plain(faked)->Array.filter(l => l->String.includes("driver-4e5f6a7b")),
    [tablesRead("driver-4e5f6a7b")],
  )
  deepEqual(
    (account.marks->Dict.get("driver-4e5f6a7b"), account.migrated),
    (None, ["driver-5c6d7e8f"]),
  )
  deepEqual(account.marks->Dict.get("driver-5c6d7e8f"), Some("5c6d7e8f"))
})

test("the marker is written right after the D1 is made, before its first migration", () => {
  let account = empty()
  let (faked, result) = installed(account, fixture())
  deepEqual(result, Ok())
  let lines = plain(faked)
  let at = line => lines->Array.indexOf(line)
  let created = at("wrangler d1 create driver-0a1b2c3d")
  deepEqual(
    (at(markerWritten("driver-0a1b2c3d")) - created, created >= 0),
    (1, true),
    ~message=lines->Array.join("\n"),
  )
  ok(
    at(markerWritten("driver-0a1b2c3d")) <
    at("wrangler d1 migrations apply driver-0a1b2c3d --remote --config <driver>"),
  )
  deepEqual(account.marks->Dict.get(full("driver")), Some(id))
  // A reused D1 is never marked again, and one listed though its id was drawn is refused.
  let (again, _) = installed(account, fixture())
  ok(plain(again)->Array.every(l => l != markerWritten("driver-0a1b2c3d")))
  let raced = empty()
  let lists = ref(0)
  let faked = make(~answer=command =>
    if line(command) == "wrangler d1 list --json" {
      lists := lists.contents + 1

      // The second list, the driver's D1's own, sees one made since the survey.
      if lists.contents == 2 {
        raced.databases->Array.push(full("driver"))
      }
      answered(raced, command)
    } else {
      answered(raced, command)
    }
  )
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("driver-0a1b2c3d is listed already, though its install id was drawn as free"),
  )
  deepEqual(raced.marks, dict{})
})

test("a drawn id is drawn again while a D1's or a Worker's name ends in it", () => {
  let account = empty()
  account.databases = ["objects-0a1b2c3d"]
  account->running("app-7-4e5f6a7b")
  let (faked, result) = installed(~draws=["0a1b2c3d", "4e5f6a7b", "5c6d7e8f"], account, fixture())
  deepEqual(result, Ok())
  let taken = id => `the install id ${id} drawn ends a name the account holds, so another is drawn`
  ok(faked.said->Array.includes(taken("0a1b2c3d")), ~message=faked.said->Array.join("\n"))
  ok(faked.said->Array.includes(taken("4e5f6a7b")))
  ok(account.databases->Array.includes("driver-5c6d7e8f"))
  deepEqual(plain(faked)->Array.filter(l => l == workersListed)->Array.length, 1)
  // An account where every draw is taken is refused, nothing made.
  let account = empty()
  account.databases = ["objects-0a1b2c3d"]
  let (faked, result) = installed(account, fixture())
  deepEqual(result, Error("no install id drawn was free in 8 draws"))
  unchanged(faked)
})

test("a marker read failing otherwise than for want of a marker stops install, nothing run", () => {
  let account = empty()
  account->holding("driver-0a1b2c3d", ~mark=id)
  let answer = command =>
    line(command) == markerRead("driver-0a1b2c3d")
      ? Error("Authentication error [code: 10000]")
      : answered(account, command)
  let faked = make(~answer)
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("the marker of driver-0a1b2c3d is not known, Authentication error [code: 10000]"),
  )
  unchanged(faked)
  let faked = make(~answer=command =>
    line(command) == markerRead("driver-0a1b2c3d") ? Ok("not JSON") : answered(account, command)
  )
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("the marker of driver-0a1b2c3d is not known, d1 execute printed no JSON array"),
  )
  unchanged(faked)
})

test("a Workers list that cannot be read stops install before anything is made", () => {
  let account = empty()
  let faked = make(~answer=command =>
    line(command) == workersListed ? Ok("not JSON") : answered(account, command)
  )
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("the Workers list printed no result array, so the account's Workers are not known"),
  )
  unchanged(faked)
  let listing = faked.ran->Array.find(c => line(c) == workersListed)
  deepEqual(listing->Option.flatMap(c => c.input), Some("Authorization: Bearer the-install-token"))
})

test("curl is given -q first, so it reads no .curlrc", () => {
  let (faked, result) = installed(empty(), fixture())
  deepEqual(result, Ok())
  let listing = faked.ran->Array.find((c: Install.command) => Host.basename(c.program) == "curl")
  deepEqual(listing->Option.flatMap(c => c.args->Array.get(0)), Some("-q"))
})

test("a Workers list answered in pages, or not a success, stops install with nothing made", () => {
  let answer = (account, body) =>
    (command: Install.command) =>
      Host.basename(command.program) == "curl" ? Ok(body) : answered(account, command)
  let answers = [
    (
      `{"success":true,"result":[{"id":"app-7-4e5f6a7b"}],
        "result_info":{"page":1,"total_pages":2}}`,
      "came in pages and was not read whole",
    ),
    (
      `{"success":true,"result":[],"result_info":{"count":20,"total_count":21}}`,
      "came in pages and was not read whole",
    ),
    (
      `{"success":true,"result":[],"result_info":{"cursor":"6Ck1la0VxJ0djhidm1MdX2FyD"}}`,
      "came in pages and was not read whole",
    ),
    (
      `{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"result":null}`,
      "did not succeed",
    ),
  ]
  answers->Array.forEach(((body, why)) => {
    let account = empty()
    let faked = make(~answer=answer(account, body))
    deepEqual(
      Install.install(faked.world, ~dry=false, ~root=fixture()),
      Error(`the Workers list ${why}, so the account's Workers are not known`),
      ~message=body,
    )
    unchanged(faked)
  })
  // One page whole, as the documentation shows every answer, is read.
  let account = empty()
  let whole = `{"success":true,"result":[],"result_info":{"page":1,"total_pages":1}}`
  let faked = make(~answer=answer(account, whole))
  deepEqual(Install.install(faked.world, ~dry=false, ~root=fixture()), Ok())
})

test("a D1's tables read failing stops install, nothing run", () => {
  let account = empty()
  account.databases = ["driver-4e5f6a7b"]
  let faked = make(~answer=command =>
    line(command) == tablesRead("driver-4e5f6a7b")
      ? Error("Authentication error [code: 10000]")
      : answered(account, command)
  )
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("the marker of driver-4e5f6a7b is not known, Authentication error [code: 10000]"),
  )
  unchanged(faked)
})

after(() => fixtures->Array.forEach(root => Host.rmSync(root, {recursive: true, force: true})))
