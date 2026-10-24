/***
 * driver(cloudflare) made on the account its inputs name, each part only where it is absent and
 * named by its install id, RFC nrs5v's Ledger, every command run through a world a test fakes.
 */
open Host

let usage = "install [--dry-run]"

let root = join([fileURLToPath(importMetaUrl), "..", ".."])

/** The names nrs5v gives each part, the driver's D1 and the binding's one database. */
let database = "driver"
let userDatabase = "database"
let bucket = "objects"

/** What it is given, read from the environment alone, as this repository is public. */
let account = "DRIVER_ACCOUNT_ID"
let installToken = "DRIVER_INSTALL_TOKEN"
let driverToken = "DRIVER_API_TOKEN"
let databaseToken = "DATABASE_API_TOKEN"
let kindsInput = "DRIVER_KINDS"

/** The names wrangler reads, set in its own environment alone and never read from install's. */
let wranglerToken = "CLOUDFLARE_API_TOKEN"
let wranglerAccount = "CLOUDFLARE_ACCOUNT_ID"

/** The prefixes of every sign-in name wrangler reads, its legacy `CF_` names among them. */
let ambient = ["CLOUDFLARE_", "CF_"]

/** The file wrangler loads in place of `.env` and `.env.local`, which holds nothing. */
let noEnvFile = ["--env-file", "/dev/null"]

/** The tokens kept out of every command's environment by their own names. */
let tokens = [installToken, driverToken, databaseToken]

/** The kinds the driver may offer, `function` alone where `DRIVER_KINDS` names none. */
let kinds = ["function", "object", "database"]
let defaultKinds = ["function"]

@module("node:crypto") external randomBytes: int => Uint8Array.t = "randomBytes"

/** An install id, 8 lowercase hex digits. */
let installIdForm = /^[0-9a-f]{8}$/

/** A D1 name in the driver's form, `driver-<8 hex>`, its own only where it holds its marker. */
let driverForm = /^driver-([0-9a-f]{8})$/

/** A part's name followed by the install id. */
let named = (name, ~id) => `${name}-${id}`

/** The hint the database and the bucket are placed by, none given letting Cloudflare place them. */
let location = "DRIVER_LOCATION"

/** Where a secret's value comes from, a variable of the environment or the binding's hash. */
type source = Environment(string) | Bound

/** A Worker, its directory beneath the root and the secrets it is given by name. */
type worker = {name: string, directory: array<string>, secrets: array<(string, source)>}

/** What one install acts on, its install id and the kinds it offers. */
type install = {id: string, kinds: array<string>}

let offers = (install, kind) => install.kinds->Array.includes(kind)

let apiToken = "API_TOKEN"
let binding = "BINDING"
let driver = {
  name: "driver",
  directory: ["cloudflare"],
  secrets: [(apiToken, Environment(driverToken)), (binding, Bound)],
}
let object = {name: "object", directory: ["cloudflare", "object"], secrets: [(binding, Bound)]}
let databaseWorker = {
  name: "database",
  directory: ["cloudflare", "database"],
  secrets: [(apiToken, Environment(databaseToken)), (binding, Bound)],
}

/** The configuration of the moment, written beside a Worker's own and removed after. */
let moment = "wrangler.install.json"

/** A command, what is written to its stdin, the one way a secret is ever handed to it. */
type command = {
  program: string,
  args: array<string>,
  cwd: string,
  input?: string,
  env: Dict.t<string>,
}

/** Everything install does outside itself, so a test answers it. */
type world = {
  run: command => result<string, string>,
  env: Dict.t<string>,
  say: string => unit,
  /** What stdin holds, empty where it is a terminal. */
  stdin: unit => string,
  /** A directory of its own, made empty. */
  scratch: unit => string,
  /** A new install id drawn at random. */
  draw: unit => string,
}

let then = (result, next) => result->Result.flatMap(next)

let value = (env, name) => env->Dict.get(name)->Option.filter(v => v != "")

/** A command as a dry run prints it, its program's name and arguments, stdin said, never shown. */
let shown = command => {
  let line = [basename(command.program), ...command.args]->Array.join(" ")
  command.input->Option.isSome ? `${line}, its value on stdin` : line
}

/**
 * The environment the commands run in, quiet and unasking, every token and every ambient
 * `CLOUDFLARE_` or `CF_` name taken out.
 */
let quiet = env => {
  let given = Dict.copy(env)
  given
  ->Dict.keysToArray
  ->Array.forEach(name =>
    if (
      ambient->Array.some(prefix => name->String.startsWith(prefix)) || tokens->Array.includes(name)
    ) {
      given->Dict.delete(name)
    }
  )
  given->Dict.set("WRANGLER_SEND_METRICS", "false")
  given->Dict.set("CI", "1")
  given
}

