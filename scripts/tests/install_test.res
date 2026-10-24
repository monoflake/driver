/***
 * `install` against an account faked as wrangler shows it, its plan dry, its first run making each
 * part in order and a second changing nothing.
 */
open Asserted

/** What a Worker on the faked account holds, its versions with their tags and its secrets. */
type held = {
  mutable versions: array<(option<string>, string)>,
  secrets: Dict.t<string>,
  mutable bundle: string,
  mutable deployed: array<string>,
}

/** What the account holds, as wrangler's commands read and write it. */
type account = {
  mutable databases: array<string>,
  mutable buckets: array<string>,
  workers: Dict.t<held>,
}

let empty = () => {
  databases: [],
  buckets: [],
  workers: dict{
    "driver": {versions: [], secrets: dict{}, bundle: "the driver's bundle", deployed: []},
    "object": {versions: [], secrets: dict{}, bundle: "the object's bundle", deployed: []},
  },
}

/** The Worker a configuration of the moment names, read from the file while it is there. */
let heldBy = (account, config) =>
  switch Host.existsSync(config) {
  | false => None
  | true =>
    Install.parsed(Host.readFileSync(config))
    ->Option.flatMap(json => json->Install.text("name"))
    ->Option.flatMap(name => account.workers->Dict.get(name))
  }

let versionsOf = held =>
  JSON.stringify(
    JSON.Array(
      held.versions->Array.mapWithIndex(((tag, trigger), i) => {
        let annotations = dict{"workers/triggered_by": JSON.String(trigger)}
        tag->Option.forEach(t => annotations->Dict.set("workers/tag", JSON.String(t)))
        JSON.Object(
          dict{"id": JSON.String(`v${Int.toString(i)}`), "annotations": JSON.Object(annotations)},
        )
      }),
    ),
  )

let line = (command: Install.command) =>
  [Host.basename(command.program), ...command.args]->Array.join(" ")

let answered = (account, command: Install.command) => {
  let worker = config =>
    switch heldBy(account, config) {
    | Some(held) => Ok(held)
    | None => Error(`no configuration of the moment at ${config}`)
    }
  let missing = Error("Worker not found")
  switch (Host.basename(command.program), List.fromArray(command.args)) {
  | ("wrangler", list{"d1", "list", "--json"}) =>
    Ok(
      JSON.stringify(
        JSON.Array(
          account.databases->Array.map(name => JSON.Object(
            dict{"name": JSON.String(name), "uuid": JSON.String(`uuid-${name}`)},
          )),
        ),
      ),
    )
  | ("wrangler", list{"d1", "create", name, "--location", "wnam"}) =>
    account.databases->Array.push(name)
    Ok("")
  | ("wrangler", list{"d1", "migrations", "apply", "driver", "--remote", "--config", config}) =>
    worker(config)->Result.map(_ => "")
  | ("wrangler", list{"r2", "bucket", "list"}) =>
    Ok(
      account.buckets
      ->Array.map(name => `name:           ${name}\ncreation_date:  2026-10-23T00:00:00.000Z`)
      ->Array.join("\n\n"),
    )
  | ("wrangler", list{"r2", "bucket", "create", name, "--location", "wnam"}) =>
    account.buckets->Array.push(name)
    Ok("")
  | ("wrangler", list{"deploy", "--dry-run", "--outdir", out, "--config", config}) =>
    worker(config)->Result.map(held => {
      mkdirSync(out, {recursive: true})
      Host.writeFileSync(Host.join([out, "worker.res.js"]), held.bundle)
      ""
    })
  | ("wrangler", list{"versions", "list", "--json", "--config", config}) =>
    worker(config)->Result.flatMap(held => held.versions == [] ? missing : Ok(versionsOf(held)))
  | ("wrangler", list{"deploy", "--config", config, "--tag", tag}) =>
    worker(config)->Result.map(held => {
      held.versions->Array.push((Some(tag), "upload"))
      held.deployed->Array.push(Host.readFileSync(config))
      ""
    })
  | ("wrangler", list{"secret", "list", "--config", config}) =>
    worker(config)->Result.flatMap(held =>
      held.versions == []
        ? missing
        : Ok(
            JSON.stringify(
              JSON.Array(
                held.secrets
                ->Dict.keysToArray
                ->Array.map(name => JSON.Object(
                  dict{"name": JSON.String(name), "type": JSON.String("secret_text")},
                )),
              ),
            ),
          )
    )
  | ("wrangler", list{"secret", "put", name, "--config", config}) =>
    worker(config)->Result.flatMap(held =>
      // A put before the Worker exists would make an empty one.
      if held.versions == [] {
        Error("an empty Worker made")
      } else {
        held.secrets->Dict.set(name, command.input->Option.getOr(""))
        held.versions->Array.push((None, "secret"))
        Ok("")
      }
    )
  | _ => Error(`not expected, ${line(command)}`)
  }
}

