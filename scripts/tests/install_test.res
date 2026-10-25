/***
 * `install` against an account faked as wrangler shows it, its plan dry, its first run making each
 * part in order and a second changing nothing, every name followed by the install id.
 */
open Asserted
open Faked_account
open Faked_install

test("a dry run reads the D1 list alone, writes nothing and shows no secret", () => {
  let root = fixture()
  let (faked, result) = dryOn(empty(), root)
  deepEqual(result, Ok())
  deepEqual((plain(faked), faked.scratched), (["wrangler d1 list --json"], []))
  ok(!shows(faked), ~message="a secret was said")
  ok(moments(root)->Array.every(path => !Host.existsSync(path)))
  ok(
    [
      "d1 list names no driver's D1 holding its marker, so a new install id would be drawn",
      "wrangler d1 execute driver-<install id> --remote --command CREATE TABLE install",
      "wrangler d1 create driver-<install id>",
      "wrangler d1 create database-<install id>",
      "wrangler d1 migrations apply driver-<install id> --remote",
      "wrangler r2 bucket create objects-<install id>",
      "rescript build in cloudflare",
      "rescript build in cloudflare/object",
      "rescript build in cloudflare/database",
      "the variables INSTALL_ID, ACCOUNT_ID, KINDS filled in",
      "the variables INSTALL_ID, ACCOUNT_ID, DATABASE_ID filled in",
      "wrangler deploy --config",
      "wrangler secret put API_TOKEN",
      "wrangler secret put BINDING",
    ]->Array.every(said => faked.said->Array.some(l => l->String.includes(said))),
    ~message=faked.said->Array.join("\n"),
  )
})

test("a dry run says which install id it would reuse, and refuses where two are marked", () => {
  let account = empty()
  account.databases = ["other"]
  account->holding("driver-0a1b2c3d", ~mark=id)
  let (faked, result) = dryOn(account, fixture())
  deepEqual(result, Ok())
  ok(
    faked.said->Array.includes(
      "d1 list names driver-0a1b2c3d, so the install id 0a1b2c3d would be reused",
    ),
  )
  ok(
    faked.said->Array.some(l => l->String.includes("wrangler d1 migrations apply driver-0a1b2c3d")),
  )
  account->holding("driver-4e5f6a7b", ~mark="4e5f6a7b")
  let (faked, result) = dryOn(account, fixture())
  ok(result->Result.isError)
  deepEqual(
    plain(faked),
    [
      "wrangler d1 list --json",
      tablesRead("driver-0a1b2c3d"),
      markerRead("driver-0a1b2c3d"),
      tablesRead("driver-4e5f6a7b"),
      markerRead("driver-4e5f6a7b"),
    ],
  )
})

test("a dry run that cannot read the account prints the rule and says why", () => {
  let rule =
    [
      "  it reuses the install id of the one driver-<8 hex> holding the driver's marker, ",
      "draws a",
    ]->Array.join("")
  let (failed, result) = dryOn(~answer=_ => Error("the list failed"), empty(), fixture())
  deepEqual(result, Ok())
  ok(failed.said->Array.includes(rule), ~message=failed.said->Array.join("\n"))
  ok(failed.said->Array.some(l => l == "the install id is not known, as the list failed;"))
  let (unread, result) = dryOn(~answer=_ => Ok("not JSON"), empty(), fixture())
  deepEqual(result, Ok())
  ok(unread.said->Array.some(l => l->String.includes("d1 list printed no JSON array")))
  let env = credentials->Array.filter(((name, _)) => name != "DRIVER_INSTALL_TOKEN")
  let (unset, result) = dryOn(~env, empty(), fixture())
  deepEqual(result, Ok())
  deepEqual(unset.ran, [])
  ok(unset.said->Array.includes("the install id is not known, as DRIVER_INSTALL_TOKEN unset;"))
  ok(unset.said->Array.includes(rule))
  ok(
    unset.said->Array.includes(
      "DRIVER_INSTALL_TOKEN unset in the environment, so a run not dry refuses",
    ),
  )
})