/** The environment wrangler runs in, its account and token set from install's own inputs. */
let accounted = env => {
  let given = quiet(env)
  given->Dict.set(wranglerToken, value(env, installToken)->Option.getOr(""))
  given->Dict.set(wranglerAccount, value(env, account)->Option.getOr(""))
  given
}

/** A wrangler command run in `cwd` reading no `.env`, wrangler being the cloudflare block's. */
let wrangler = (~root, ~cwd, ~env, arguments) => {
  program: join([root, "cloudflare", "node_modules", ".bin", "wrangler"]),
  args: [...arguments, ...noEnvFile],
  cwd,
  env,
}

/** A command of the account's, given install's own account and token alone. */
let commanded = (w, ~root, ~cwd, arguments) =>
  wrangler(~root, ~cwd, ~env=accounted(w.env), arguments)

/** A Worker's package compiled in its directory, so its bundle is this checkout's source. */
let compiled = (w, ~dry, ~root, ~directory, worker) => {
  let build = {
    program: join([root, "node_modules", ".bin", "rescript"]),
    args: ["build"],
    cwd: directory,
    env: quiet(w.env),
  }
  if dry {
    w.say(`would run ${shown(build)} in ${worker.directory->Array.join("/")}`)
    Ok()
  } else {
    w.run(build)->Result.map(_ => w.say(`the Worker ${worker.name} built`))
  }
}

/** The arguments placing a part by the hint `DRIVER_LOCATION` gives, none where it gives none. */
let placed = w =>
  switch value(w.env, location) {
  | Some(hint) => ["--location", hint]
  | None => []
  }

/** A JSON object's member, or null. */
let member = (json, name) =>
  json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(name))->Option.getOr(JSON.Null)
let text = (json, name) => json->member(name)->JSON.Decode.string

let parsed = body =>
  switch JSON.parseOrThrow(body) {
  | json => Some(json)
  | exception JsExn(_) => None
  }

let idForm = /^(0|[1-9][0-9]*)$/
let secretForm = /^[A-Za-z0-9_-]{43}$/

/** The BLAKE3 in lowercase hex of a binding token's secret, `<id>.<secret>`, as bearer.res reads
 * it. */
let bindingHash = token =>
  switch token->String.split(".") {
  | [id, secret] if idForm->RegExp.test(id) && secretForm->RegExp.test(secret) =>
    let bytes = fromEncoded(secret, "base64url")
    // Only the one spelling of 32 bytes, so a secret with stray low bits is never taken.
    TypedArray.length(bytes) == 32 && fromBytes(bytes)->encoded("base64url") == secret
      ? Ok(fromBytes(Keys.Hash.plain(bytes))->encoded("hex"))
      : Error("the token on stdin holds no secret of 32 bytes")
  | _ => Error("the token on stdin is not <id>.<secret>, its secret 32 bytes in unpadded base64url")
  }

/** What `d1 list --json` prints, an array, or an error where it is anything else. */
let listed = body =>
  switch parsed(body)->Option.flatMap(JSON.Decode.array) {
  | Some(all) => Ok(all)
  | None => Error("d1 list printed no JSON array, so the account's databases are not known")
  }

/** A database's id where `d1 list` holds one by its name. */
let listedDatabase = (body, name) =>
  listed(body)->Result.map(all =>
    all
    ->Array.find(db => db->text("name") == Some(name))
    ->Option.flatMap(db => db->text("uuid"))
  )

/** The names `d1 list` holds, and nothing more of any database. */
let listedNames = body =>
  listed(body)->Result.map(all => all->Array.filterMap(db => db->text("name")))

/** The install id a name in the driver's D1 form ends in, `driver-<8 hex>`. */
let suffixOf = name =>
  driverForm
  ->RegExp.exec(name)
  ->Option.flatMap(found => found->RegExp.Result.matches->Array.get(0)->Option.flatMap(id => id))

/** The read-only query of a D1's tables, which says whether it holds the marker's table. */
let tablesQuery = "SELECT name FROM sqlite_master WHERE type = 'table'"

/** The read-only query of the driver's marker, the install id its table `install` holds. */
let markerQuery = "SELECT id FROM install WHERE one = 1"

/** The marker's table made and its one row written, the first statement a new D1 runs. */
let markerWrite = id =>
  [
    "CREATE TABLE install (one INTEGER PRIMARY KEY CHECK (one = 1), id TEXT NOT NULL);",
    `INSERT INTO install (one, id) VALUES (1, '${id}')`,
  ]->Array.join(" ")

/** The rows `d1 execute --json` printed for its one statement. */
let rowsOf = body =>
  switch parsed(body)->Option.flatMap(JSON.Decode.array) {
  | None => Error("d1 execute printed no JSON array")
  | Some(answers) =>
    switch answers->Array.get(0)->Option.flatMap(a => a->member("results")->JSON.Decode.array) {
    | Some(rows) => Ok(rows)
    | None => Error("d1 execute printed no results")
    }
  }

