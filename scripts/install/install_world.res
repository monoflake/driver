/***
 * What install is given and how it speaks to the world, its names, its inputs, its commands and
 * the environments they run in, every command a test fakes.
 */

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
let driverToken = "CLOUDFLARE_DRIVER_SCRIPTS"
let databaseToken = "CLOUDFLARE_DRIVER_DATABASE"
let kindsInput = "DRIVER_KINDS"
/** Where the control's calls are sent, as the runner's `--base` names it, platform RFC 8j7b0. */
let controlBase = "DRIVER_CONTROL_BASE"

/** The name wrangler reads its account by, set in its own environment alone and never read from
 * install's; wrangler runs on the Mac's own login. */
let wranglerAccount = "CLOUDFLARE_ACCOUNT_ID"

/** The kinds the driver may offer, `function` alone where `DRIVER_KINDS` names none. */
let kinds = ["function", "object", "database"]
let defaultKinds = ["function"]

/**
 * Where each database and bucket install makes is placed, one of `locations` alone and never left
 * to Cloudflare, the workspace's `cloudflare-placed`; one there already is never moved.
 */
let location = "DRIVER_LOCATION"
let locations = ["wnam", "apac"]

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

// Shared installation primitives belong to Worker_install.
include Worker_install.World
let noEnvFile = Worker_install.noEnvFile
type world = {
  ...Worker_install.context,
  stdin: unit => string,
  draw: unit => string,
}
let then = Worker_install.then
let shown = Worker_install.shown
let value = Worker_install.value
let quiet = Worker_install.quiet
let member = Worker_install.member
let text = Worker_install.text
let parsed = Worker_install.parsed

/** The place `DRIVER_LOCATION` names, where it names one of `locations`. */
let placeOf = env => value(env, location)->Option.filter(hint => locations->Array.includes(hint))

/** The environment wrangler runs in, its account set from install's own input, `HOME` kept so
 * wrangler finds its login. */
let accounted = env => {
  let given = quiet(env)
  given->Dict.set(wranglerAccount, value(env, account)->Option.getOr(""))
  given
}

/** A wrangler command run in `cwd` reading no `.env`, wrangler being the cloudflare block's. */
let wrangler = (~root, ~cwd, ~env, arguments) =>
  Worker_install.command(
    ~program=Host.join([root, "cloudflare", "node_modules", ".bin", "wrangler"]),
    ~cwd,
    ~env,
    arguments,
  )

/** A command of the account's, given install's own account alone. */
let commanded = (w, ~root, ~cwd, arguments) =>
  wrangler(~root, ~cwd, ~env=accounted(w.env), arguments)

/** The read of the Mac's own wrangler login, its token printed as JSON. */
let loginRead = (w, ~root) => commanded(w, ~root, ~cwd=root, ["auth", "token", "--json"])

/** The token a login read answers, its answer never said since it holds the token. */
let bearerOf = body =>
  switch parsed(body)->Option.flatMap(json => json->text("token")) {
  | Some(token) if token != "" => Ok(token)
  | Some(_) | None => Error("wrangler auth token answered no token, so run wrangler login first")
  }

/** The bearer of the Mac's wrangler login, read fresh for each call and never kept. */
let bearer = (w, ~root) => w.run(loginRead(w, ~root))->then(bearerOf)
