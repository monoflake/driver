/***
 * driver(cloudflare) made on the account wrangler is given, each part only where it is absent, RFC
 * nrs5v, "What makes it on an account", every command run through a world a test fakes.
 */
open Host

let usage = "install [--dry-run]"

let root = join([fileURLToPath(importMetaUrl), "..", ".."])

/** The names nrs5v gives each part. */
let database = "driver"
let bucket = "objects"

/** Where the database and bucket are placed on the test account, western North America. */
let located = "wnam"

/** What it is given, read from the environment alone, as this repository is public. */
let credential = "CLOUDFLARE_API_TOKEN"
let account = "CLOUDFLARE_ACCOUNT_ID"
let driverToken = "DRIVER_API_TOKEN"
let inputs = [credential, account, driverToken]

/** A Worker, its directory beneath the root and the secrets it is given by name. */
type worker = {name: string, directory: array<string>, secrets: array<string>}

let apiToken = "API_TOKEN"
let binding = "BINDING"
let driver = {name: "driver", directory: ["cloudflare"], secrets: [apiToken, binding]}
let object = {name: "object", directory: ["cloudflare", "object"], secrets: [binding]}

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

/** The environment the commands run in, quiet and unasking, the driver's own token taken out. */
let quiet = env => {
  let given = Dict.copy(env)
  given->Dict.delete(driverToken)
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

/** The database's id where `d1 list` holds one by its name. */
let listedDatabase = body =>
  parsed(body)
  ->Option.flatMap(JSON.Decode.array)
  ->Option.flatMap(all => all->Array.find(db => db->text("name") == Some(database)))
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

/** The database made with its hint where the account lists none by its name, and its id. */
let databaseOf = (w, ~dry, ~root) => {
  let list = commanded(w, ~root, ~cwd=root, ["d1", "list", "--json"])
  let create = commanded(w, ~root, ~cwd=root, ["d1", "create", database, "--location", located])
  if dry {
    w.say(`would run ${shown(list)}, and ${shown(create)} unless ${database} is listed`)
    Ok("<the database's id>")
  } else {
    switch w.run(list)->Result.map(listedDatabase) {
    | Error(why) => Error(why)
    | Ok(Some(id)) =>
      w.say(`the database ${database} is there already`)
      Ok(id)
    | Ok(None) =>
      w.run(create)
      ->then(_ => w.run(list))
      ->Result.map(listedDatabase)
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
  let create = commanded(
    w,
    ~root,
    ~cwd=root,
    ["r2", "bucket", "create", bucket, "--location", located],
  )
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

/** A Worker's own configuration with the database's real id and the account's as `ACCOUNT_ID`. */
let configured = (given, ~id, ~account) =>
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
            switch db->JSON.Decode.object {
            | Some(o) if db->text("database_name") == Some(database) =>
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
    vars->Dict.set("ACCOUNT_ID", JSON.String(account))
    filled->Dict.set("vars", JSON.Object(vars))
    Ok(JSON.stringify(JSON.Object(filled), ~space=2))
  }

/** `next` run with a Worker's configuration of the moment written, removed after whatever it
 * answered. */
let within = (w, ~dry, ~root, ~id, worker, next) => {
  let directory = join([root, ...worker.directory])
  let config = join([directory, moment])
  if dry {
    let shortened = [...worker.directory, moment]->Array.join("/")
    w.say(`would write ${shortened}, ${worker.name}'s wrangler.json with the database's id`)
    w.say(`  and ACCOUNT_ID filled in, and remove it once ${worker.name} is done`)
    next(directory, config)
  } else {
    configured(
      readFileSync(join([directory, "wrangler.json"])),
      ~id,
      ~account=value(w.env, account)->Option.getOr(""),
    )->then(text => {
      writeFileSync(config, text)
      let done = switch next(directory, config) {
      | done => done
      | exception JsExn(e) => Error(e->JsExn.message->Option.getOr("an exception"))
      }
      rmSync(config, {recursive: false, force: true})
      done
    })
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
  let given = worker.secrets->Array.filterMap(name =>
    if name == apiToken {
      value(w.env, driverToken)->Option.map(v => (name, v))
    } else if name == binding {
      hashed->Option.map(v => (name, v))
    } else {
      None
    }
  )
  let passed = () =>
    if worker.secrets->Array.includes(binding) && hashed == None {
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
  if dry {
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
    bundled(w, ~root, ~directory, ~config, ~out)->then(tag => {
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
      let scratch = dry ? "<a directory of its own>" : w.scratch()
      let installed = databaseOf(w, ~dry, ~root)->then(id =>
        within(
          w,
          ~dry,
          ~root,
          ~id,
          driver,
          (directory, config) =>
            migrated(w, ~dry, ~root, ~directory, ~config)
            ->then(() => bucketOf(w, ~dry, ~root))
            ->then(() => deployed(w, ~dry, ~root, ~directory, ~config, ~scratch, ~hashed, driver)),
        )->then(
          () =>
            within(
              w,
              ~dry,
              ~root,
              ~id,
              object,
              (directory, config) =>
                deployed(w, ~dry, ~root, ~directory, ~config, ~scratch, ~hashed, object),
            ),
        )
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