/** A table SQLite or Cloudflare keeps in every D1, never one a migration or install made. */
let internal = name => name->String.startsWith("_cf_") || name->String.startsWith("sqlite_")

/** The tables a D1 holds, its internal ones left out. */
let tablesOf = body =>
  rowsOf(body)->Result.map(rows =>
    rows->Array.filterMap(row => row->text("name"))->Array.filter(name => !internal(name))
  )

/** The install id `d1 execute --json` printed for the marker query, None where it holds none. */
let markOf = body =>
  rowsOf(body)->Result.map(rows => rows->Array.get(0)->Option.flatMap(row => row->text("id")))

/** What the account's D1 list and markers say, read alone before anything is written. */
type surveyed = {
  /** Every D1's name, so a drawn id is drawn again while one ends in it. */
  names: array<string>,
  /** The install ids of the D1s in the driver's form holding the driver's marker. */
  marked: array<string>,
  /** The names in the driver's form holding tables but no marker, passed over. */
  foreign: array<string>,
  /** The names in the driver's form holding no table at all, passed over and said apart. */
  empty: array<string>,
}

/** What one D1 in the driver's form holds, read by its tables and then its marker. */
type held = Marked(string) | Foreign | Empty

/** One D1 in the driver's form read, its marker only where its tables hold `install`. */
let heldIn = (w, ~root, name) => {
  let known = result => result->Result.mapError(why => `the marker of ${name} is not known, ${why}`)
  let execute = ["d1", "execute", name, "--remote", "--command"]
  let read = query => w.run(commanded(w, ~root, ~cwd=root, [...execute, query, "--json"]))->known
  read(tablesQuery)
  ->then(body => known(tablesOf(body)))
  ->then(tables =>
    switch tables {
    | [] => Ok(Empty)
    | tables if tables->Array.includes("install") =>
      read(markerQuery)
      ->then(body => known(markOf(body)))
      ->Result.map(mark => mark->Option.mapOr(Foreign, mark => Marked(mark)))
    | _ => Ok(Foreign)
    }
  )
}

/**
 * The account's D1 list, each name in the driver's form read for its marker, its install id equal
 * to the name's suffix, any read failing refused.
 */
let surveyed = (w, ~root) =>
  w.run(commanded(w, ~root, ~cwd=root, ["d1", "list", "--json"]))
  ->then(listedNames)
  ->then(names =>
    names
    ->Array.filterMap(name => suffixOf(name)->Option.map(id => (name, id)))
    ->Array.reduce(Ok({names, marked: [], foreign: [], empty: []}), (done, (name, id)) =>
      done->then(
        survey =>
          heldIn(w, ~root, name)->Result.map(
            held =>
              switch held {
              | Marked(mark) if mark == id => {...survey, marked: [...survey.marked, id]}
              | Marked(_) | Foreign => {...survey, foreign: [...survey.foreign, name]}
              | Empty => {...survey, empty: [...survey.empty, name]}
              },
          ),
      )
    )
  )

/** Each foreign D1 said, and each empty one as possibly an interrupted install, none written. */
let passedOver = (w, survey) => {
  survey.foreign->Array.forEach(name =>
    w.say(`${name} holds no driver's marker, so it is passed over and never written`)
  )
  survey.empty->Array.forEach(name =>
    w.say(
      [
        `${name} holds no tables, possibly an interrupted install of this driver;`,
        " delete it by hand if it is yours",
      ]->Array.join(""),
    )
  )
}

/** The Workers the account holds, by Cloudflare's documented List Workers, read alone. */
let workersList = (w, ~root) => {
  program: "curl",
  // `-q` first, so curl reads no .curlrc.
  args: [
    "-q",
    "--silent",
    "--show-error",
    "--fail-with-body",
    "--header",
    "@-",
    `https://api.cloudflare.com/client/v4/accounts/${value(w.env, account)->Option.getOr(
        "",
      )}/workers/scripts`,
  ],
  cwd: root,
  // The token reaches curl on stdin alone, as a header, never in an argument.
  input: `Authorization: Bearer ${value(w.env, installToken)->Option.getOr("")}`,
  env: quiet(w.env),
}

/** Whether an answer says it holds one page of more, as no documented List Workers answer does. */
let paged = json => {
  let info = json->member("result_info")
  let number = name => info->member(name)->JSON.Decode.float
  switch (number("total_pages"), number("count"), number("total_count")) {
  | (Some(pages), _, _) if pages > 1. => true
  | (_, Some(count), Some(total)) if count < total => true
  | _ => info->text("cursor")->Option.mapOr(false, cursor => cursor != "")
  }
}

/**
 * The names List Workers answered, each script's id, its answer one page by the documentation,
 * developers.cloudflare.com/api/resources/workers/subresources/scripts/methods/list, read whole.
 */
