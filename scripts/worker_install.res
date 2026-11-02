/*** The shared Worker installation primitives owned by monoflake/driver. */
@module("node:path") external basename: string => string = "basename"
@module("node:path") @variadic external join: array<string> => string = "join"
@module("node:fs") external readFileSync: (string, @as("utf8") _) => string = "readFileSync"
@module("node:fs") external readBytes: string => Uint8Array.t = "readFileSync"
@module("node:fs")
external readdirSync: (string, {"recursive": bool}) => array<string> = "readdirSync"
@module("node:fs") external statSync: string => {"isFile": unit => bool} = "statSync"
type hash
@module("node:crypto") external createHash: string => hash = "createHash"
@send external update: (hash, Uint8Array.t) => hash = "update"
@send external updateText: (hash, string) => hash = "update"
@send external digest: (hash, @as("hex") _) => string = "digest"

module World = {
  type command = {
    program: string,
    args: array<string>,
    cwd?: string,
    input?: string,
    env?: Dict.t<string>,
    stream?: bool,
  }
  type request = {method: string, headers: Dict.t<string>, body?: string}
  type answered = {status: int, body: string}

  type context = {
    run: command => result<string, string>,
    env: Dict.t<string>,
    say: string => unit,
    scratch: unit => string,
  }
}
include World
let then = (result, next) => result->Result.flatMap(next)

let value = (env, name) => env->Dict.get(name)->Option.filter(v => v != "" && v != "unset")

/** A command as a dry run prints it, its program's name and arguments, stdin said, never shown. */
let shown = command => {
  let line = [basename(command.program), ...command.args]->Array.join(" ")
  command.input->Option.isSome ? `${line}, its value on stdin` : line
}

/** The spawned environment takes only these names from the caller. */
let allowed = ["PATH", "HOME", "TMPDIR", "USER", "LANG"]

/** The environment the commands run in, the allowed names alone, quiet and unasking. */
let quiet = env => {
  let given = Dict.make()
  allowed->Array.forEach(name =>
    env->Dict.get(name)->Option.forEach(value => given->Dict.set(name, value))
  )
  given->Dict.set("WRANGLER_SEND_METRICS", "false")
  given->Dict.set("CI", "1")
  given->Dict.set("CLOUDFLARE_CF_FETCH_ENABLED", "false")
  given
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

let noEnvFile = ["--env-file", "/dev/null"]
let command = (~program, ~cwd, ~env, arguments): command => {
  program,
  cwd,
  env,
  args: [...arguments, ...noEnvFile],
}
let arguments = (command: command) => {
  let n = Array.length(command.args)
  command.args->Array.slice(~start=n - 2) == noEnvFile
    ? command.args->Array.slice(~start=0, ~end=n - 2)
    : command.args
}
let line = command => [basename(command.program), ...arguments(command)]->Array.join(" ")
let shows = (~ran, ~said, secrets) =>
  secrets->Array.some(secret =>
    ran->Array.some(c => c.args->Array.some(a => a->String.includes(secret))) ||
      said->Array.some(l => l->String.includes(secret))
  )

/** The command and message log used by caller test worlds. */
let recording = (~answer) => {
  let ran = []
  let said = []
  let run = command => {
    ran->Array.push(command)
    answer(command)
  }
  let say = line => said->Array.push(line)
  (ran, said, run, say)
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

let databaseOf = (
  w,
  ~dry,
  ~command,
  ~create,
  ~listed,
  ~fresh=false,
  ~created=() => Ok(),
  ~marking=[],
  ~placeholder,
  database,
) => {
  let list = command(["d1", "list", "--json"])
  // The caller names the create's place, where the place check reads it.
  let create = command(create)
  if dry {
    w.say(`would run ${shown(list)}, and ${shown(create)} unless ${database} is listed`)
    marking->Array.forEach(line => w.say(line))
    Ok(placeholder)
  } else {
    switch w.run(list)->then(listed) {
    | Error(why) => Error(why)
    | Ok(Some(_)) if fresh =>
      Error(`${database} is listed already, though its name was drawn as free`)
    | Ok(Some(id)) =>
      w.say(`the database ${database} is there already`)
      Ok(id)
    | Ok(None) =>
      w.run(create)
      ->then(_ => created())
      ->then(_ => w.run(list))
      ->then(listed)
      ->then(found =>
        switch found {
        | Some(id) => Ok(id)
        | None => Error(`${database} made but not listed`)
        }
      )
    }
  }
}
let bucketOf = (w, ~dry, ~command, ~create, ~drawn=false, ~bucket) => {
  let list = command(["r2", "bucket", "list"])
  let create = command(create)
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
let bundled = (w, ~command, ~config, ~out) =>
  w.run(command(["deploy", "--dry-run", "--outdir", out, "--config", config]))->Result.map(_ => {
    let hashed = createHash("sha256")->updateText(readFileSync(config))
    readdirSync(out, {"recursive": true})
    ->Array.toSorted(String.compare)
    ->Array.filter(name => statSync(join([out, name]))["isFile"]())
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

/** Secrets reach the command only on stdin. */
let secretsPut = (w, ~command, ~held, ~describe, given) =>
  given->Array.reduce(Ok(), (done, (name, value, replace)) =>
    done->then(() => {
      let present = held->Array.includes(name)
      if present && !replace {
        w.say(describe(name, "is there already"))
        Ok()
      } else {
        let put = {...command(["secret", "put", name]), input: value}
        w.run(put)->Result.map(_ => w.say(describe(name, present ? "replaced" : "put")))
      }
    })
  )

/** Existing Workers receive secrets before a deploy and new Workers after it. */
let deployed = (w, ~command, ~config, ~name, ~tag, ~secrets) => {
  let versions = command(["versions", "list", "--json", "--config", config])
  let deploy = () =>
    w.run(command(["deploy", "--config", config, "--tag", tag]))->Result.map(_ =>
      w.say(`the Worker ${name} deployed, ${tag}`)
    )
  switch w.run(versions) {
  | Ok(body) =>
    secrets()->then(() =>
      if runningTag(body) == Some(tag) {
        w.say(`the Worker ${name} runs this bundle already, ${tag}`)
        Ok()
      } else {
        deploy()
      }
    )
  | Error(_) => deploy()->then(secrets)
  }
}
