/***
 * How the install id is read from the account, the D1s surveyed for their markers, each name drawn
 * or reused from the records, and every read failing stopping install before anything is made.
 */
open Asserted
open Faked_account
open Faked_install

test(
  "the install id is drawn where no D1 named by 8 hex is marked, and reused where one is",
  () => {
    let account = empty()
    account.databases = ["driver", "0A1B2C3D", "driver-0a1b2c3d", "objects"]
    let (drawn, result) = installed(account, fixture())
    deepEqual(result, Ok())
    ok(drawn.said->Array.includes("the name 0a1b2c3d is drawn for state"))
    ok(account.databases->Array.includes(id))
    // A second install reuses it, and draws nothing, every part recorded.
    let (reused, result) = installed(~draws=["6e7f8a9b"], account, fixture())
    deepEqual(result, Ok())
    ok(
      reused.said->Array.includes(
        "the install id 0a1b2c3d is reused, the account holding the D1 0a1b2c3d",
      ),
    )
    ok(plain(reused)->Array.every(l => !(l->String.includes("6e7f8a9b"))))
  },
)

test("more than one marked D1 is refused by name, and nothing is made", () => {
  let account = empty()
  account.databases = ["other"]
  account->holding("0a1b2c3d", ~mark=id)
  account->holding("4e5f6a7b", ~mark="4e5f6a7b")
  let (faked, result) = installed(account, fixture())
  deepEqual(
    result,
    Error("the account holds more than one driver's D1, 0a1b2c3d, 4e5f6a7b, so none is chosen"),
  )
  deepEqual(
    plain(faked),
    [
      "wrangler d1 list --json",
      tablesRead("0a1b2c3d"),
      markerRead("0a1b2c3d"),
      tablesRead("4e5f6a7b"),
      markerRead("4e5f6a7b"),
    ],
  )
})

test("a drawn id not of the id form is refused before anything is made", () => {
  let (faked, result) = installed(~draws=[], ~drawn="0A1B2C3D", empty(), fixture())
  deepEqual(result, Error("an install id drawn is not 8 lowercase hex digits, 0A1B2C3D"))
  deepEqual(plain(faked), ["wrangler d1 list --json", workersListed, "wrangler r2 bucket list"])
})

/** Names drawn past those the faked account holds, each part's in turn. */
let elsewhere = ["5c6d7e8f", "1b2c3d4e", "2c3d4e5f", "3d4e5f6a", "6e7f8a9b", "5f6a7b8c"]

test("a D1 named by 8 hex holding no marker of its own is foreign, never written", () => {
  let root = fixture()
  let account = empty()

  // One holds a table of its own and no marker, another a marker naming another D1.
  account.databases = ["20261024"]
  account.own->Dict.set("20261024", ["notes"])
  account->holding("4e5f6a7b", ~mark="0a1b2c3d")
  let foreign = ["20261024", "4e5f6a7b"]
  let (dry, result) = dryOn(account, root)
  deepEqual(result, Ok())
  foreign->Array.forEach(name =>
    ok(
      dry.said->Array.includes(
        `${name} holds no driver's marker, so it is passed over and never written`,
      ),
      ~message=dry.said->Array.join("\n"),
    )
  )
  ok(dry.said->Array.some(l => l->String.includes("so a new install id would be drawn")))
  let (faked, result) = installed(~draws=elsewhere, account, root)
  deepEqual(result, Ok())
  let lines = plain(faked)
  deepEqual(
    foreign->Array.map(name => lines->Array.filter(l => l->String.includes(name))),
    [[tablesRead("20261024")], [tablesRead("4e5f6a7b"), markerRead("4e5f6a7b")]],
  )
  ok(faked.said->Array.includes("the name 5c6d7e8f is drawn for state"))
  deepEqual(
    (account.marks->Dict.get("20261024"), account.marks->Dict.get("4e5f6a7b")),
    (None, Some("0a1b2c3d")),
  )
  deepEqual(account.marks->Dict.get("5c6d7e8f"), Some("5c6d7e8f"))
  // The next install reuses the one marked, the foreign ones still passed over.
  let (again, result) = installed(~draws=["7f8a9b0c"], account, root)
  deepEqual(result, Ok())
  ok(
    again.said->Array.includes(
      "the install id 5c6d7e8f is reused, the account holding the D1 5c6d7e8f",
    ),
  )
})