let listedWorkers = body => {
  let unknown = why => Error(`the Workers list ${why}, so the account's Workers are not known`)
  switch parsed(body) {
  | Some(json) if json->member("success") != JSON.Boolean(true) => unknown("did not succeed")
  | Some(json) if paged(json) => unknown("came in pages and was not read whole")
  | Some(json) =>
    switch json->member("result")->JSON.Decode.array {
    | Some(all) => Ok(all->Array.filterMap(script => script->text("id")))
    | None => unknown("printed no result array")
    }
  | None => unknown("printed no result array")
  }
}

/** How many ids are drawn at most before install gives up. */
let draws = 8

/** An id drawn and drawn again while a D1's or a Worker's name ends in it. */
let drawn = (w, ~root, ~names) =>
  w.run(workersList(w, ~root))
  ->then(listedWorkers)
  ->then(workers => {
    let taken = id => [...names, ...workers]->Array.some(name => name->String.endsWith(`-${id}`))
    let rec draw = left =>
      switch w.draw() {
      | id if !(installIdForm->RegExp.test(id)) =>
        Error(`an install id drawn is not 8 lowercase hex digits, ${id}`)
      | id if taken(id) && left > 1 =>
        w.say(`the install id ${id} drawn ends a name the account holds, so another is drawn`)
        draw(left - 1)
      | id if taken(id) => Error(`no install id drawn was free in ${Int.toString(draws)} draws`)
      | id => Ok(id)
      }
    draw(draws)
  })

/** The rule, said where a dry run cannot say which install id. */
let rule = w => {
  w.say(`  it reuses the install id of the one driver-<8 hex> holding the driver's marker, draws a`)
  w.say(`  new one where none does, and refuses where more than one does`)
}

let more = marked => {
  let all = marked->Array.map(id => named(database, ~id))->Array.join(", ")
  Error(`the account holds more than one driver's D1, ${all}, so none is chosen`)
}

/** The install id read from the D1s' markers alone, drawn where none is marked, reused where one
 * is, and refused where more are, with whether it was drawn so the new D1 is marked. */
let recovered = (w, ~dry, ~root) =>
  if dry {
    // A dry run writes nothing, so it reads the list and the markers alone, given the account.
    let unknown = () => Ok(("<install id>", true))
    switch [account, installToken]->Array.filter(name => value(w.env, name) == None) {
    | [] =>
      switch surveyed(w, ~root) {
      | Ok(survey) =>
        passedOver(w, survey)
        switch survey.marked {
        | [] =>
          let none = "d1 list names no driver's D1 holding its marker"
          w.say(`${none}, so a new install id would be drawn`)
          w.say(`  by ${shown(workersList(w, ~root))}, again while a D1 or a Worker ends in it`)
          unknown()
        | [id] =>
          w.say(`d1 list names ${named(database, ~id)}, so the install id ${id} would be reused`)
          Ok((id, false))
        | marked => more(marked)
        }
      | Error(why) =>
        w.say(`the install id is not known, as ${why};`)
        rule(w)
        unknown()
      }
    | unset =>
      w.say(`the install id is not known, as ${unset->Array.join(" and ")} unset;`)
      rule(w)
      unknown()
    }
  } else {
    surveyed(w, ~root)->then(survey => {
      passedOver(w, survey)
      switch survey.marked {
      | [] =>
        drawn(w, ~root, ~names=survey.names)->Result.map(id => {
          w.say(
            `no driver's D1 holding its marker on the account, so the install id ${id} is drawn`,
          )
          (id, true)
        })
      | [id] =>
        w.say(`the install id ${id} is reused, the account holding ${named(database, ~id)}`)
        Ok((id, false))
      | marked => more(marked)
      }
    })
  }

/** The buckets `r2 bucket list` prints, each on a line of its own beginning `name`. */
let listedBuckets = body =>
  body
  ->String.split("\n")
  ->Array.filterMap(line =>
    switch line->String.trim->String.split(":") {
    | ["name", name] => Some(name->String.trim)
    | _ => None
    }
  )

/**
 * A database made with its hint where the account lists none by its name, and its id, marked with
 * `marker` by its first statement where one is given, so it must be made here.
 */