test("a missing input is refused by its name before anything runs, none read in its stead", () => {
  let root = fixture()
  let env = [...ambient, ("DRIVER_ACCOUNT_ID", "")]
  let faked = make(~env, ~answer=_ => Ok(""))
  let names = "DRIVER_ACCOUNT_ID, DRIVER_INSTALL_TOKEN, DRIVER_API_TOKEN"
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root),
    Error(`${names} unset in the environment, which alone gives them`),
  )
  deepEqual(faked.ran, [])
  // A dry run names them, and reads nothing, the account being unknown.
  let faked = make(~env, ~answer=_ => Ok(""))
  deepEqual(Install.install(faked.world, ~dry=true, ~root), Ok())
  deepEqual(faked.ran, [])
  ok(faked.said->Array.includes(`${names} unset in the environment, so a run not dry refuses`))
})

test("DRIVER_ACCOUNT_ID unset is refused, though CLOUDFLARE_ACCOUNT_ID is set", () => {
  let root = fixture()
  let env = [...credentials->Array.filter(((name, _)) => name != "DRIVER_ACCOUNT_ID"), ...ambient]
  let faked = make(~env, ~answer=_ => Ok(""))
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root),
    Error("DRIVER_ACCOUNT_ID unset in the environment, which alone gives them"),
  )
  deepEqual(faked.ran, [])
  let faked = make(~env, ~answer=_ => Ok(""))
  deepEqual(Install.install(faked.world, ~dry=true, ~root), Ok())
  deepEqual(faked.ran, [])
})

test("DATABASE_API_TOKEN missing is refused by its name alone, and said in a dry run", () => {
  let root = fixture()
  let env = credentials->Array.filter(((name, _)) => name != "DATABASE_API_TOKEN")
  let faked = make(~env, ~answer=_ => Ok(""))
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root),
    Error("DATABASE_API_TOKEN unset in the environment, which alone gives them"),
  )
  deepEqual(faked.ran, [])
  let (faked, result) = dryOn(~env, empty(), root)
  deepEqual(result, Ok())
  ok(
    faked.said->Array.includes(
      "DATABASE_API_TOKEN unset in the environment, so a run not dry refuses",
    ),
  )
})

test("a first install makes each part in order, and a second changes nothing", () => {
  let root = fixture()
  let account = empty()
  let (made, result) = installed(account, root)
  deepEqual(result, Ok())
  deepEqual(plain(made), first)
  deepEqual(account.marks->Dict.get(full("driver")), Some(id))
  let (kept, result) = installed(account, root)
  deepEqual(result, Ok())
  deepEqual(plain(kept), again)
  ok(moments(root)->Array.every(path => !Host.existsSync(path)), ~message="a moment was left")
  ok(
    [...made.scratched, ...kept.scratched]->Array.every(path => !Host.existsSync(path)),
    ~message="a scratch directory was left",
  )
})

test("each part the account holds already is passed over", () => {
  let root = fixture()
  let account = empty()
  account.databases = ["other", "driver", "database-0a1b2c3d"]
  account->holding("driver-0a1b2c3d", ~mark=id)
  account.buckets = ["objects", "objects-0a1b2c3d"]
  let (faked, result) = installed(account, root)
  deepEqual(result, Ok())
  let lines = plain(faked)
  ok(lines->Array.every(l => !(l->String.includes(" create "))), ~message=lines->Array.join("\n"))
  ok(faked.said->Array.includes("the database driver-0a1b2c3d is there already"))
  ok(faked.said->Array.includes("the database database-0a1b2c3d is there already"))
  ok(faked.said->Array.includes("the bucket objects-0a1b2c3d is there already"))
})

