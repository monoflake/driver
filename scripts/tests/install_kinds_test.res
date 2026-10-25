/***
 * The kinds DRIVER_KINDS offers, added or left on a rerun, and the environment each command runs
 * in, no ambient sign in reaching it and wrangler reading no .env.
 */
open Asserted
open Faked_account
open Faked_install

let only = (kinds: option<string>) =>
  [
    ...credentials->Array.filter(((name, _)) =>
      name != "DRIVER_KINDS" && name != "DATABASE_API_TOKEN"
    ),
    ...kinds->Option.mapOr([], k => [("DRIVER_KINDS", k)]),
  ]

test(
  "function alone by default makes the driver's Worker and D1, and asks no database token",
  () => {
    let account = empty()
    let (faked, result) = installed(~env=only(None), account, fixture())
    deepEqual(result, Ok())
    deepEqual(
      plain(faked),
      [
        "wrangler d1 list --json",
        workersListed,
        "wrangler versions list --json --name object-0a1b2c3d",
        "wrangler versions list --json --name database-0a1b2c3d",
        "wrangler d1 list --json",
        "wrangler d1 create driver-0a1b2c3d",
        markerWritten("driver-0a1b2c3d"),
        "wrangler d1 list --json",
        "wrangler d1 migrations apply driver-0a1b2c3d --remote --config <driver>",
        "rescript build in <driver>",
        "wrangler deploy --dry-run --outdir <out> --config <driver>",
        "wrangler versions list --json --config <driver>",
        "wrangler deploy --config <driver> --tag <tag>",
        "wrangler secret list --config <driver>",
        "wrangler secret put API_TOKEN --config <driver>",
        "wrangler secret put BINDING --config <driver>",
      ],
    )
    ok(faked.said->Array.includes("the kinds offered are function, DRIVER_KINDS"))
    deepEqual((account.databases, account.buckets), ([full("driver")], []))
    let driver = account.workers->Dict.getUnsafe(full("driver"))
    let kinds =
      driver.deployed
      ->Array.get(0)
      ->Option.flatMap(Install_world.parsed)
      ->Option.map(config => config->Install_world.member("vars")->Install_world.text("KINDS"))
    deepEqual(kinds, Some(Some("function")))
  },
)

test("a kind listed on a rerun is added, and one dropped is named and left as it is", () => {
  let account = empty()
  let root = fixture()
  let _ = installed(~env=only(None), account, root)
  let (added, result) = installed(~env=only(Some("object,function")), account, root)
  deepEqual(result, Ok())
  deepEqual(
    plain(added)->Array.filter(l =>
      l->String.includes(" create ") || l->String.startsWith("wrangler deploy --config")
    ),
    [
      "wrangler r2 bucket create objects-0a1b2c3d",
      "wrangler deploy --config <driver> --tag <tag>",
      "wrangler deploy --config <object> --tag <tag>",
    ],
  )
  ok(added.said->Array.includes("the kinds offered are function, object, DRIVER_KINDS"))
  let (dropped, result) = installed(~env=only(Some("function")), account, root)
  deepEqual(result, Ok())
  ok(plain(dropped)->Array.every(l => !(l->String.includes("delete"))))
  deepEqual(account.buckets, [full("objects")])
  ok(
    dropped.said->Array.includes(
      [
        "object is not offered, and object-0a1b2c3d and the bucket objects-0a1b2c3d ",
        "are left as they are;",
      ]->Array.join(""),
    ),
    ~message=dropped.said->Array.join("\n"),
  )
  ok(dropped.said->Array.every(l => !(l->String.includes("database-0a1b2c3d and"))))
})

test("DRIVER_KINDS naming anything but function, object and database is refused", () => {
  ["function,instance", "function,", "Function", "function object"]->Array.forEach(kinds => {
    let faked = make(~env=only(Some(kinds)), ~answer=_ => Ok(""))
    ok(Install.install(faked.world, ~dry=false, ~root=fixture())->Result.isError, ~message=kinds)
    deepEqual(faked.ran, [])
  })
})

