/***
 * Each part install makes where it is absent, the databases, the bucket, each Worker's
 * configuration of the moment, its migrations, its bundle, its secrets and its deploy.
 */
open Host
open! Install_world
open Install_ledger

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

let listedBuckets = Worker_install.listedBuckets

/** The arguments placing a part where `DRIVER_LOCATION` names, said by its name in a dry run. */
let placed = w => ["--location", placeOf(w.env)->Option.getOr(`<${location}>`)]

/** The marker and collision policy belong to the driver install. */
let databaseOf = (w: world, ~dry, ~root, ~marker=?, ~drawn=false, database) => {
  let command = args => commanded(w, ~root, ~cwd=root, args)
  let marking =
    marker->Option.map(id =>
      command(["d1", "execute", database, "--remote", "--command", markerWrite(id)])
    )
  Worker_install.databaseOf(
    (w :> Worker_install.context),
    ~dry,
    ~command,
    ~create=["d1", "create", database, ...placed(w)],
    ~listed=body => listedDatabase(body, database),
    ~fresh=marker != None || drawn,
    ~placeholder=`<${database}'s id>`,
    ~marking=marking->Option.mapOr([], write => [
      `  and right after it ${shown(write)}, before any migration`,
    ]),
    ~created=() => {
      w.say(`the database ${database} made`)
      marking->Option.mapOr(Ok(), write =>
        w.run(write)->Result.map(_ => w.say(`${database} marked as the driver's`))
      )
    },
    database,
  )
}
let bucketOf = (w: world, ~dry, ~root, ~drawn=false, ~bucket) =>
  Worker_install.bucketOf(
    (w :> Worker_install.context),
    ~dry,
    ~command=args => commanded(w, ~root, ~cwd=root, args),
    ~create=["r2", "bucket", "create", bucket, ...placed(w)],
    ~drawn,
    ~bucket,
  )

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
 * A Worker's own configuration with its name, its databases' and its bucket's replaced by those the
 * driver records, each D1 database's real id by its own name, and the variables given set.
 */
let configured = (given, ~install, ~ids: dict<string>, ~vars as set: dict<string>) =>
  switch parsed(given)->Option.flatMap(JSON.Decode.object) {
  | None => Error("a Worker's wrangler.json is not JSON")
  | Some(config) =>
    let filled = Dict.copy(config)
    config
    ->Dict.get("name")
    ->Option.flatMap(JSON.Decode.string)
    ->Option.forEach(name => filled->Dict.set("name", JSON.String(nameOf(install, name))))
    filled->eachOf(config, "d1_databases", d =>
      d
      ->Dict.get("database_name")
      ->Option.flatMap(JSON.Decode.string)
      ->Option.forEach(name => {
        d->Dict.set("database_name", JSON.String(nameOf(install, databaseRole(name))))
        ids->Dict.get(name)->Option.forEach(real => d->Dict.set("database_id", JSON.String(real)))
      })
    )
    filled->eachOf(config, "r2_buckets", d =>
      d->Dict.set("bucket_name", JSON.String(nameOf(install, bucketRole)))
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
    let full = nameOf(install, worker.name)
    w.say(`would write ${shortened}, ${worker.name}'s wrangler.json with every name the one`)
    w.say(`  recorded, its databases' ids, and the variables ${given} filled in,`)
    w.say(`  and remove it once ${full} is done`)
    next(directory, config)
  } else {
    let done = switch configured(
      readFileSync(join([directory, "wrangler.json"])),
      ~install,
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

let bundled = (w: world, ~root, ~directory, ~config, ~out) =>
  Worker_install.bundled(
    (w :> Worker_install.context),
    ~command=args => wrangler(~root, ~cwd=directory, ~env=quiet(w.env), args),
    ~config,
    ~out,
  )
let runningTag = Worker_install.runningTag
let listedSecrets = Worker_install.listedSecrets

/**
 * Each of a Worker's secrets put where it holds none by that name, and `BINDING` written whenever
 * stdin holds a token, replacing what is there, since a secret cannot be read back to compare and
 * a token given means bind; with nothing on stdin it is never touched.
 */
let secretsPut = (w: world, ~dry, ~root, ~directory, ~config, ~hashed, worker) => {
  let list = commanded(w, ~root, ~cwd=directory, ["secret", "list", "--config", config])
  let put = (name, given) => {
    ...commanded(w, ~root, ~cwd=directory, ["secret", "put", name, "--config", config]),
    input: given,
  }
  let given = worker.secrets->Array.filterMap(((name, source)) =>
    switch source {
    | Environment(variable) => value(w.env, variable)->Option.map(v => (name, v, false))
    | Bound => hashed->Option.map(v => (name, v, true))
    }
  )
  let passed = () =>
    if worker.secrets->Array.some(((_, source)) => source == Bound) && hashed == None {
      w.say(`${binding} of ${worker.name} passed over, nothing on stdin`)
    }
  if dry {
    w.say(`would run ${shown(list)}, and put each secret it does not name, and ${binding} always`)
    given->Array.forEach(((name, _, replaced)) =>
      w.say(`  ${shown(put(name, ""))}${replaced ? ", replacing what is there" : ""}`)
    )
    passed()
    Ok()
  } else {
    w.run(list)
    ->Result.map(listedSecrets)
    ->then(held => {
      passed()
      Worker_install.secretsPut(
        (w :> Worker_install.context),
        ~command=args => commanded(w, ~root, ~cwd=directory, [...args, "--config", config]),
        ~held,
        ~describe=(name, action) => `the secret ${name} of ${worker.name} ${action}`,
        given,
      )
    })
  }
}

/** Worker_install owns deployment ordering and skips a bundle whose tag is running. */
let deployed = (w: world, ~dry, ~root, ~directory, ~config, ~scratch, ~hashed, worker) => {
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
      Worker_install.deployed(
        (w :> Worker_install.context),
        ~command=args => commanded(w, ~root, ~cwd=directory, args),
        ~config,
        ~name=worker.name,
        ~tag,
        ~secrets,
      )
    })
  }
}