test("a Worker is deployed again only where its bundle or its configuration changed", () => {
  let root = fixture()
  let account = empty()
  let _ = installed(account, root)
  let object = account.workers->Dict.getUnsafe(full("object"))
  let driver = account.workers->Dict.getUnsafe(full("driver"))
  object.bundle = "the object's bundle, changed"
  let (faked, result) = installed(account, root)
  deepEqual(result, Ok())
  deepEqual(
    plain(faked)->Array.filter(l => l->String.startsWith("wrangler deploy --config")),
    ["wrangler deploy --config <object> --tag <tag>"],
  )
  deepEqual((driver.deployed->Array.length, object.deployed->Array.length), (1, 2))
  // The account's id is the configuration's, so a new one deploys each again.
  let env = [...credentials, ("DRIVER_ACCOUNT_ID", anotherAccount)]
  let (faked, _) = installed(~env, account, root)
  deepEqual(
    plain(faked)->Array.filter(l => l->String.startsWith("wrangler deploy --config")),
    [
      "wrangler deploy --config <driver> --tag <tag>",
      "wrangler deploy --config <object> --tag <tag>",
      "wrangler deploy --config <database> --tag <tag>",
    ],
  )
})

test("each configuration of the moment holds its databases' ids and the account's", () => {
  let root = fixture()
  let account = empty()
  let _ = installed(account, root)
  let configOf = name =>
    (account.workers->Dict.getUnsafe(name)).deployed
    ->Array.get(0)
    ->Option.flatMap(Install_world.parsed)
    ->Option.getOr(JSON.Null)
  let seen = name => {
    let config = configOf(name)
    let ids =
      config
      ->Install_world.member("d1_databases")
      ->JSON.Decode.array
      ->Option.getOr([])
      ->Array.map(db => (db->Install_world.text("binding"), db->Install_world.text("database_id")))
    let vars = config->Install_world.member("vars")
    (
      config->Install_world.text("name"),
      ids,
      vars->Install_world.text("ACCOUNT_ID"),
      vars->Install_world.text("DATABASE_ID"),
    )
  }
  let driver = (Some("DB"), Some("uuid-driver-0a1b2c3d"))
  let account = Some(accountId)
  deepEqual(seen(full("driver")), (Some(full("driver")), [driver], account, None))
  deepEqual(seen(full("object")), (Some(full("object")), [driver], account, None))
  deepEqual(
    seen(full("database")),
    (
      Some(full("database")),
      [driver, (Some("DATABASE"), Some("uuid-database-0a1b2c3d"))],
      account,
      Some("uuid-database-0a1b2c3d"),
    ),
  )
  let named = (name, key, field) =>
    configOf(full(name))
    ->Install_world.member(key)
    ->JSON.Decode.array
    ->Option.getOr([])
    ->Array.map(entry => entry->Install_world.text(field))
  deepEqual(named("driver", "d1_databases", "database_name"), [Some(full("driver"))])
  deepEqual(
    named("database", "d1_databases", "database_name"),
    [Some(full("driver")), Some(full("database"))],
  )
  deepEqual(named("object", "r2_buckets", "bucket_name"), [Some(full("objects"))])
  let varOf = (name, var) =>
    configOf(full(name))->Install_world.member("vars")->Install_world.text(var)
  deepEqual(
    ["driver", "object", "database"]->Array.map(name => varOf(name, "INSTALL_ID")),
    [Some(id), Some(id), Some(id)],
  )
  deepEqual(
    ["driver", "object", "database"]->Array.map(name => varOf(name, "KINDS")),
    [Some("function,object,database"), None, None],
  )
})

