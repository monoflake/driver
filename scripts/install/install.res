/***
 * driver(cloudflare) made on the account its inputs name, each part only where it is absent and
 * named by 8 hex digits it draws and records, RFC nrs5v, every command run through a world a test
 * fakes.
 */
open Host
open! Install_world
open Install_ledger
open Install_parts

let usage = "install [--dry-run]"

let root = join([fileURLToPath(importMetaUrl), "..", "..", ".."])

@module("node:crypto") external randomBytes: int => Uint8Array.t = "randomBytes"

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

/** A read of stdin that failed for a reason of its own, which install refuses with. */
exception Unread(string)

/** The codes a read answers where stdin is non-blocking and its writer has not written yet. */
let wouldBlock = ["EAGAIN", "EWOULDBLOCK"]

/**
 * All that stdin holds, read to its end, each read that would block waited on and tried again, and
 * any other failure an error named by its code.
 */
let readWhole = (~read, ~wait) => {
  let chunk = Uint8Array.fromLength(65536)
  let held = []
  let ended = ref(None)
  while ended.contents == None {
    switch read(chunk) {
    | 0 => ended := Some(Ok(joined(held)->encoded("utf8")))
    | count => held->Array.push(chunk->TypedArray.slice(~start=0, ~end=count))
    | exception JsExn(error) =>
      switch errorCode(error)->Nullable.toOption {
      | Some(code) if wouldBlock->Array.includes(code) => wait()
      | code =>
        let named = code->Option.orElse(JsExn.message(error))->Option.getOr("an unnamed error")
        ended :=
          Some(Error(`stdin could not be read, ${named}, so whether it holds a token is not known`))
      }
    }
  }
  ended.contents->Option.getOr(Ok(""))
}