let databaseOf = (w, ~dry, ~root, ~marker=?, database) => {
  let list = commanded(w, ~root, ~cwd=root, ["d1", "list", "--json"])
  let create = commanded(w, ~root, ~cwd=root, ["d1", "create", database, ...placed(w)])
  let marking =
    marker->Option.map(id =>
      commanded(
        w,
        ~root,
        ~cwd=root,
        ["d1", "execute", database, "--remote", "--command", markerWrite(id)],
      )
    )
  let marked = () =>
    switch marking {
    | Some(write) => w.run(write)->Result.map(_ => w.say(`${database} marked as the driver's`))
    | None => Ok()
    }
  if dry {
    w.say(`would run ${shown(list)}, and ${shown(create)} unless ${database} is listed`)
    marking->Option.forEach(write =>
      w.say(`  and right after it ${shown(write)}, before any migration`)
    )
    Ok(`<${database}'s id>`)
  } else {
    switch w.run(list)->then(body => listedDatabase(body, database)) {
    | Error(why) => Error(why)
    | Ok(Some(_)) if marking != None =>
      Error(`${database} is listed already, though its install id was drawn as free`)
    | Ok(Some(id)) =>
      w.say(`the database ${database} is there already`)
      Ok(id)
    | Ok(None) =>
      w.run(create)
      ->then(_ => marked())
      ->then(_ => w.run(list))
      ->then(body => listedDatabase(body, database))
      ->then(found =>
        switch found {
        | Some(id) =>
          w.say(`the database ${database} made`)
          Ok(id)
        | None => Error(`${database} made but not listed`)
        }
      )
    }
  }
}

/** The bucket made with its hint where the account lists none by its name. */
let bucketOf = (w, ~dry, ~root, ~bucket) => {
  let list = commanded(w, ~root, ~cwd=root, ["r2", "bucket", "list"])
  let create = commanded(w, ~root, ~cwd=root, ["r2", "bucket", "create", bucket, ...placed(w)])
  if dry {
    w.say(`would run ${shown(list)}, and ${shown(create)} unless ${bucket} is listed`)
    Ok()
  } else {
    switch w.run(list)->Result.map(listedBuckets) {
    | Error(why) => Error(why)
    | Ok(names) if names->Array.includes(bucket) =>
      w.say(`the bucket ${bucket} is there already`)
      Ok()
    | Ok(_) => w.run(create)->Result.map(_ => w.say(`the bucket ${bucket} made`))
    }
  }
}

/** Each of a configuration's entries under `key` with `change` made to its object. */
let eachOf = (filled, config, key, change) =>
  config
  ->Dict.get(key)
  ->Option.flatMap(JSON.Decode.array)
  ->Option.forEach(entries =>
    filled->Dict.set(
      key,
      JSON.Array(
        entries->Array.map(entry =>
          switch entry->JSON.Decode.object {
          | Some(o) =>
            let d = Dict.copy(o)
            change(d)
            JSON.Object(d)
          | None => entry
          }
        ),
      ),
    )
  )

/**
 * A Worker's own configuration with its name, its databases' and its bucket's followed by the
 * install id, each D1 database's real id by its name, and the variables given set beside its own.
 */
let configured = (given, ~id, ~ids: dict<string>, ~vars as set: dict<string>) =>
  switch parsed(given)->Option.flatMap(JSON.Decode.object) {
  | None => Error("a Worker's wrangler.json is not JSON")
  | Some(config) =>
    let filled = Dict.copy(config)
    config
    ->Dict.get("name")
    ->Option.flatMap(JSON.Decode.string)
    ->Option.forEach(name => filled->Dict.set("name", JSON.String(named(name, ~id))))
    filled->eachOf(config, "d1_databases", d =>
      d
      ->Dict.get("database_name")
      ->Option.flatMap(JSON.Decode.string)
      ->Option.forEach(name => {
        d->Dict.set("database_name", JSON.String(named(name, ~id)))
        ids->Dict.get(name)->Option.forEach(real => d->Dict.set("database_id", JSON.String(real)))
      })
    )
    filled->eachOf(config, "r2_buckets", d =>
      d
      ->Dict.get("bucket_name")
      ->Option.flatMap(JSON.Decode.string)
      ->Option.forEach(name => d->Dict.set("bucket_name", JSON.String(named(name, ~id))))
    )
    let vars =
      config
      ->Dict.get("vars")
      ->Option.flatMap(JSON.Decode.object)
      ->Option.getOr(dict{})
      ->Dict.copy
    set->Dict.forEachWithKey((value, name) => vars->Dict.set(name, JSON.String(value)))
    filled->Dict.set("vars", JSON.Object(vars))
    Ok(JSON.stringify(JSON.Object(filled), ~space=2))
  }

/**
 * The variables a Worker is given, the install id and the account's, the kinds offered to `driver`
 * alone, and the database's id to `database` alone.
 */
let varsOf = (w, ~install, ~ids: dict<string>, worker) => {
  let vars = dict{
    "INSTALL_ID": install.id,
    "ACCOUNT_ID": value(w.env, account)->Option.getOr(""),
  }
  if worker.name == driver.name {
    vars->Dict.set("KINDS", install.kinds->Array.join(","))
  }
  if worker.name == databaseWorker.name {
    vars->Dict.set("DATABASE_ID", ids->Dict.get(userDatabase)->Option.getOr(""))
  }
  vars
}

/**
 * `next` run with a Worker's configuration of the moment written, removed after whatever it
 * answered or threw, a throw answered as an error.
 */