test("a secret is put only where its name is missing, on stdin and never in an argument", () => {
  let root = fixture()
  let account = empty()
  let (made, _) = installed(account, root)
  ok(!shows(made), ~message="a secret was in an argument or said")
  let driver = account.workers->Dict.getUnsafe(full("driver"))
  let object = account.workers->Dict.getUnsafe(full("object"))
  let database = account.workers->Dict.getUnsafe(full("database"))
  deepEqual(
    (driver.secrets, object.secrets, database.secrets),
    (
      dict{"API_TOKEN": "the-driver-token", "BINDING": hashed},
      dict{"BINDING": hashed},
      dict{"API_TOKEN": "the-database-token", "BINDING": hashed},
    ),
  )
  driver.secrets->Dict.delete("API_TOKEN")
  database.secrets->Dict.delete("API_TOKEN")
  let (faked, _) = installed(account, root)
  deepEqual(
    plain(faked)->Array.filter(l => l->String.includes("secret put")),
    [
      "wrangler secret put API_TOKEN --config <driver>",
      "wrangler secret put API_TOKEN --config <database>",
    ],
  )
  deepEqual(database.secrets->Dict.get("API_TOKEN"), Some("the-database-token"))
  ok(!shows(faked))
})

test("with nothing on stdin BINDING is passed over and said so", () => {
  let root = fixture()
  let account = empty()
  let (faked, result) = installed(~stdin=" \n", account, root)
  deepEqual(result, Ok())
  deepEqual(
    plain(faked)->Array.filter(l => l->String.includes("secret put")),
    [
      "wrangler secret put API_TOKEN --config <driver>",
      "wrangler secret put API_TOKEN --config <database>",
    ],
  )
  ok(faked.said->Array.includes("BINDING of driver-0a1b2c3d passed over, nothing on stdin"))
  ok(faked.said->Array.includes("BINDING of object-0a1b2c3d passed over, nothing on stdin"))
  ok(faked.said->Array.includes("BINDING of database-0a1b2c3d passed over, nothing on stdin"))
})

test("BINDING is keys' own BLAKE3 of the token's secret, in lowercase hex", () => {
  let own = Host.fromBytes(Keys.Hash.plain(secret))->Host.encoded("hex")
  deepEqual((Install.bindingHash(token), own), (Ok(hashed), hashed))
})

test("a token not of a binding's form is refused before anything runs", () => {
  let root = fixture()
  [
    "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
    "07.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
    "7.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh",
    "7.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh9",
    "7.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
  ]->Array.forEach(stdin => {
    let faked = make(~stdin, ~answer=_ => Ok(""))
    ok(Install.install(faked.world, ~dry=false, ~root)->Result.isError, ~message=stdin)
    deepEqual(faked.ran, [])
  })
})

test("each Worker is built in its own directory before it is bundled", () => {
  let root = fixture()
  let (faked, result) = installed(empty(), root)
  deepEqual(result, Ok())
  let lines = plain(faked)
  let at = line => lines->Array.indexOf(line)
  ["driver", "object", "database"]->Array.forEach(name => {
    let built = at(`rescript build in <${name}>`)
    ok(
      built >= 0 && built < at(`wrangler deploy --dry-run --outdir <out> --config <${name}>`),
      ~message=lines->Array.join("\n"),
    )
  })
})

test("DRIVER_API_TOKEN and DATABASE_API_TOKEN are in no command's environment", () => {
  let root = fixture()
  let (faked, result) = installed(empty(), root)
  deepEqual(result, Ok())
  ok(faked.ran->Array.length > 0)
  faked.ran->Array.forEach(command => {
    deepEqual(command.env->Dict.get("DRIVER_API_TOKEN"), None, ~message=line(command))
    deepEqual(command.env->Dict.get("DATABASE_API_TOKEN"), None, ~message=line(command))
    let values = command.env->Dict.valuesToArray
    ok(
      !(values->Array.includes("the-driver-token") || values->Array.includes("the-database-token")),
      ~message=line(command),
    )
    let wrangler =
      Host.basename(command.program) == "wrangler" && !(command.args->Array.includes("--dry-run"))
    deepEqual(
      (
        command.env->Dict.get("CLOUDFLARE_API_TOKEN"),
        command.env->Dict.get("CLOUDFLARE_ACCOUNT_ID"),
      ),
      wrangler ? (Some("the-install-token"), Some(accountId)) : (None, None),
      ~message=line(command),
    )
  })
  deepEqual(faked.world.env->Dict.get("DRIVER_API_TOKEN"), Some("the-driver-token"))
  deepEqual(faked.world.env->Dict.get("DATABASE_API_TOKEN"), Some("the-database-token"))
})