test("a D1 named by 8 hex holding no table is said as possibly interrupted, never touched", () => {
  let root = fixture()
  let account = empty()
  account.databases = ["4e5f6a7b"]
  let said =
    [
      "4e5f6a7b holds no tables, possibly an interrupted install of this driver;",
      " delete it by hand if it is yours",
    ]->Array.join("")
  let (dry, result) = dryOn(account, root)
  deepEqual(result, Ok())
  ok(dry.said->Array.includes(said), ~message=dry.said->Array.join("\n"))
  let (faked, result) = installed(~draws=elsewhere, account, root)
  deepEqual(result, Ok())
  ok(faked.said->Array.includes(said), ~message=faked.said->Array.join("\n"))
  deepEqual(
    plain(faked)->Array.filter(l => l->String.includes("4e5f6a7b")),
    [tablesRead("4e5f6a7b")],
  )
  deepEqual((account.marks->Dict.get("4e5f6a7b"), account.migrated), (None, ["5c6d7e8f"]))
  deepEqual(account.marks->Dict.get("5c6d7e8f"), Some("5c6d7e8f"))
})

test("the marker is written right after the D1 is made, and the records before any part", () => {
  let account = empty()
  let (faked, result) = installed(account, fixture())
  deepEqual(result, Ok())
  let lines = plain(faked)
  let at = line => lines->Array.indexOf(line)
  let created = at("wrangler d1 create 0a1b2c3d")
  deepEqual(
    (at(markerWritten("0a1b2c3d")) - created, created >= 0),
    (1, true),
    ~message=lines->Array.join("\n"),
  )
  let migrated = at("wrangler d1 migrations apply 0a1b2c3d --remote --config <driver>")
  ok(at(markerWritten("0a1b2c3d")) < migrated)
  // The records follow the migrations, which make their table, and precede every part.
  let records = at(recordsWritten("0a1b2c3d", drawnRecords))
  deepEqual(records - migrated, 1, ~message=lines->Array.join("\n"))
  ok(
    records < at("wrangler d1 create 5f6a7b8c") &&
      records < at("wrangler r2 bucket create 3d4e5f6a"),
  )
  // A reused D1 is never marked again, and one listed though its name was drawn is refused.
  let (again, _) = installed(account, fixture())
  ok(plain(again)->Array.every(l => l != markerWritten("0a1b2c3d")))
  let raced = empty()
  let lists = ref(0)
  let faked = make(~answer=command =>
    if line(command) == "wrangler d1 list --json" {
      lists := lists.contents + 1

      // The second list, the driver's D1's own, sees one made since the survey.
      if lists.contents == 2 {
        raced.databases->Array.push(id)
      }
      answered(raced, command)
    } else {
      answered(raced, command)
    }
  )
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("0a1b2c3d is listed already, though its name was drawn as free"),
  )
  deepEqual(raced.marks, dict{})
})

