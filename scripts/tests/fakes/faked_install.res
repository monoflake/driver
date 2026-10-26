/***
 * Install run in a world of its own, a root of fixtures, the inputs it is given, what it ran and
 * said, and the lines a first run and a second run each.
 */
open Asserted
open Faked_account

/** A root of its own holding the three Workers' configurations as the repository holds them. */
let fixtures = []
let fixture = () => {
  let root = Host.mkdtempSync(Host.join([Host.tmpdir(), "install-root-"]))
  fixtures->Array.push(root)
  mkdirSync(Host.join([root, "cloudflare", "object"]), {recursive: true})
  mkdirSync(Host.join([root, "cloudflare", "database"]), {recursive: true})
  ["cloudflare", "cloudflare/object", "cloudflare/database"]->Array.forEach(dir =>
    copyFileSync(
      Host.join([Install.root, dir, "wrangler.json"]),
      Host.join([root, dir, "wrangler.json"]),
    )
  )
  root
}

/** The secret 0 to 31, its token, and its BLAKE3 as b3sum gives it. */
let secret = Uint8Array.fromLength(32)
for i in 0 to 31 {
  secret->TypedArray.set(i, i)
}
let token = "7.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
let hashed = "e528e95798037df410543d9f31e396ecdd458d71b157d6014398bae32fb56c65"

/** Cloudflare's documented example account ids. */
let accountId = "023e105f4ecef8ad9ca31a8372d0c353"
let anotherAccount = "699d98642c564d2e855e9661899b7252"

/** Install's own inputs, every kind offered, its parts placed in Western North America. */
let credentials = [
  ("DRIVER_ACCOUNT_ID", accountId),
  ("DRIVER_INSTALL_TOKEN", "the-install-token"),
  ("DRIVER_API_TOKEN", "the-driver-token"),
  ("DATABASE_API_TOKEN", "the-database-token"),
  ("DRIVER_KINDS", "function,object,database"),
  ("DRIVER_CONTROL_BASE", base),
  ("DRIVER_LOCATION", "wnam"),
]

/** What the environment holds besides, which install never reads. */
let ambient = [
  ("CLOUDFLARE_API_TOKEN", "the-ambient-token"),
  ("CLOUDFLARE_ACCOUNT_ID", anotherAccount),
  ("CLOUDFLARE_EMAIL", "author@example.com"),
]

/** Every value no argument and no line said may hold. */
let secrets = [
  "the-install-token",
  "the-ambient-token",
  "the-driver-token",
  "the-database-token",
  token,
  hashed,
]

type faked = {
  world: Install_world.world,
  ran: array<Install_world.command>,
  said: array<string>,
  scratched: array<string>,
}

let make = (~env=credentials, ~stdin=token, ~drawn=id, ~draws=drawnNames, ~answer) => {
  let ran = []
  let queued = draws->Array.copy
  let said = []
  let scratched = []
  let world: Install_world.world = {
    run: command => {
      ran->Array.push(command)
      answer(command)
    },
    env: Dict.fromArray(env),
    say: line => said->Array.push(line),
    stdin: () => stdin,
    scratch: () => {
      let made = Host.mkdtempSync(Host.join([Host.tmpdir(), "install-scratch-"]))
      scratched->Array.push(made)
      made
    },
    draw: () => queued->Array.shift->Option.getOr(drawn),
  }
  {world, ran, said, scratched}
}

/** Each line run with the paths a run makes written as names, a build beside its Worker's. */
let plain = faked =>
  faked.ran->Array.map(command => {
    let within = switch Host.basename(command.program) {
    | "rescript" if command.cwd->String.endsWith("/cloudflare/object") => " in <object>"
    | "rescript" if command.cwd->String.endsWith("/cloudflare/database") => " in <database>"
    | "rescript" if command.cwd->String.endsWith("/cloudflare") => " in <driver>"
    | _ => ""
    }
    let words = line(command)->String.split(" ")
    words
    ->Array.mapWithIndex((word, i) =>
      if word->String.endsWith("/cloudflare/wrangler.install.json") {
        "<driver>"
      } else if word->String.endsWith("/object/wrangler.install.json") {
        "<object>"
      } else if word->String.endsWith("/database/wrangler.install.json") {
        "<database>"
      } else if word->String.includes("install-scratch-") {
        "<out>"
      } else if i > 0 && words->Array.get(i - 1) == Some("--tag") {
        "<tag>"
      } else {
        word
      }
    )
    ->Array.join(" ") ++ within
  })

/** Whether any argument run or any line said holds a secret. */
let shows = faked =>
  secrets->Array.some(s =>
    faked.ran->Array.some(c => c.args->Array.some(a => a->String.includes(s))) ||
      faked.said->Array.some(l => l->String.includes(s))
  )

let installed = (~env=?, ~stdin=?, ~drawn=?, ~draws=?, account, root) => {
  let faked = make(~env?, ~stdin?, ~drawn?, ~draws?, ~answer=command => answered(account, command))
  let result = Install.install(faked.world, ~dry=false, ~root)
  (faked, result)
}

/** What a first install records, each name drawn by its role. */
let drawnRecords = [
  ("0a1b2c3d", "state"),
  ("1b2c3d4e", "driver"),
  ("2c3d4e5f", "object"),
  ("3d4e5f6a", "bucket"),
  ("4e5f6a7b", "database"),
  ("5f6a7b8c", "user_database"),
]