/** An install whose commands are answered by the account, the one `failing` names failed. */
let failedAt = (root, failing) => {
  let account = empty()
  let faked = make(~answer=command =>
    line(command)->String.includes(failing)
      ? Error(`${failing} failed`)
      : answered(account, command)
  )
  (faked, Install.install(faked.world, ~dry=false, ~root))
}

test("a step failing after a configuration of the moment is written leaves it removed", () => {
  let root = fixture()
  ["d1 migrations apply", "deploy --dry-run", "secret put BINDING"]->Array.forEach(failing => {
    let (faked, result) = failedAt(root, failing)
    deepEqual(result, Error(`${failing} failed`))
    ok(moments(root)->Array.every(path => !named(path)), ~message=failing)
    ok(faked.scratched->Array.every(path => !Host.existsSync(path)), ~message=failing)
  })
})

test("a configuration that cannot be read or written is answered, and nothing is left", () => {
  let root = fixture()
  Host.rmSync(
    Host.join([root, "cloudflare", "object", "wrangler.json"]),
    {recursive: false, force: true},
  )
  let (faked, result) = installed(empty(), root)
  ok(result->Result.isError && faked.scratched != [])
  ok(moments(root)->Array.every(path => !named(path)))
  ok(faked.scratched->Array.every(path => !Host.existsSync(path)))
  // A configuration of the moment linked into no directory cannot be written.
  let root = fixture()
  let object = Host.join([root, "cloudflare", "object", Install_world.moment])
  symlinkSync(Host.join([root, "nowhere", Install_world.moment]), object)
  let (faked, result) = installed(empty(), root)
  ok(result->Result.isError && faked.scratched != [])
  ok(moments(root)->Array.every(path => !named(path)))
  ok(faked.scratched->Array.every(path => !Host.existsSync(path)))
})

test("the databases and the bucket are placed by DRIVER_LOCATION, or by Cloudflare", () => {
  let creates = faked =>
    plain(faked)->Array.filter(l =>
      l->String.includes(" create ") && l->String.startsWith("wrangler")
    )
  let placed = [...credentials, ("DRIVER_LOCATION", "weur")]
  let (faked, result) = installed(~env=placed, empty(), fixture())
  deepEqual(result, Ok())
  deepEqual(
    creates(faked),
    [
      "wrangler d1 create driver-0a1b2c3d --location weur",
      "wrangler d1 create database-0a1b2c3d --location weur",
      "wrangler r2 bucket create objects-0a1b2c3d --location weur",
    ],
  )
  let (faked, result) = installed(empty(), fixture())
  deepEqual(result, Ok())
  deepEqual(
    creates(faked),
    [
      "wrangler d1 create driver-0a1b2c3d",
      "wrangler d1 create database-0a1b2c3d",
      "wrangler r2 bucket create objects-0a1b2c3d",
    ],
  )
  let dry = env => {
    let faked = make(~env, ~answer=command => Error(`ran ${line(command)}`))
    deepEqual(Install.install(faked.world, ~dry=true, ~root=fixture()), Ok())
    faked.said
  }
  let said = dry(placed)
  ok(said->Array.includes("the databases and the bucket placed by the hint weur, DRIVER_LOCATION"))
  let includes = text => said->Array.some(l => l->String.includes(text))
  ok(includes("wrangler d1 create driver-<install id> --location weur"))
  ok(includes("wrangler d1 create database-<install id> --location weur"))
  ok(includes("wrangler r2 bucket create objects-<install id> --location weur"))
  let said = dry(credentials)
  ok(said->Array.includes("no DRIVER_LOCATION, so Cloudflare places the databases and the bucket"))
  ok(said->Array.every(l => !(l->String.includes("--location"))), ~message=said->Array.join("\n"))
})

after(() => fixtures->Array.forEach(root => Host.rmSync(root, {recursive: true, force: true})))