/** A root of its own holding the two Workers' configurations as the repository holds them. */
let fixtures = []
let fixture = () => {
  let root = Host.mkdtempSync(Host.join([Host.tmpdir(), "install-root-"]))
  fixtures->Array.push(root)
  mkdirSync(Host.join([root, "cloudflare", "object"]), {recursive: true})
  ["cloudflare", "cloudflare/object"]->Array.forEach(dir =>
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

let credentials = [
  ("CLOUDFLARE_API_TOKEN", "the-author-token"),
  ("CLOUDFLARE_ACCOUNT_ID", "the-account"),
  ("DRIVER_API_TOKEN", "the-driver-token"),
]

/** Every value no argument and no line said may hold. */
let secrets = ["the-author-token", "the-driver-token", token, hashed]

type faked = {
  world: Install.world,
  ran: array<Install.command>,
  said: array<string>,
  scratched: array<string>,
}

let make = (~env=credentials, ~stdin=token, ~answer) => {
  let ran = []
  let said = []
  let scratched = []
  let world: Install.world = {
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
  }
  {world, ran, said, scratched}
}

/** Each line run with the paths a run makes written as names. */
let plain = faked =>
  faked.ran->Array.map(command => {
    let words = line(command)->String.split(" ")
    words
    ->Array.mapWithIndex((word, i) =>
      if word->String.endsWith("/cloudflare/wrangler.install.json") {
        "<driver>"
      } else if word->String.endsWith("/object/wrangler.install.json") {
        "<object>"
      } else if word->String.includes("install-scratch-") {
        "<out>"
      } else if i > 0 && words->Array.get(i - 1) == Some("--tag") {
        "<tag>"
      } else {
        word
      }
    )
    ->Array.join(" ")
  })

/** Whether any argument run or any line said holds a secret. */
let shows = faked =>
  secrets->Array.some(s =>
    faked.ran->Array.some(c => c.args->Array.some(a => a->String.includes(s))) ||
      faked.said->Array.some(l => l->String.includes(s))
  )

let installed = (~env=?, ~stdin=?, account, root) => {
  let faked = make(~env?, ~stdin?, ~answer=command => answered(account, command))
  let result = Install.install(faked.world, ~dry=false, ~root)
  (faked, result)
}

let first = [
  "wrangler d1 list --json",
  "wrangler d1 create driver --location wnam",
  "wrangler d1 list --json",
  "wrangler d1 migrations apply driver --remote --config <driver>",
  "wrangler r2 bucket list",
  "wrangler r2 bucket create objects --location wnam",
  "wrangler deploy --dry-run --outdir <out> --config <driver>",
  "wrangler versions list --json --config <driver>",
  "wrangler deploy --config <driver> --tag <tag>",
  "wrangler secret list --config <driver>",
  "wrangler secret put API_TOKEN --config <driver>",
  "wrangler secret put BINDING --config <driver>",
  "wrangler deploy --dry-run --outdir <out> --config <object>",
  "wrangler versions list --json --config <object>",
  "wrangler deploy --config <object> --tag <tag>",
  "wrangler secret list --config <object>",
  "wrangler secret put BINDING --config <object>",
]

let again = [
  "wrangler d1 list --json",
  "wrangler d1 migrations apply driver --remote --config <driver>",
  "wrangler r2 bucket list",
  "wrangler deploy --dry-run --outdir <out> --config <driver>",
  "wrangler versions list --json --config <driver>",
  "wrangler secret list --config <driver>",
  "wrangler deploy --dry-run --outdir <out> --config <object>",
  "wrangler versions list --json --config <object>",
  "wrangler secret list --config <object>",
]

let moments = root => [
  Host.join([root, "cloudflare", Install.moment]),
  Host.join([root, "cloudflare", "object", Install.moment]),
]

test("a dry run runs nothing, writes nothing and shows no secret", () => {
  let root = fixture()
  let faked = make(~answer=command => Error(`ran ${line(command)}`))
  deepEqual(Install.install(faked.world, ~dry=true, ~root), Ok())
  deepEqual((faked.ran, faked.scratched), ([], []))
  ok(!shows(faked), ~message="a secret was said")
  ok(moments(root)->Array.every(path => !Host.existsSync(path)))
  ok(
    [
      "wrangler d1 create driver --location wnam",
      "wrangler d1 migrations apply driver --remote",
      "wrangler r2 bucket create objects --location wnam",
      "wrangler deploy --config",
      "wrangler secret put API_TOKEN",
      "wrangler secret put BINDING",
    ]->Array.every(said => faked.said->Array.some(l => l->String.includes(said))),
    ~message=faked.said->Array.join("\n"),
  )
})

test("a missing input is refused by its name before anything runs", () => {
  let root = fixture()
  let env = [("CLOUDFLARE_API_TOKEN", "the-author-token"), ("CLOUDFLARE_ACCOUNT_ID", "")]
  [false, true]->Array.forEach(dry => {
    let faked = make(~env, ~answer=_ => Ok(""))
    switch Install.install(faked.world, ~dry, ~root) {
    | Ok() => ok(false, ~message="it installed")
    | Error(why) =>
      ok(
        why->String.includes("CLOUDFLARE_ACCOUNT_ID, DRIVER_API_TOKEN") &&
          !(why->String.includes("CLOUDFLARE_API_TOKEN")),
        ~message=why,
      )
    }
    deepEqual(faked.ran, [])
  })
})

test("a first install makes each part in order, and a second changes nothing", () => {
  let root = fixture()
  let account = empty()
  let (made, result) = installed(account, root)
  deepEqual(result, Ok())
  deepEqual(plain(made), first)
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
  account.databases = ["other", "driver"]
  account.buckets = ["objects"]
  let (faked, result) = installed(account, root)
  deepEqual(result, Ok())
  let lines = plain(faked)
  ok(lines->Array.every(l => !(l->String.includes(" create "))), ~message=lines->Array.join("\n"))
  ok(faked.said->Array.includes("the database driver is there already"))
  ok(faked.said->Array.includes("the bucket objects is there already"))
})

test("a Worker is deployed again only where its bundle or its configuration changed", () => {
  let root = fixture()
  let account = empty()
  let _ = installed(account, root)
  let object = account.workers->Dict.getUnsafe("object")
  let driver = account.workers->Dict.getUnsafe("driver")
  object.bundle = "the object's bundle, changed"
  let (faked, result) = installed(account, root)
  deepEqual(result, Ok())
  deepEqual(
    plain(faked)->Array.filter(l => l->String.startsWith("wrangler deploy --config")),
    ["wrangler deploy --config <object> --tag <tag>"],
  )
  deepEqual((driver.deployed->Array.length, object.deployed->Array.length), (1, 2))
  // The account's id is the configuration's, so a new one deploys both again.
  let env = [...credentials, ("CLOUDFLARE_ACCOUNT_ID", "another-account")]
  let (faked, _) = installed(~env, account, root)
  deepEqual(
    plain(faked)->Array.filter(l => l->String.startsWith("wrangler deploy --config")),
    [
      "wrangler deploy --config <driver> --tag <tag>",
      "wrangler deploy --config <object> --tag <tag>",
    ],
  )
})

test("each configuration of the moment holds the database's id and the account's", () => {
  let root = fixture()
  let account = empty()
  let _ = installed(account, root)
  ["driver", "object"]->Array.forEach(name => {
    let config =
      (account.workers->Dict.getUnsafe(name)).deployed
      ->Array.get(0)
      ->Option.flatMap(Install.parsed)
      ->Option.getOr(JSON.Null)
    let database =
      config
      ->Install.member("d1_databases")
      ->JSON.Decode.array
      ->Option.flatMap(all => all->Array.get(0))
      ->Option.getOr(JSON.Null)
    deepEqual(
      (
        config->Install.text("name"),
        database->Install.text("database_id"),
        config->Install.member("vars")->Install.text("ACCOUNT_ID"),
      ),
      (Some(name), Some("uuid-driver"), Some("the-account")),
    )
  })
})

test("a secret is put only where its name is missing, on stdin and never in an argument", () => {
  let root = fixture()
  let account = empty()
  let (made, _) = installed(account, root)
  ok(!shows(made), ~message="a secret was in an argument or said")
  let driver = account.workers->Dict.getUnsafe("driver")
  let object = account.workers->Dict.getUnsafe("object")
  deepEqual(
    (driver.secrets, object.secrets),
    (dict{"API_TOKEN": "the-driver-token", "BINDING": hashed}, dict{"BINDING": hashed}),
  )
  driver.secrets->Dict.delete("API_TOKEN")
  let (faked, _) = installed(account, root)
  deepEqual(
    plain(faked)->Array.filter(l => l->String.includes("secret put")),
    ["wrangler secret put API_TOKEN --config <driver>"],
  )
  ok(!shows(faked))
})

test("with nothing on stdin BINDING is passed over and said so", () => {
  let root = fixture()
  let account = empty()
  let (faked, result) = installed(~stdin=" \n", account, root)
  deepEqual(result, Ok())
  deepEqual(
    plain(faked)->Array.filter(l => l->String.includes("secret put")),
    ["wrangler secret put API_TOKEN --config <driver>"],
  )
  ok(faked.said->Array.includes("BINDING of driver passed over, nothing on stdin"))
  ok(faked.said->Array.includes("BINDING of object passed over, nothing on stdin"))
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

after(() => fixtures->Array.forEach(root => Host.rmSync(root, {recursive: true, force: true})))