let within = (w, ~dry, ~root, ~install, ~ids, worker, next) => {
  let directory = join([root, ...worker.directory])
  let config = join([directory, moment])
  if dry {
    let shortened = [...worker.directory, moment]->Array.join("/")
    let given = varsOf(w, ~install, ~ids, worker)->Dict.keysToArray->Array.join(", ")
    let full = named(worker.name, ~id=install.id)
    w.say(`would write ${shortened}, ${worker.name}'s wrangler.json with every name followed by`)
    w.say(`  the install id, its databases' ids, and the variables ${given} filled in,`)
    w.say(`  and remove it once ${full} is done`)
    next(directory, config)
  } else {
    let done = switch configured(
      readFileSync(join([directory, "wrangler.json"])),
      ~id=install.id,
      ~ids,
      ~vars=varsOf(w, ~install, ~ids, worker),
    )->then(text => {
      writeFileSync(config, text)
      next(directory, config)
    }) {
    | done => done
    | exception JsExn(e) => Error(e->JsExn.message->Option.getOr("an exception"))
    }
    rmSync(config, {recursive: false, force: true})
    done
  }
}

/** The database's migrations applied, wrangler applying only those not applied yet. */
let migrated = (w, ~dry, ~root, ~directory, ~config, ~database) => {
  let apply = commanded(
    w,
    ~root,
    ~cwd=directory,
    ["d1", "migrations", "apply", database, "--remote", "--config", config],
  )
  if dry {
    w.say(`would run ${shown(apply)}`)
    Ok()
  } else {
    w.run(apply)->Result.map(_ => w.say(`the migrations of ${database} applied`))
  }
}

/** The bundle written out, in the quiet environment, as it reaches no account. */
let bundling = (w, ~root, ~directory, ~config, ~out) =>
  wrangler(
    ~root,
    ~cwd=directory,
    ~env=quiet(w.env),
    ["deploy", "--dry-run", "--outdir", out, "--config", config],
  )

/** What a deploy would upload, the bundle and the configuration, as one short hash. */
let bundled = (w, ~root, ~directory, ~config, ~out) =>
  w.run(bundling(w, ~root, ~directory, ~config, ~out))->Result.map(_ => {
    let hashed = createHash("sha256")->updateText(readFileSync(config))
    readdirSync(out, {recursive: true})
    ->Array.toSorted(String.compare)
    ->Array.filter(name => statSync(join([out, name]))->isFile)
    ->Array.forEach(name => hashed->updateText(name)->update(readBytes(join([out, name])))->ignore)
    hashed->digest->String.slice(~start=0, ~end=16)
  })

/** The tag of the newest version not made by a secret's change, the code the Worker runs. */
let runningTag = body =>
  parsed(body)
  ->Option.flatMap(JSON.Decode.array)
  ->Option.flatMap(versions =>
    versions
    ->Array.toReversed
    ->Array.find(v => v->member("annotations")->text("workers/triggered_by") != Some("secret"))
  )
  ->Option.flatMap(v => v->member("annotations")->text("workers/tag"))

/** The names `secret list` holds. */
let listedSecrets = body =>
  parsed(body)
  ->Option.flatMap(JSON.Decode.array)
  ->Option.mapOr([], all => all->Array.filterMap(s => s->text("name")))

/** Each of a Worker's secrets put where it holds none by that name, `BINDING` passed over where
 * stdin held nothing. */
let secretsPut = (w, ~dry, ~root, ~directory, ~config, ~hashed, worker) => {
  let list = commanded(w, ~root, ~cwd=directory, ["secret", "list", "--config", config])
  let put = (name, given) => {
    ...commanded(w, ~root, ~cwd=directory, ["secret", "put", name, "--config", config]),
    input: given,
  }
  let given = worker.secrets->Array.filterMap(((name, source)) =>
    switch source {
    | Environment(variable) => value(w.env, variable)->Option.map(v => (name, v))
    | Bound => hashed->Option.map(v => (name, v))
    }
  )
  let passed = () =>
    if worker.secrets->Array.some(((_, source)) => source == Bound) && hashed == None {
      w.say(`${binding} of ${worker.name} passed over, nothing on stdin`)
    }
  if dry {
    w.say(`would run ${shown(list)}, and put each secret it does not name:`)
    given->Array.forEach(((name, _)) => w.say(`  ${shown(put(name, ""))}`))
    passed()
    Ok()
  } else {
    w.run(list)
    ->Result.map(listedSecrets)
    ->then(held => {
      passed()
      given->Array.reduce(Ok(), (done, (name, secret)) =>
        done->then(
          () =>
            if held->Array.includes(name) {
              w.say(`the secret ${name} of ${worker.name} is there already`)
              Ok()
            } else {
              w.run(put(name, secret))->Result.map(
                _ => w.say(`the secret ${name} of ${worker.name} put`),
              )
            },
        )
      )
    })
  }
}

