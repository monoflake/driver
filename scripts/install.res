/***
 * driver(cloudflare) made on the account its inputs name, each part only where it is absent and
 * named by its install id, RFC nrs5v's Ledger, every command run through a world a test fakes.
 */
open Host
open! Install_world
open Install_ledger
open Install_parts

let usage = "install [--dry-run]"

let root = join([fileURLToPath(importMetaUrl), "..", ".."])

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