test("a drawn name is drawn again while a D1, a Worker or a bucket is so named", () => {
  let account = empty()
  account.databases = ["2c3d4e5f"]
  account.buckets = ["1b2c3d4e"]
  account->running("0a1b2c3d")
  let draws = [
    "0a1b2c3d",
    "1b2c3d4e",
    "2c3d4e5f",
    "9a8b7c6d",
    "3d4e5f6a",
    "4e5f6a7b",
    "5f6a7b8c",
    "6e7f8a9b",
    "7f8a9b0c",
  ]
  let (faked, result) = installed(~draws, account, fixture())
  deepEqual(result, Ok())
  let taken = id =>
    `the name ${id} drawn is the account's or the driver's already, so another is drawn`
  ["0a1b2c3d", "1b2c3d4e", "2c3d4e5f"]->Array.forEach(id =>
    ok(faked.said->Array.includes(taken(id)), ~message=faked.said->Array.join("\n"))
  )
  ok(account.databases->Array.includes("9a8b7c6d"))
  deepEqual(
    account.records->Dict.get("9a8b7c6d")->Option.map(r => r->Array.map(((n, _)) => n)),
    Some(["9a8b7c6d", "3d4e5f6a", "4e5f6a7b", "5f6a7b8c", "6e7f8a9b", "7f8a9b0c"]),
  )
  deepEqual(plain(faked)->Array.filter(l => l == workersListed)->Array.length, 1)
  // An account where every draw is taken is refused, nothing made.
  let account = empty()
  account->running("0a1b2c3d")
  let (faked, result) = installed(~draws=[], account, fixture())
  deepEqual(result, Error("no name drawn was free in 8 draws"))
  unchanged(faked)
})

test("a marked D1 made before the records were has its parts drawn and itself recorded", () => {
  let account = empty()
  account.databases = [id]
  account.marks->Dict.set(id, id)
  let (faked, result) = installed(
    ~draws=["1b2c3d4e"],
    ~env=[...credentials, ("DRIVER_KINDS", "function")],
    account,
    fixture(),
  )
  deepEqual(result, Ok())
  ok(plain(faked)->Array.every(l => l != recordsRead(id)), ~message="no table owned to read")
  deepEqual(account.records->Dict.get(id), Some([(id, "state"), ("1b2c3d4e", "driver")]))
})

test("the records failing to be read stop install, nothing run", () => {
  let account = empty()
  account->holding(id, ~mark=id)
  let faked = make(~answer=command =>
    line(command) == recordsRead(id)
      ? Error("Authentication error [code: 10000]")
      : answered(account, command)
  )
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("the records of 0a1b2c3d are not known, Authentication error [code: 10000]"),
  )
  unchanged(faked)
})

test("a marker read failing otherwise than for want of a marker stops install, nothing run", () => {
  let account = empty()
  account->holding("0a1b2c3d", ~mark=id)
  let answer = command =>
    line(command) == markerRead("0a1b2c3d")
      ? Error("Authentication error [code: 10000]")
      : answered(account, command)
  let faked = make(~answer)
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("the marker of 0a1b2c3d is not known, Authentication error [code: 10000]"),
  )
  unchanged(faked)
  let faked = make(~answer=command =>
    line(command) == markerRead("0a1b2c3d") ? Ok("not JSON") : answered(account, command)
  )
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("the marker of 0a1b2c3d is not known, d1 execute printed no JSON array"),
  )
  unchanged(faked)
})

test("a Workers list that cannot be read stops install before anything is made", () => {
  let account = empty()
  let faked = make(~answer=command =>
    line(command) == workersListed ? Ok("not JSON") : answered(account, command)
  )
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("the Workers list printed no result array, so the account's Workers are not known"),
  )
  unchanged(faked)
  let listing = faked.ran->Array.find(c => line(c) == workersListed)
  deepEqual(listing->Option.flatMap(c => c.input), Some("Authorization: Bearer the-install-token"))
})

test("curl is given -q first, so it reads no .curlrc", () => {
  let (faked, result) = installed(empty(), fixture())
  deepEqual(result, Ok())
  let listing =
    faked.ran->Array.find((c: Install_world.command) => Host.basename(c.program) == "curl")
  deepEqual(listing->Option.flatMap(c => c.args->Array.get(0)), Some("-q"))
})

