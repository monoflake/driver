/***
 * driver(cloudflare) made on the account wrangler is given, each part only where it is absent, RFC
 * nrs5v, "What makes it on an account", every command run through a world a test fakes.
 */
open Host

let usage = "install [--dry-run]"

let root = join([fileURLToPath(importMetaUrl), "..", ".."])

/** The names nrs5v gives each part, the driver's D1 and the binding's one database. */
let database = "driver"
let userDatabase = "database"
let bucket = "objects"

/** What it is given, read from the environment alone, as this repository is public. */
let credential = "CLOUDFLARE_API_TOKEN"
let account = "CLOUDFLARE_ACCOUNT_ID"
let driverToken = "DRIVER_API_TOKEN"
let databaseToken = "DATABASE_API_TOKEN"
let inputs = [credential, account, driverToken, databaseToken]

/** The tokens handed to a Worker alone, on stdin, and kept out of every command's environment. */
let tokens = [driverToken, databaseToken]

/** The hint the database and the bucket are placed by, none given letting Cloudflare place them. */
let location = "DRIVER_LOCATION"

/** Where a secret's value comes from, a variable of the environment or the binding's hash. */
type source = Environment(string) | Bound

/** A Worker, its directory beneath the root and the secrets it is given by name. */
type worker = {name: string, directory: array<string>, secrets: array<(string, source)>}

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
}

let then = (result, next) => result->Result.flatMap(next)

let value = (env, name) => env->Dict.get(name)->Option.filter(v => v != "")

/** A command as a dry run prints it, its program's name and arguments, stdin said, never shown. */
let shown = command => {
  let line = [basename(command.program), ...command.args]->Array.join(" ")
  command.input->Option.isSome ? `${line}, its value on stdin` : line
}

/** The environment the commands run in, quiet and unasking, the Workers' own tokens taken out. */
let quiet = env => {
  let given = Dict.copy(env)
  tokens->Array.forEach(name => given->Dict.delete(name))
  given->Dict.set("WRANGLER_SEND_METRICS", "false")
  given->Dict.set("CI", "1")
  given
}

/** A command of the account's, run in `cwd`, wrangler being the cloudflare block's. */
let commanded = (w, ~root, ~cwd, arguments) => {
  program: join([root, "cloudflare", "node_modules", ".bin", "wrangler"]),
  args: arguments,
  cwd,
  env: quiet(w.env),
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
let bucketOf = (w, ~dry, ~root) => {
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

/**
 * A Worker's own configuration, each D1 database's real id by its name, and the variables given
 * set beside its own.
 */
let configured = (given, ~ids: dict<string>, ~vars as set: dict<string>) =>
  switch parsed(given)->Option.flatMap(JSON.Decode.object) {
  | None => Error("a Worker's wrangler.json is not JSON")
  | Some(config) =>
    let filled = Dict.copy(config)
    config
    ->Dict.get("d1_databases")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.forEach(databases =>
      filled->Dict.set(
        "d1_databases",
        JSON.Array(
          databases->Array.map(db =>
            switch (
              db->JSON.Decode.object,
              db->text("database_name")->Option.flatMap(n => ids->Dict.get(n)),
            ) {
            | (Some(o), Some(id)) =>
              let d = Dict.copy(o)
              d->Dict.set("database_id", JSON.String(id))
              JSON.Object(d)
            | _ => db
            }
          ),
        ),
      )
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

/** The variables a Worker is given, the account's id, and the database's to `database` alone. */
let varsOf = (w, ~ids: dict<string>, worker) => {
  let vars = dict{"ACCOUNT_ID": value(w.env, account)->Option.getOr("")}
  if worker.name == databaseWorker.name {
    vars->Dict.set("DATABASE_ID", ids->Dict.get(userDatabase)->Option.getOr(""))
  }
  vars
}

/**
 * `next` run with a Worker's configuration of the moment written, removed after whatever it
 * answered or threw, a throw answered as an error.
 */
let within = (w, ~dry, ~root, ~ids, worker, next) => {
  let directory = join([root, ...worker.directory])
  let config = join([directory, moment])
  if dry {
    let shortened = [...worker.directory, moment]->Array.join("/")
    let named = varsOf(w, ~ids, worker)->Dict.keysToArray->Array.join(" and ")
    w.say(`would write ${shortened}, ${worker.name}'s wrangler.json with its databases' ids`)
    w.say(`  and ${named} filled in, and remove it once ${worker.name} is done`)
    next(directory, config)
  } else {
    let done = switch configured(
      readFileSync(join([directory, "wrangler.json"])),
      ~ids,
      ~vars=varsOf(w, ~ids, worker),
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
let migrated = (w, ~dry, ~root, ~directory, ~config) => {
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

/** driver(cloudflare) on the account, each part made where it is absent, in nrs5v's order. */
let install = (w, ~dry, ~root=root) => {
  let missing = inputs->Array.filter(name => value(w.env, name) == None)
  if missing != [] {
    Error(`${missing->Array.join(", ")} unset in the environment, which alone gives them`)
  } else {
    hashOfStdin(w)->then(hashed => {
      if hashed == None {
        w.say(`nothing on stdin, so ${binding} is passed over on each Worker`)
      }
      switch value(w.env, location) {
      | Some(hint) => w.say(`the databases and the bucket placed by the hint ${hint}, ${location}`)
      | None => w.say(`no ${location}, so Cloudflare places the databases and the bucket`)
      }
      let scratch = dry ? "<a directory of its own>" : w.scratch()
      let deployedIn = (ids, worker) =>
        within(w, ~dry, ~root, ~ids, worker, (directory, config) =>
          deployed(w, ~dry, ~root, ~directory, ~config, ~scratch, ~hashed, worker)
        )
      let installed =
        databaseOf(w, ~dry, ~root, database)
        ->then(driverId =>
          databaseOf(w, ~dry, ~root, userDatabase)->Result.map(
            id => Dict.fromArray([(database, driverId), (userDatabase, id)]),
          )
        )
        ->then(ids =>
          within(
            w,
            ~dry,
            ~root,
            ~ids,
            driver,
            (directory, config) =>
              migrated(w, ~dry, ~root, ~directory, ~config)
              ->then(() => bucketOf(w, ~dry, ~root))
              ->then(
                () => deployed(w, ~dry, ~root, ~directory, ~config, ~scratch, ~hashed, driver),
              ),
          )
          ->then(() => deployedIn(ids, object))
          ->then(() => deployedIn(ids, databaseWorker))
        )
      if !dry {
        rmSync(scratch, {recursive: true, force: true})
      }
      installed
    })
  }
}

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