/**
 * A Worker deployed unless the version it runs carries this bundle's tag, its secrets put first
 * where it exists and after its first deploy where it does not, as monoflake/cloud's install does.
 */
let deployed = (w, ~dry, ~root, ~directory, ~config, ~scratch, ~hashed, worker) => {
  let out = join([scratch, worker.name])
  let versions = commanded(
    w,
    ~root,
    ~cwd=directory,
    ["versions", "list", "--json", "--config", config],
  )
  let deploy = tag =>
    commanded(w, ~root, ~cwd=directory, ["deploy", "--config", config, "--tag", tag])
  let secrets = () => secretsPut(w, ~dry, ~root, ~directory, ~config, ~hashed, worker)
  let build = () => compiled(w, ~dry, ~root, ~directory, worker)
  if dry {
    build()->ignore
    let bundle = bundling(w, ~root, ~directory, ~config, ~out)
    w.say(`would run ${shown(bundle)}, and hash the bundle and the configuration`)
    w.say(`would run ${shown(versions)}, and deploy unless ${worker.name} runs that hash's tag,`)
    w.say(`  its secrets put first where it exists, and after where it does not`)
    w.say(`would run ${shown(deploy("<the hash>"))}`)
    secrets()
  } else {
    build()
    ->then(() => bundled(w, ~root, ~directory, ~config, ~out))
    ->then(tag => {
      let deployOnce = () =>
        w.run(deploy(tag))->Result.map(_ => w.say(`the Worker ${worker.name} deployed, ${tag}`))
      switch w.run(versions) {
      | Ok(body) =>
        secrets()->then(() =>
          if runningTag(body) == Some(tag) {
            w.say(`the Worker ${worker.name} runs this bundle already, ${tag}`)
            Ok()
          } else {
            deployOnce()
          }
        )
      // A secret put before the Worker exists would make an empty one.
      | Error(_) => deployOnce()->then(secrets)
      }
    })
  }
}

/** The binding token's hash where stdin holds one, None where it holds nothing. */
let hashOfStdin = w =>
  switch w.stdin()->String.trim {
  | "" => Ok(None)
  | token => bindingHash(token)->Result.map(hash => Some(hash))
  }

/** The kinds `DRIVER_KINDS` names, comma-separated, `function` alone where it names none. */
let kindsOf = env =>
  switch value(env, kindsInput) {
  | None => Ok(defaultKinds)
  | Some(listed) =>
    let named = listed->String.split(",")->Array.map(String.trim)
    switch named->Array.find(kind => !(kinds->Array.includes(kind))) {
    | Some(other) =>
      Error(`${kindsInput} names "${other}", where each is one of ${kinds->Array.join(", ")}`)
    // Each kind once, in the order the driver names them.
    | None => Ok(kinds->Array.filter(kind => named->Array.includes(kind)))
    }
  }

/**
 * What install reads before anything runs, the kinds offered and every input it needs, one unset
 * refused, or said where the run is dry, since a dry run acts on nothing.
 */
let inputsOf = (w, ~dry) =>
  kindsOf(w.env)->then(offered => {
    let needed = [
      account,
      installToken,
      driverToken,
      ...offered->Array.includes("database") ? [databaseToken] : [],
    ]
    switch needed->Array.filter(name => value(w.env, name) == None) {
    | [] => Ok(offered)
    | missing if dry =>
      w.say(`${missing->Array.join(", ")} unset in the environment, so a run not dry refuses`)
      Ok(offered)
    | missing =>
      Error(`${missing->Array.join(", ")} unset in the environment, which alone gives them`)
    }
  })

/** What a kind no longer offered holds, its Worker first, as install names it. */
let heldBy = kind =>
  switch kind {
  | "object" => Some((object, `the bucket ${bucket}`))
  | "database" => Some((databaseWorker, `the D1 database ${userDatabase}`))
  | _ => None
  }

/** Cloudflare's answer for a Worker the account does not hold, its error 10007. */
let notFound = why => why->String.includes("[code: 10007]")

/**
 * Each kind not offered whose Worker the account holds, named with what it holds and left as it
 * is, since install never removes what a kind dropped from the list holds.
 */
let left = (w, ~dry, ~root, ~install) =>
  kinds
  ->Array.filter(kind => !offers(install, kind))
  ->Array.filterMap(kind => heldBy(kind)->Option.map(held => (kind, held)))
  ->Array.reduce(Ok(), (done, (kind, (worker, holds))) =>
    done->then(() => {
      let full = named(worker.name, ~id=install.id)
      let store = named(holds, ~id=install.id)
      let versions = commanded(w, ~root, ~cwd=root, ["versions", "list", "--json", "--name", full])
      if dry {
        w.say(`would run ${shown(versions)}, and where ${full} is there name it and ${store},`)
        w.say(`  left as they are, ${kind} not being offered`)
        Ok()
      } else {
        switch w.run(versions) {
        | Ok(_) =>
          w.say(`${kind} is not offered, and ${full} and ${store} are left as they are;`)
          w.say(`  install removes neither, so remove them by hand where they are not wanted`)
          Ok()
        // A Worker not found was never made, or is gone already.
        | Error(why) if notFound(why) => Ok()
        | Error(why) => Error(`whether ${full} is there is not known, ${why}`)
        }
      }
    })
  )