test("no ambient CLOUDFLARE_ name reaches a command, wrangler given install's own", () => {
  let (faked, result) = installed(~env=[...ambient, ...credentials], empty(), fixture())
  deepEqual(result, Ok())
  ok(!shows(faked))
  faked.ran->Array.forEach(command => {
    let values = command.env->Dict.valuesToArray
    ok(
      !(values->Array.includes("the-ambient-token") || values->Array.includes(anotherAccount)),
      ~message=line(command),
    )
    deepEqual(command.env->Dict.get("CLOUDFLARE_EMAIL"), None)
    deepEqual(command.env->Dict.get("DRIVER_INSTALL_TOKEN"), None)
  })
  ok(
    faked.ran->Array.some(c =>
      c.env->Dict.get("CLOUDFLARE_API_TOKEN") == Some("the-install-token")
    ),
  )
})

test("no CF_ name reaches a command, and wrangler is pointed at an empty env file", () => {
  let root = fixture()
  // A .env wrangler would load from where it runs, were it not given the empty file instead.
  let dotEnv = "CLOUDFLARE_API_KEY=the-dotenv-key\nCLOUDFLARE_EMAIL=dotenv@example.com\n"
  ["", "cloudflare", "cloudflare/object", "cloudflare/database"]->Array.forEach(dir =>
    Host.writeFileSync(Host.join([root, dir, ".env"]), dotEnv)
  )
  let legacy = [
    ("CF_API_KEY", "the-legacy-key"),
    ("CF_EMAIL", "legacy@example.com"),
    ("CF_API_BASE_URL", "https://api.example/client/v4"),
  ]
  let (faked, result) = installed(~env=[...legacy, ...credentials], empty(), root)
  deepEqual(result, Ok())
  faked.ran->Array.forEach(command => {
    let names = command.env->Dict.keysToArray
    deepEqual(
      names->Array.filter(name => name->String.startsWith("CF_")),
      [],
      ~message=line(command),
    )
    let values = command.env->Dict.valuesToArray
    ok(legacy->Array.every(((_, v)) => !(values->Array.includes(v))), ~message=line(command))
    if Host.basename(command.program) == "wrangler" {
      deepEqual(command.args->Array.slice(~start=-2), ["--env-file", "/dev/null"])
    }
  })
})

test("the bundle is written in the quiet environment, given no account and no token", () => {
  let (faked, result) = installed(empty(), fixture())
  deepEqual(result, Ok())
  let bundles = faked.ran->Array.filter(c => c.args->Array.includes("--dry-run"))
  deepEqual(Array.length(bundles), 3)
  bundles->Array.forEach(command =>
    deepEqual(
      (
        command.env->Dict.get("CLOUDFLARE_API_TOKEN"),
        command.env->Dict.get("CLOUDFLARE_ACCOUNT_ID"),
      ),
      (None, None),
    )
  )
})

test("a D1 list that is no JSON array is an error, never an empty account", () => {
  let lists = ref(0)
  let account = empty()
  let unreadAt = at =>
    command =>
      if line(command) == "wrangler d1 list --json" {
        lists := lists.contents + 1
        lists.contents == at ? Ok("not JSON") : answered(account, command)
      } else {
        answered(account, command)
      }
  let refused = Error("d1 list printed no JSON array, so the account's databases are not known")
  // The first list is recovery's, the second the driver's D1's, after the checks.
  [1, 2]->Array.forEach(at => {
    lists := 0
    let faked = make(~answer=unreadAt(at))
    deepEqual(Install.install(faked.world, ~dry=false, ~root=fixture()), refused)
    ok(plain(faked)->Array.every(l => !(l->String.includes(" create "))))
  })
})

test("a dropped kind's lookup failing otherwise than not found stops install, nothing run", () => {
  let account = empty()
  let answer = command =>
    line(command) == "wrangler versions list --json --name object-0a1b2c3d"
      ? Error("Authentication error [code: 10000]")
      : answered(account, command)
  let faked = make(~env=only(None), ~answer)
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("whether object-0a1b2c3d is there is not known, Authentication error [code: 10000]"),
  )
  unchanged(faked)
  deepEqual((account.databases, account.buckets, account.marks), ([], [], dict{}))
})

after(() => fixtures->Array.forEach(root => Host.rmSync(root, {recursive: true, force: true})))