/** The binding token and its hash where stdin holds one, None where it holds nothing. */
let tokenOfStdin = w =>
  switch w.stdin() {
  | exception Unread(why) => Error(why)
  | held =>
    switch held->String.trim {
    | "" => Ok(None)
    | token => bindingHash(token)->Result.map(hash => Some((token, hash)))
    }
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
 * What install reads before anything runs, the kinds, every input and the place, one unset or
 * unknown refused, or said where the run is dry, since a dry run acts on nothing.
 */
let inputsOf = (w, ~dry) =>
  kindsOf(w.env)
  ->then(offered => {
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
  ->then(offered => {
    let named = locations->Array.join(" or ")
    let places = `where each database and bucket made is placed, ${named} alone`
    let unplaced = switch (value(w.env, location), placeOf(w.env)) {
    | (_, Some(_)) => None
    | (Some(other), None) => Some(`${location} is "${other}", which names ${places}`)
    | (None, None) => Some(`${location} unset in the environment, which names ${places}`)
    }
    switch unplaced {
    | None => Ok(offered)
    | Some(why) if dry =>
      w.say(`${why}, so a run not dry refuses`)
      Ok(offered)
    // What is made is known only after the reads, and a rerun may add a kind's part,
    // so the place is asked first.
    | Some(why) => Error(`${why}; one there already is never moved`)
    }
  })

/** What a kind no longer offered holds, its Worker's role first and its store's after. */
let heldBy = kind =>
  switch kind {
  | "object" => Some(("object", "bucket", "the bucket"))
  | "database" => Some(("database", "user_database", "the D1 database"))
  | _ => None
  }

/** Cloudflare's answer for a Worker the account does not hold, its error 10007. */
let notFound = why => why->String.includes("[code: 10007]")

/**
 * Each kind not offered whose Worker the driver records and the account holds, named with what it
 * holds and left as it is, since install never removes what a kind dropped from the list holds.
 */
let left = (w, ~dry, ~root, ~install) =>
  kinds
  ->Array.filter(kind => !offers(install, kind))
  ->Array.filterMap(heldBy)
  ->Array.filterMap(((worker, store, what)) =>
    install.parts->Dict.get(worker)->Option.map(full => (worker, full, store, what))
  )
  ->Array.reduce(Ok(), (done, (kind, full, store, what)) =>
    done->then(() => {
      let holds = `${what} ${nameOf(install, store)}`
      let versions = commanded(w, ~root, ~cwd=root, ["versions", "list", "--json", "--name", full])
      if dry {
        w.say(`would run ${shown(versions)}, and where ${full} is there name it and ${holds},`)
        w.say(`  left as they are, ${kind} not being offered`)
        Ok()
      } else {
        switch w.run(versions) {
        | Ok(_) =>
          w.say(`${kind} is not offered, and ${full} and ${holds} are left as they are;`)
          w.say(`  install removes neither, so remove them by hand where they are not wanted`)
          Ok()
        // A Worker not found was never made, or is gone already.
        | Error(why) if notFound(why) => Ok()
        | Error(why) => Error(`whether ${full} is there is not known, ${why}`)
        }
      }
    })
  )

/** The roles of the parts the kinds offered need, the driver's Worker whatever they are. */
let partsFor = offered =>
  Array.concatMany(
    ["driver"],
    [
      offered->Array.includes("object") ? ["object", "bucket"] : [],
      offered->Array.includes("database") ? ["database", "user_database"] : [],
    ],
  )

/**
 * Each part's name, the records' where they hold one and one drawn where not, read before anything
 * is written, each drawn name checked against the account's D1s, Workers and buckets.
 */
let named = (w, ~dry, ~root, ~found: Install_ledger.recovery, ~offered, ~records) => {
  let parts = Dict.fromArray(records->Array.map(((name, role)) => (role, name)))
  let wanted = [
    ...found.state == None ? ["state"] : [],
    ...partsFor(offered)->Array.filter(role => parts->Dict.get(role) == None),
  ]
  if dry {
    wanted->Array.forEach(role => w.say(`a name would be drawn for ${role}, and recorded`))
    found.state->Option.forEach(id => parts->Dict.set("state", id))
    Ok((parts, wanted->Array.map(role => (`<${role}'s name>`, role))))
  } else {
    let buckets = () =>
      offered->Array.includes("object") && wanted != []
        ? w.run(commanded(w, ~root, ~cwd=root, ["r2", "bucket", "list"]))->Result.map(listedBuckets)
        : Ok([])
    buckets()
    ->then(buckets => {
      let taken = [...found.names, ...buckets, ...records->Array.map(((name, _)) => name)]
      Install_ledger.drawn(w, ~workers=found.workers, ~taken, ~count=Array.length(wanted))
    })
    ->Result.map(names => {
      let drawn = wanted->Array.mapWithIndex((role, at) => (names->Array.getUnsafe(at), role))
      drawn->Array.forEach(((name, role)) => {
        parts->Dict.set(role, name)
        w.say(`the name ${name} is drawn for ${role}`)
      })
      found.state->Option.forEach(id => parts->Dict.set("state", id))
      // The state D1 is recorded too, where it was made before the records were.
      let unrecorded =
        found.state->Option.mapOr([], id =>
          records->Array.some(((_, role)) => role == "state") ? [] : [(id, "state")]
        )
      (parts, [...unrecorded, ...drawn])
    })
  }
}

/** The names newly drawn written into the state D1's records, before any of them is made. */
let recorded = (w, ~dry, ~root, ~state, ~written) => {
  let write = commanded(
    w,
    ~root,
    ~cwd=root,
    ["d1", "execute", state, "--remote", "--command", recordsWrite(written)],
  )
  if written == [] {
    Ok()
  } else if dry {
    w.say(`would run ${shown(write)->String.replace(recordsWrite(written), "INSERT INTO owned")},`)
    w.say(`  recording each name drawn before it is made`)
    Ok()
  } else {
    w.run(write)->Result.map(_ =>
      w.say(`the names ${written->Array.map(((name, _)) => name)->Array.join(", ")} recorded`)
    )
  }
}

/**
 * driver(cloudflare) on the account, each part made where it is absent, in nrs5v's order, every
 * read-only check run first, so a failed one stops install with nothing changed.
 */
let install = (w, ~dry, ~root=root) =>
  inputsOf(w, ~dry)->then(offered =>
    tokenOfStdin(w)
    ->then(read =>
      Install_bind.bindOf(w, ~token=read->Option.map(((token, _)) => token))->Result.map(
        bind => (read, bind),
      )
    )
    ->then(((read, bind)) => {
      let hashed = read->Option.map(((_, hash)) => hash)
      if hashed == None {
        w.say(`nothing on stdin, so ${binding} is passed over on each Worker`)
      }
      w.say(`the kinds offered are ${offered->Array.join(", ")}, ${kindsInput}`)
      placeOf(w.env)->Option.forEach(
        hint => w.say(`each database and bucket made is placed in ${hint}, ${location}`),
      )
      recovered(w, ~dry, ~root)->then(
        found =>
          found.state
          ->Option.mapOr(Ok([]), state => recordsOf(w, ~root, ~state, ~tables=found.tables))
          ->then(
            records => {
              passedOver(w, ~foreign=found.foreign, ~empty=found.empty, ~records)
              let parts = Dict.fromArray(records->Array.map(((name, role)) => (role, name)))
              let dropped = {id: "", kinds: offered, parts}
              left(w, ~dry, ~root, ~install=dropped)->then(
                () => named(w, ~dry, ~root, ~found, ~offered, ~records),
              )
            },
          )
          ->then(
            ((parts, written)) => {
              let fresh = found.state == None
              let install = {
                id: nameOf({id: "", kinds: offered, parts}, "state"),
                kinds: offered,
                parts,
              }
              let id = install.id
              let drawn = role => written->Array.some(((_, held)) => held == role)
              let scratch = dry ? "<a directory of its own>" : w.scratch()
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
                      {...worker, name: nameOf(install, worker.name)},
                    ),
                )
              let marker = fresh ? Some(id) : None
              let installed = databaseOf(w, ~dry, ~root, ~marker?, id)->then(
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
                      migrated(w, ~dry, ~root, ~directory, ~config, ~database=id)
                      ->then(() => recorded(w, ~dry, ~root, ~state=id, ~written))
                      ->then(
                        () =>
                          made(
                            "database",
                            () =>
                              databaseOf(
                                w,
                                ~dry,
                                ~root,
                                ~drawn=drawn("user_database"),
                                nameOf(install, "user_database"),
                              )->Result.map(id => ids->Dict.set(userDatabase, id)),
                          ),
                      )
                      ->then(
                        () =>
                          made(
                            "object",
                            () =>
                              bucketOf(
                                w,
                                ~dry,
                                ~root,
                                ~drawn=drawn("bucket"),
                                ~bucket=nameOf(install, "bucket"),
                              ),
                          ),
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
                            {...driver, name: nameOf(install, driver.name)},
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
              // Bound once every Worker is deployed, the Worker `driver` answering the call back.
              installed->then(
                () => Install_bind.bound(w, ~dry, ~bind, ~worker=nameOf(install, "driver")),
              )
            },
          ),
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
  // A terminal holds no token, and a pipe is read to its end however late its writer writes.
  stdin: () =>
    if stdinTerminal() {
      ""
    } else {
      switch readWhole(
        ~read=chunk => readStdinInto(chunk, TypedArray.length(chunk)),
        ~wait=() => pause(10),
      ) {
      | Ok(held) => held
      | Error(why) => throw(Unread(why))
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
