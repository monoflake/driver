/***
 * What install is given and how it speaks to the world, its names, its inputs, its commands and
 * the environments they run in, every command a test fakes.
 */
open Host

/** The names each Worker's own configuration gives the driver's D1, the database kind's and the
 * bucket, which install replaces by the names it records. */
let database = "driver"
let userDatabase = "database"
let bucket = "objects"

/** The role the driver records a part of its configuration in, by its kind and its own name. */
let databaseRole = name => name == database ? "state" : "user_database"
let bucketRole = "bucket"

/** What it is given, read from the environment alone, as this repository is public. */
let account = "DRIVER_ACCOUNT_ID"
let installToken = "DRIVER_INSTALL_TOKEN"
let driverToken = "DRIVER_API_TOKEN"
let databaseToken = "DATABASE_API_TOKEN"
let kindsInput = "DRIVER_KINDS"
/** Where the control's calls are sent, as the runner's `--base` names it, platform RFC 8j7b0. */
let controlBase = "DRIVER_CONTROL_BASE"

/** The names wrangler reads, set in its own environment alone and never read from install's. */
let wranglerToken = "CLOUDFLARE_API_TOKEN"
let wranglerAccount = "CLOUDFLARE_ACCOUNT_ID"

/** The file wrangler loads in place of `.env` and `.env.local`, which holds nothing. */
let noEnvFile = ["--env-file", "/dev/null"]

/** The kinds the driver may offer, `function` alone where `DRIVER_KINDS` names none. */
let kinds = ["function", "object", "database"]
let defaultKinds = ["function"]

/** The hint the database and the bucket are placed by, none given letting Cloudflare place them. */
let location = "DRIVER_LOCATION"

/** Where a secret's value comes from, a variable of the environment or the binding's hash. */
type source = Environment(string) | Bound

/** A Worker, its directory beneath the root and the secrets it is given by name. */
type worker = {name: string, directory: array<string>, secrets: array<(string, source)>}

/**
 * What one install acts on, its install id, the state D1's own name, the kinds it offers and each
 * part's name by the role the driver records it in, RFC nrs5v's bare ids.
 */
type install = {id: string, kinds: array<string>, parts: dict<string>}

/** A part's name by its role, said by its role where a dry run has not drawn it. */
let nameOf = (install, role) => install.parts->Dict.get(role)->Option.getOr(`<${role}'s name>`)

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
  /** What stdin holds, empty where it is a terminal, `Install.Unread` raised where a read fails. */
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
 * The names a spawned command is given from install's own environment, and nothing else, since
 * install runs in a person's shell holding secrets of every kind a deny list would miss.
 */
let allowed = ["PATH", "HOME", "TMPDIR", "USER", "LANG"]

/** The environment the commands run in, the allowed names alone, quiet and unasking. */
let quiet = env => {
  let given = Dict.make()
  allowed->Array.forEach(name =>
    env->Dict.get(name)->Option.forEach(value => given->Dict.set(name, value))
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

/** A JSON object's member, or null. */
let member = (json, name) =>
  json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(name))->Option.getOr(JSON.Null)
let text = (json, name) => json->member(name)->JSON.Decode.string

let parsed = body =>
  switch JSON.parseOrThrow(body) {
  | json => Some(json)
  | exception JsExn(_) => None
  }
