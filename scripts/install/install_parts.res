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

/** The arguments placing a part where `DRIVER_LOCATION` names, said by its name in a dry run. */
let placed = w => ["--location", placeOf(w.env)->Option.getOr(`<${location}>`)]

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
 * A database made where `DRIVER_LOCATION` places it and the account lists none by its name, and its
 * id, marked with `marker` first where one is given, so it must be made here, as one `drawn` must.
 */
let databaseOf = (w, ~dry, ~root, ~marker=?, ~drawn=false, database) => {
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
    | Ok(Some(_)) if marking != None || drawn =>
      Error(`${database} is listed already, though its name was drawn as free`)
    | Ok(Some(id)) =>
      w.say(`the database ${database} is there already`)
      Ok(id)
    | Ok(None) =>
      w.run(create)
      ->Result.map(_ => w.say(`the database ${database} made`))
      ->then(_ => marked())
      ->then(_ => w.run(list))
      ->then(body => listedDatabase(body, database))
      ->then(found =>
        switch found {
        | Some(id) => Ok(id)
        | None => Error(`${database} made but not listed`)
        }
      )
    }
  }
}

/**
 * The bucket made where `DRIVER_LOCATION` places it, where the account lists none by its name, as
 * one `drawn` is.
 */
let bucketOf = (w, ~dry, ~root, ~drawn=false, ~bucket) => {
  let list = commanded(w, ~root, ~cwd=root, ["r2", "bucket", "list"])
  let create = commanded(w, ~root, ~cwd=root, ["r2", "bucket", "create", bucket, ...placed(w)])
  if dry {
    w.say(`would run ${shown(list)}, and ${shown(create)} unless ${bucket} is listed`)
    Ok()
  } else {
    switch w.run(list)->Result.map(listedBuckets) {
    | Error(why) => Error(why)
    | Ok(names) if names->Array.includes(bucket) && drawn =>
      Error(`the bucket ${bucket} is listed already, though its name was drawn as free`)
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

/**
 * Each of a Worker's secrets put where it holds none by that name, and `BINDING` written whenever
 * stdin holds a token, replacing what is there, since a secret cannot be read back to compare and
 * a token given means bind; with nothing on stdin it is never touched.
 */
let secretsPut = (w, ~dry, ~root, ~directory, ~config, ~hashed, worker) => {
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
      given->Array.reduce(Ok(), (done, (name, secret, replaced)) =>
        done->then(
          () =>
            if held->Array.includes(name) && !replaced {
              w.say(`the secret ${name} of ${worker.name} is there already`)
              Ok()
            } else {
              let was = held->Array.includes(name) ? "replaced" : "put"
              w.run(put(name, secret))->Result.map(
                _ => w.say(`the secret ${name} of ${worker.name} ${was}`),
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