/** The subdomain read and the bind, the last two a run with both its halves makes. */
let subdomainRead = [
  "curl -q --silent --show-error --fail-with-body ",
  "--connect-timeout 10 --max-time 30 --header @- ",
  "https://api.cloudflare.com/client/v4/accounts/023e105f4ecef8ad9ca31a8372d0c353/",
  "workers/subdomain",
]->Array.join("")
let origin = "https://1b2c3d4e.my-subdomain.workers.dev"
let bindLine = line(Install_bind.bindCall(~token="", ~base, ~origin, ~env=dict{}))
let bound = [subdomainRead, bindLine]

let first = [
  "wrangler d1 list --json",
  workersListed,
  "wrangler r2 bucket list",
  "wrangler d1 list --json",
  "wrangler d1 create 0a1b2c3d --location wnam",
  markerWritten("0a1b2c3d"),
  "wrangler d1 list --json",
  "wrangler d1 migrations apply 0a1b2c3d --remote --config <driver>",
  recordsWritten("0a1b2c3d", drawnRecords),
  "wrangler d1 list --json",
  "wrangler d1 create 5f6a7b8c --location wnam",
  "wrangler d1 list --json",
  "wrangler r2 bucket list",
  "wrangler r2 bucket create 3d4e5f6a --location wnam",
  "rescript build in <driver>",
  "wrangler deploy --dry-run --outdir <out> --config <driver>",
  "wrangler versions list --json --config <driver>",
  "wrangler deploy --config <driver> --tag <tag>",
  "wrangler secret list --config <driver>",
  "wrangler secret put API_TOKEN --config <driver>",
  "wrangler secret put BINDING --config <driver>",
  "rescript build in <object>",
  "wrangler deploy --dry-run --outdir <out> --config <object>",
  "wrangler versions list --json --config <object>",
  "wrangler deploy --config <object> --tag <tag>",
  "wrangler secret list --config <object>",
  "wrangler secret put BINDING --config <object>",
  "rescript build in <database>",
  "wrangler deploy --dry-run --outdir <out> --config <database>",
  "wrangler versions list --json --config <database>",
  "wrangler deploy --config <database> --tag <tag>",
  "wrangler secret list --config <database>",
  "wrangler secret put API_TOKEN --config <database>",
  "wrangler secret put BINDING --config <database>",
  ...bound,
]

let again = [
  "wrangler d1 list --json",
  tablesRead("0a1b2c3d"),
  markerRead("0a1b2c3d"),
  tablesRead("5f6a7b8c"),
  workersListed,
  recordsRead("0a1b2c3d"),
  "wrangler d1 list --json",
  "wrangler d1 migrations apply 0a1b2c3d --remote --config <driver>",
  "wrangler d1 list --json",
  "wrangler r2 bucket list",
  "rescript build in <driver>",
  "wrangler deploy --dry-run --outdir <out> --config <driver>",
  "wrangler versions list --json --config <driver>",
  "wrangler secret list --config <driver>",
  "wrangler secret put BINDING --config <driver>",
  "rescript build in <object>",
  "wrangler deploy --dry-run --outdir <out> --config <object>",
  "wrangler versions list --json --config <object>",
  "wrangler secret list --config <object>",
  "wrangler secret put BINDING --config <object>",
  "rescript build in <database>",
  "wrangler deploy --dry-run --outdir <out> --config <database>",
  "wrangler versions list --json --config <database>",
  "wrangler secret list --config <database>",
  "wrangler secret put BINDING --config <database>",
  ...bound,
]

let moments = root => [
  Host.join([root, "cloudflare", Install_world.moment]),
  Host.join([root, "cloudflare", "object", Install_world.moment]),
  Host.join([root, "cloudflare", "database", Install_world.moment]),
]

/** The reads a dry run may run, the D1 and Workers lists, and the tables, marker and records
 * queries. */
let reads = command => {
  let l = line(command)
  l == "wrangler d1 list --json" ||
  l == workersListed ||
  (l->String.startsWith("wrangler d1 execute ") &&
    [
      Install_ledger.tablesQuery,
      Install_ledger.markerQuery,
      Install_ledger.recordsQuery,
    ]->Array.some(q => l->String.endsWith(`${q} --json`)))
}

/** A dry run whose commands are answered by `account`, any but the reads refused. */
let dryOn = (~env=?, ~answer=?, account, root) => {
  let answer =
    answer->Option.getOr(command =>
      reads(command) ? answered(account, command) : Error(`ran ${line(command)}`)
    )
  let faked = make(~env?, ~answer)
  (faked, Install.install(faked.world, ~dry=true, ~root))
}

/** Whether a line run changes anything, on the account or in the checkout. */
let writes = l =>
  [
    " create ",
    "migrations apply",
    "CREATE TABLE",
    "INSERT INTO",
    "deploy",
    "secret put",
    "rescript build",
  ]->Array.some(w => l->String.includes(w))

/** That nothing was changed, no line written and no scratch directory made. */
let unchanged = faked => {
  let lines = plain(faked)
  ok(lines->Array.every(l => !writes(l)), ~message=lines->Array.join("\n"))
  deepEqual(faked.scratched, [])
}