/**
 * driver(cloudflare) on the account, each part made where it is absent, in nrs5v's order, every
 * read-only check run first, so a failed one stops install with nothing changed.
 */
let install = (w, ~dry, ~root=root) =>
  inputsOf(w, ~dry)->then(offered =>
    hashOfStdin(w)->then(hashed => {
      if hashed == None {
        w.say(`nothing on stdin, so ${binding} is passed over on each Worker`)
      }
      w.say(`the kinds offered are ${offered->Array.join(", ")}, ${kindsInput}`)
      switch value(w.env, location) {
      | Some(hint) => w.say(`the databases and the bucket placed by the hint ${hint}, ${location}`)
      | None => w.say(`no ${location}, so Cloudflare places the databases and the bucket`)
      }
      recovered(w, ~dry, ~root)->then(
        ((id, fresh)) => {
          let install = {id, kinds: offered}
          left(w, ~dry, ~root, ~install)->then(
            () => {
              let scratch = dry ? "<a directory of its own>" : w.scratch()
              let full = name => named(name, ~id)
              let made = (kind, step) => offers(install, kind) ? step() : Ok()
              let deployedIn = (ids, worker) =>
                within(
                  w,
                  ~dry,
                  ~root,
                  ~install,
                  ~ids,
                  worker,
                  (directory, config) =>
                    deployed(
                      w,
                      ~dry,
                      ~root,
                      ~directory,
                      ~config,
                      ~scratch,
                      ~hashed,
                      {...worker, name: full(worker.name)},
                    ),
                )
              let marker = fresh ? Some(id) : None
              let installed = databaseOf(w, ~dry, ~root, ~marker?, full(database))->then(
                driverId => {
                  let ids = Dict.fromArray([(database, driverId)])
                  within(
                    w,
                    ~dry,
                    ~root,
                    ~install,
                    ~ids,
                    driver,
                    (directory, config) =>
                      migrated(w, ~dry, ~root, ~directory, ~config, ~database=full(database))
                      ->then(
                        () =>
                          made(
                            "database",
                            () =>
                              databaseOf(w, ~dry, ~root, full(userDatabase))->Result.map(
                                id => ids->Dict.set(userDatabase, id),
                              ),
                          ),
                      )
                      ->then(
                        () => made("object", () => bucketOf(w, ~dry, ~root, ~bucket=full(bucket))),
                      )
                      ->then(
                        () =>
                          deployed(
                            w,
                            ~dry,
                            ~root,
                            ~directory,
                            ~config,
                            ~scratch,
                            ~hashed,
                            {...driver, name: full(driver.name)},
                          ),
                      ),
                  )
                  ->then(() => made("object", () => deployedIn(ids, object)))
                  ->then(() => made("database", () => deployedIn(ids, databaseWorker)))
                },
              )
              if !dry {
                rmSync(scratch, {recursive: true, force: true})
              }
              installed
            },
          )
        },
      )
    })
  )

/** The world as it is, each command run to its end with its output kept. */
let real = {
  run: command => {
    let done = spawnSync(
      command.program,
      command.args,
      {
        cwd: command.cwd,
        input: ?command.input,
        env: command.env,
        stdio: ["pipe", "pipe", "pipe"],
        encoding: "utf8",
      },
    )
    let said = text => text->Nullable.toOption->Option.getOr("")->String.trim
    switch done.status->Nullable.toOption {
    | Some(0) => Ok(said(done.stdout))
    | _ => Error(`${shown(command)} failed, ${said(done.stderr)} ${said(done.stdout)}`->String.trim)
    }
  },
  env: processEnv,
  say: Console.log,
  stdin: () =>
    if stdinTerminal->Nullable.toOption == Some(true) {
      ""
    } else {
      switch readStdin() {
      | read => read
      | exception JsExn(_) => ""
      }
    },
  scratch: () => mkdtempSync(join([tmpdir(), "driver-install-"])),
  draw: () => fromBytes(randomBytes(4))->encoded("hex"),
}

if isMain {
  let args = argv->Array.slice(~start=2)
  switch args->Array.find(a => a != "--dry-run") {
  | Some(other) =>
    Console.error(`install: ${other} is no argument of ${usage}`)
    process->setExitCode(1)
  | None =>
    switch install(real, ~dry=args->Array.includes("--dry-run")) {
    | Ok() => ()
    | Error(why) =>
      Console.error(`install: ${why}`)
      process->setExitCode(1)
    }
  }
}