test("a Workers list answered in pages, or not a success, stops install with nothing made", () => {
  let answer = (account, body) =>
    (command: Install_world.command) =>
      line(command) == workersListed ? Ok(body) : answered(account, command)
  let answers = [
    (
      `{"success":true,"result":[{"id":"app-7-4e5f6a7b"}],
        "result_info":{"page":1,"total_pages":2}}`,
      "came in pages and was not read whole",
    ),
    (
      `{"success":true,"result":[],"result_info":{"count":20,"total_count":21}}`,
      "came in pages and was not read whole",
    ),
    (
      `{"success":true,"result":[],"result_info":{"cursor":"6Ck1la0VxJ0djhidm1MdX2FyD"}}`,
      "came in pages and was not read whole",
    ),
    (
      `{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"result":null}`,
      "did not succeed",
    ),
  ]
  answers->Array.forEach(((body, why)) => {
    let account = empty()
    let faked = make(~answer=answer(account, body))
    deepEqual(
      Install.install(faked.world, ~dry=false, ~root=fixture()),
      Error(`the Workers list ${why}, so the account's Workers are not known`),
      ~message=body,
    )
    unchanged(faked)
  })
  // One page whole, as the documentation shows every answer, is read.
  let account = empty()
  let whole = `{"success":true,"result":[],"result_info":{"page":1,"total_pages":1}}`
  let faked = make(~answer=answer(account, whole))
  deepEqual(Install.install(faked.world, ~dry=false, ~root=fixture()), Ok())
})

test("a D1's tables read failing stops install, nothing run", () => {
  let account = empty()
  account.databases = ["4e5f6a7b"]
  let faked = make(~answer=command =>
    line(command) == tablesRead("4e5f6a7b")
      ? Error("Authentication error [code: 10000]")
      : answered(account, command)
  )
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("the marker of 4e5f6a7b is not known, Authentication error [code: 10000]"),
  )
  unchanged(faked)
})

/** What install says of a D1 or a Worker left over from the old naming. */
let leftOver = (what, name) =>
  `the ${what} ${name} is left over from the old naming; install never writes, deletes or`

test("a D1 of the old naming is said left over, never written, deleted or reused", () => {
  let account = empty()
  account->holding("driver-0a1b2c3d", ~mark="0a1b2c3d")
  let (faked, result) = installed(account, fixture())
  deepEqual(result, Ok())
  ok(
    faked.said->Array.includes(leftOver("D1", "driver-0a1b2c3d")),
    ~message=faked.said->Array.join("\n"),
  )
  deepEqual(plain(faked)->Array.filter(l => l->String.includes("driver-0a1b2c3d")), [])
  // A new state is made beside it, the old one never taken as the state.
  ok(faked.said->Array.includes("the name 0a1b2c3d is drawn for state"))
  ok(account.databases->Array.includes("driver-0a1b2c3d"))
  deepEqual(account.marks->Dict.get("0a1b2c3d"), Some("0a1b2c3d"))
})

test("a Worker of the old naming is said left over, never written or deleted", () => {
  let account = empty()
  account->running("driver-4e5f6a7b")
  let (faked, result) = installed(account, fixture())
  deepEqual(result, Ok())
  ok(
    faked.said->Array.includes(leftOver("Worker", "driver-4e5f6a7b")),
    ~message=faked.said->Array.join("\n"),
  )
  deepEqual(plain(faked)->Array.filter(l => l->String.includes("driver-4e5f6a7b")), [])
  ok(account.workers->Dict.get("driver-4e5f6a7b")->Option.isSome)
})

test("a dry run names each D1 and Worker of the old naming, and writes nothing", () => {
  let account = empty()
  account.databases = ["driver-0a1b2c3d", "driver"]
  account->running("driver-4e5f6a7b")
  account->running("driver-shop")
  let (faked, result) = dryOn(account, fixture())
  deepEqual(result, Ok())
  let said = faked.said
  ok(said->Array.includes(leftOver("D1", "driver-0a1b2c3d")), ~message=said->Array.join("\n"))
  ok(said->Array.includes(leftOver("Worker", "driver-4e5f6a7b")))
  ok(said->Array.every(l => !(l->String.includes(" driver ") || l->String.includes("driver-shop"))))
  unchanged(faked)
})

after(() => fixtures->Array.forEach(root => Host.rmSync(root, {recursive: true, force: true})))
