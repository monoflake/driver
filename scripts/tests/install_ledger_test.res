/***
 * How the install id is read from the account, the D1s surveyed for their markers, an id drawn
 * or reused, and every read failing stopping install before anything is made.
 */
open Asserted
open Faked_account
open Faked_install

test("the install id is drawn where no driver-<8 hex> is listed, and reused where one is", () => {
  let account = empty()
  account.databases = ["driver", "driver-0A1B2C3D", "driver-0a1b2c3d-old", "objects-4e5f6a7b"]
  let (drawn, result) = installed(account, fixture())
  deepEqual(result, Ok())
  ok(
    drawn.said->Array.includes(
      "no driver's D1 holding its marker on the account, so the install id 0a1b2c3d is drawn",
    ),
  )
  ok(account.databases->Array.includes(full("driver")))
  // A second install draws another, which is never taken while one is listed.
  let (reused, result) = installed(~drawn="4e5f6a7b", account, fixture())
  deepEqual(result, Ok())
  ok(
    reused.said->Array.includes(
      "the install id 0a1b2c3d is reused, the account holding driver-0a1b2c3d",
    ),
  )
  ok(plain(reused)->Array.every(l => !(l->String.includes("4e5f6a7b"))))
})

test("more than one driver-<8 hex> is refused by name, and nothing is made", () => {
  let account = empty()
  account.databases = ["other"]
  account->holding("driver-0a1b2c3d", ~mark=id)
  account->holding("driver-4e5f6a7b", ~mark="4e5f6a7b")
  let (faked, result) = installed(account, fixture())
  deepEqual(
    result,
    Error(
      [
        "the account holds more than one driver's D1, driver-0a1b2c3d, driver-4e5f6a7b, ",
        "so none is chosen",
      ]->Array.join(""),
    ),
  )
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

test("a drawn id not of the id form is refused before anything is made", () => {
  let (faked, result) = installed(~drawn="0A1B2C3D", empty(), fixture())
  deepEqual(result, Error("an install id drawn is not 8 lowercase hex digits, 0A1B2C3D"))
  deepEqual(plain(faked), ["wrangler d1 list --json", workersListed])
})

test("a driver-<8 hex> holding no marker is foreign, passed over and never written", () => {
  let root = fixture()
  let account = empty()

  // One holds a table of its own and no marker, another a marker naming another install.
  account.databases = ["driver-20261024"]
  account.own->Dict.set("driver-20261024", ["notes"])
  account->holding("driver-4e5f6a7b", ~mark="0a1b2c3d")
  let foreign = ["driver-20261024", "driver-4e5f6a7b"]
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
  let (faked, result) = installed(~draws=["5c6d7e8f"], account, root)
  deepEqual(result, Ok())
  let lines = plain(faked)
  deepEqual(
    foreign->Array.map(name => lines->Array.filter(l => l->String.includes(name))),
    [
      [tablesRead("driver-20261024")],
      [tablesRead("driver-4e5f6a7b"), markerRead("driver-4e5f6a7b")],
    ],
  )
  ok(
    faked.said->Array.includes(
      "no driver's D1 holding its marker on the account, so the install id 5c6d7e8f is drawn",
    ),
  )
  deepEqual(
    (account.marks->Dict.get("driver-20261024"), account.marks->Dict.get("driver-4e5f6a7b")),
    (None, Some("0a1b2c3d")),
  )
  deepEqual(account.marks->Dict.get("driver-5c6d7e8f"), Some("5c6d7e8f"))
  // The next install reuses the one marked, the foreign ones still passed over.
  let (again, result) = installed(~draws=["6e7f8a9b"], account, root)
  deepEqual(result, Ok())
  ok(
    again.said->Array.includes(
      "the install id 5c6d7e8f is reused, the account holding driver-5c6d7e8f",
    ),
  )
})

test("a driver-<8 hex> holding no table is said as possibly interrupted, and never touched", () => {
  let root = fixture()
  let account = empty()
  account.databases = ["driver-4e5f6a7b"]
  let said =
    [
      "driver-4e5f6a7b holds no tables, possibly an interrupted install of this driver;",
      " delete it by hand if it is yours",
    ]->Array.join("")
  let (dry, result) = dryOn(account, root)
  deepEqual(result, Ok())
  ok(dry.said->Array.includes(said), ~message=dry.said->Array.join("\n"))
  ok(dry.said->Array.some(l => l->String.includes("so a new install id would be drawn")))
  let (faked, result) = installed(~draws=["4e5f6a7b", "5c6d7e8f"], account, root)
  deepEqual(result, Ok())
  ok(faked.said->Array.includes(said), ~message=faked.said->Array.join("\n"))
  deepEqual(
    plain(faked)->Array.filter(l => l->String.includes("driver-4e5f6a7b")),
    [tablesRead("driver-4e5f6a7b")],
  )
  deepEqual(
    (account.marks->Dict.get("driver-4e5f6a7b"), account.migrated),
    (None, ["driver-5c6d7e8f"]),
  )
  deepEqual(account.marks->Dict.get("driver-5c6d7e8f"), Some("5c6d7e8f"))
})

test("the marker is written right after the D1 is made, before its first migration", () => {
  let account = empty()
  let (faked, result) = installed(account, fixture())
  deepEqual(result, Ok())
  let lines = plain(faked)
  let at = line => lines->Array.indexOf(line)
  let created = at("wrangler d1 create driver-0a1b2c3d")
  deepEqual(
    (at(markerWritten("driver-0a1b2c3d")) - created, created >= 0),
    (1, true),
    ~message=lines->Array.join("\n"),
  )
  ok(
    at(markerWritten("driver-0a1b2c3d")) <
    at("wrangler d1 migrations apply driver-0a1b2c3d --remote --config <driver>"),
  )
  deepEqual(account.marks->Dict.get(full("driver")), Some(id))
  // A reused D1 is never marked again, and one listed though its id was drawn is refused.
  let (again, _) = installed(account, fixture())
  ok(plain(again)->Array.every(l => l != markerWritten("driver-0a1b2c3d")))
  let raced = empty()
  let lists = ref(0)
  let faked = make(~answer=command =>
    if line(command) == "wrangler d1 list --json" {
      lists := lists.contents + 1

      // The second list, the driver's D1's own, sees one made since the survey.
      if lists.contents == 2 {
        raced.databases->Array.push(full("driver"))
      }
      answered(raced, command)
    } else {
      answered(raced, command)
    }
  )
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("driver-0a1b2c3d is listed already, though its install id was drawn as free"),
  )
  deepEqual(raced.marks, dict{})
})

test("a drawn id is drawn again while a D1's or a Worker's name ends in it", () => {
  let account = empty()
  account.databases = ["objects-0a1b2c3d"]
  account->running("app-7-4e5f6a7b")
  let (faked, result) = installed(~draws=["0a1b2c3d", "4e5f6a7b", "5c6d7e8f"], account, fixture())
  deepEqual(result, Ok())
  let taken = id => `the install id ${id} drawn ends a name the account holds, so another is drawn`
  ok(faked.said->Array.includes(taken("0a1b2c3d")), ~message=faked.said->Array.join("\n"))
  ok(faked.said->Array.includes(taken("4e5f6a7b")))
  ok(account.databases->Array.includes("driver-5c6d7e8f"))
  deepEqual(plain(faked)->Array.filter(l => l == workersListed)->Array.length, 1)
  // An account where every draw is taken is refused, nothing made.
  let account = empty()
  account.databases = ["objects-0a1b2c3d"]
  let (faked, result) = installed(account, fixture())
  deepEqual(result, Error("no install id drawn was free in 8 draws"))
  unchanged(faked)
})

test("a marker read failing otherwise than for want of a marker stops install, nothing run", () => {
  let account = empty()
  account->holding("driver-0a1b2c3d", ~mark=id)
  let answer = command =>
    line(command) == markerRead("driver-0a1b2c3d")
      ? Error("Authentication error [code: 10000]")
      : answered(account, command)
  let faked = make(~answer)
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("the marker of driver-0a1b2c3d is not known, Authentication error [code: 10000]"),
  )
  unchanged(faked)
  let faked = make(~answer=command =>
    line(command) == markerRead("driver-0a1b2c3d") ? Ok("not JSON") : answered(account, command)
  )
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("the marker of driver-0a1b2c3d is not known, d1 execute printed no JSON array"),
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
      Host.basename(command.program) == "curl" ? Ok(body) : answered(account, command)
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
  account.databases = ["driver-4e5f6a7b"]
  let faked = make(~answer=command =>
    line(command) == tablesRead("driver-4e5f6a7b")
      ? Error("Authentication error [code: 10000]")
      : answered(account, command)
  )
  deepEqual(
    Install.install(faked.world, ~dry=false, ~root=fixture()),
    Error("the marker of driver-4e5f6a7b is not known, Authentication error [code: 10000]"),
  )
  unchanged(faked)
})

after(() => fixtures->Array.forEach(root => Host.rmSync(root, {recursive: true, force: true})))
