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
let ambient = "CLOUDFLARE_"

/** The tokens kept out of every command's environment by their own names. */
let tokens = [installToken, driverToken, databaseToken]

/** The kinds the driver may offer, `function` alone where `DRIVER_KINDS` names none. */
let kinds = ["function", "object", "database"]
let defaultKinds = ["function"]

@module("node:crypto") external randomBytes: int => Uint8Array.t = "randomBytes"

/** An install id, 8 lowercase hex digits. */
let installIdForm = /^[0-9a-f]{8}$/

/** The driver's own D1 by its name, the one install id it holds. */
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
 * `CLOUDFLARE_` name taken out.
 */
let quiet = env => {
  let given = Dict.copy(env)
  given
  ->Dict.keysToArray
  ->Array.forEach(name =>
    if name->String.startsWith(ambient) || tokens->Array.includes(name) {
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

/** A command of the account's, run in `cwd`, wrangler being the cloudflare block's. */
let commanded = (w, ~root, ~cwd, arguments) => {
  program: join([root, "cloudflare", "node_modules", ".bin", "wrangler"]),
  args: arguments,
  cwd,
  env: accounted(w.env),
}

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

/** A database's id where `d1 list` holds one by its name. */
let listedDatabase = (body, name) =>
  parsed(body)
  ->Option.flatMap(JSON.Decode.array)
  ->Option.flatMap(all => all->Array.find(db => db->text("name") == Some(name)))
  ->Option.flatMap(db => db->text("uuid"))

/** The names `d1 list` holds, and nothing more of any database. */
let listedNames = body =>
  parsed(body)
  ->Option.flatMap(JSON.Decode.array)
  ->Option.mapOr([], all => all->Array.filterMap(db => db->text("name")))

/** The install ids the driver's D1 databases are named by, each `driver-<8 hex>`. */
let installIds = names =>
  names->Array.filterMap(name =>
    switch driverForm->RegExp.exec(name) {
    | Some(found) => found->RegExp.Result.matches->Array.get(0)->Option.flatMap(id => id)
    | None => None
    }
  )

/**
 * The install id the account holds, read from its D1 databases' names alone, a new one drawn where
 * none is, the one reused, and a refusal naming each where more than one is.
 */
let recovered = (w, ~dry, ~root) => {
  let list = commanded(w, ~root, ~cwd=root, ["d1", "list", "--json"])
  if dry {
    w.say(`would run ${shown(list)}, and reuse the install id of the one driver-<8 hex> it names,`)
    w.say(`  draw a new one where it names none, and refuse where it names more than one`)
    Ok(("<install id>", []))
  } else {
    w.run(list)
    ->Result.map(listedNames)
    ->then(names =>
      switch installIds(names) {
      | [] =>
        let id = w.draw()
        if installIdForm->RegExp.test(id) {
          w.say(`no driver-<8 hex> on the account, so the install id ${id} is drawn`)
          Ok((id, names))
        } else {
          Error(`an install id drawn is not 8 lowercase hex digits, ${id}`)
        }
      | [id] =>
        w.say(`the install id ${id} is reused, the account holding ${named(database, ~id)}`)
        Ok((id, names))
      | ids =>
        let all = ids->Array.map(id => named(database, ~id))->Array.join(", ")
        Error(`the account holds more than one driver's D1, ${all}, so none is chosen`)
      }
    )
  }
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

/** A database made with its hint where the account lists none by its name, and its id. */
let databaseOf = (w, ~dry, ~root, database) => {
  let list = commanded(w, ~root, ~cwd=root, ["d1", "list", "--json"])
  let create = commanded(w, ~root, ~cwd=root, ["d1", "create", database, ...placed(w)])
  if dry {
    w.say(`would run ${shown(list)}, and ${shown(create)} unless ${database} is listed`)
    Ok(`<${database}'s id>`)
  } else {
    switch w.run(list)->Result.map(body => listedDatabase(body, database)) {
    | Error(why) => Error(why)
    | Ok(Some(id)) =>
      w.say(`the database ${database} is there already`)
      Ok(id)
    | Ok(None) =>
      w.run(create)
      ->then(_ => w.run(list))
      ->Result.map(body => listedDatabase(body, database))
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

/** What a deploy would upload, the bundle and the configuration, as one short hash. */
let bundled = (w, ~root, ~directory, ~config, ~out) =>
  w.run(
    commanded(
      w,
      ~root,
      ~cwd=directory,
      ["deploy", "--dry-run", "--outdir", out, "--config", config],
    ),
  )->Result.map(_ => {
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
    let bundle = commanded(
      w,
      ~root,
      ~cwd=directory,
      ["deploy", "--dry-run", "--outdir", out, "--config", config],
    )
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

/** What install reads before anything runs, every input it needs and the kinds offered. */
let inputsOf = env =>
  kindsOf(env)->then(offered => {
    let needed = [
      account,
      installToken,
      driverToken,
      ...offered->Array.includes("database") ? [databaseToken] : [],
    ]
    switch needed->Array.filter(name => value(env, name) == None) {
    | [] => Ok(offered)
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
      } else {
        switch w.run(versions) {
        | Ok(_) =>
          w.say(`${kind} is not offered, and ${full} and ${store} are left as they are;`)
          w.say(`  install removes neither, so remove them by hand where they are not wanted`)
        // A Worker not found was never made, or is gone already.
        | Error(_) => ()
        }
      }
      Ok()
    })
  )

/** driver(cloudflare) on the account, each part made where it is absent, in nrs5v's order. */
let install = (w, ~dry, ~root=root) =>
  inputsOf(w.env)->then(offered =>
    hashOfStdin(w)->then(hashed => {
      if hashed == None {
        w.say(`nothing on stdin, so ${binding} is passed over on each Worker`)
      }
      w.say(`the kinds offered are ${offered->Array.join(", ")}, ${kindsInput}`)
      switch value(w.env, location) {
      | Some(hint) => w.say(`the databases and the bucket placed by the hint ${hint}, ${location}`)
      | None => w.say(`no ${location}, so Cloudflare places the databases and the bucket`)
      }
      let scratch = dry ? "<a directory of its own>" : w.scratch()
      let installed = recovered(w, ~dry, ~root)->then(
        ((id, _)) => {
          let install = {id, kinds: offered}
          let full = name => named(name, ~id)
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
          let made = (kind, step) => offers(install, kind) ? step() : Ok()
          databaseOf(w, ~dry, ~root, full(database))
          ->then(
            driverId => {
              let ids = Dict.fromArray([(database, driverId)])
              made(
                "database",
                () =>
                  databaseOf(w, ~dry, ~root, full(userDatabase))->Result.map(
                    id => ids->Dict.set(userDatabase, id),
                  ),
              )->Result.map(() => ids)
            },
          )
          ->then(
            ids =>
              within(
                w,
                ~dry,
                ~root,
                ~install,
                ~ids,
                driver,
                (directory, config) =>
                  migrated(w, ~dry, ~root, ~directory, ~config, ~database=full(database))
                  ->then(() => made("object", () => bucketOf(w, ~dry, ~root, ~bucket=full(bucket))))
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
              ->then(() => made("database", () => deployedIn(ids, databaseWorker))),
          )
          ->then(() => left(w, ~dry, ~root, ~install))
        },
      )
      if !dry {
        rmSync(scratch, {recursive: true, force: true})
      }
      installed
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
