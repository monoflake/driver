/***
 * install binding the Worker `driver` once it is deployed, the control's base judged before
 * anything runs, both halves or neither, and the bind's answer reported, platform RFC 8j7b0.
 */
open Asserted
open Faked_account
open Faked_install

test("a base keeps its path, drops a trailing slash, and a call joins it by one slash", () => {
  let based = text => Install_bind.baseOf(text)
  deepEqual(based(base), Ok(base))
  deepEqual(based(`${base}/`), Ok(base))
  deepEqual(based("https://control.example.com"), Ok("https://control.example.com"))
  deepEqual(based("https://control.example.com/"), Ok("https://control.example.com"))
  deepEqual(
    based(`${base}/`)->Result.map(b =>
      Install_bind.callTo(b, ~interface="bindings", ~operation="bind")
    ),
    Ok(`${base}/bindings/bind`),
  )
})

test("a base not https, on no DNS host, a port, a user, a query or a fragment is refused", () => {
  [
    "http://control.example.com",
    "https://192.0.2.1",
    "https://[2001:db8::1]",
    "https://localhost",
    "https://control.local",
    "https://control.example.com:8443",
    "https://user@control.example.com",
    "https://control.example.com/v1?app=2",
    "https://control.example.com/?",
    "https://control.example.com/v1#app",
    "control.example.com",
  ]->Array.forEach(text => ok(Install_bind.baseOf(text)->Result.isError, ~message=text))
})

test("an origin is a base with no path, the Worker's own judged by 8j7b0's rule", () => {
  let origin = "https://1b2c3d4e.my-subdomain.workers.dev"
  deepEqual(Install_bind.originOf(origin), Ok(origin))
  [
    `${origin}/`,
    `${origin}/v1`,
    "http://1b2c3d4e.my-subdomain.workers.dev",
    "https://192.0.2.1",
  ]->Array.forEach(text => ok(Install_bind.originOf(text)->Result.isError, ~message=text))
})

let withBase = value =>
  [
    ...credentials->Array.filter(((name, _)) => name != "DRIVER_CONTROL_BASE"),
    ("DRIVER_CONTROL_BASE", value),
  ]

test("a malformed base is refused before anything runs", () => {
  let faked = make(~env=withBase("http://control.example.com"), ~answer=_ => Ok(""))
  let result = Install.install(faked.world, ~dry=false, ~root=fixture())
  ok(result->Result.isError)
  deepEqual(faked.ran, [])
})

test("half of a bind's inputs is refused before anything is deployed, naming the other", () => {
  let noBase = credentials->Array.filter(((name, _)) => name != "DRIVER_CONTROL_BASE")
  let tokenAlone = make(~env=noBase, ~answer=_ => Ok(""))
  deepEqual(
    Install.install(tokenAlone.world, ~dry=false, ~root=fixture()),
    Error("a token on stdin and no DRIVER_CONTROL_BASE, so the bind has half its inputs"),
  )
  deepEqual(tokenAlone.ran, [])
  let baseAlone = make(~stdin="", ~answer=_ => Ok(""))
  deepEqual(
    Install.install(baseAlone.world, ~dry=false, ~root=fixture()),
    Error("DRIVER_CONTROL_BASE and no token on stdin, so the bind has half its inputs"),
  )
  deepEqual(baseAlone.ran, [])
})

test("with neither half the bind is passed over and said so", () => {
  let account = empty()
  let env = credentials->Array.filter(((name, _)) => name != "DRIVER_CONTROL_BASE")
  let (faked, result) = installed(~env, ~stdin="", account, fixture())
  deepEqual(result, Ok())
  ok(
    faked.said->Array.includes(
      "no token on stdin and no DRIVER_CONTROL_BASE, so the bind is passed over",
    ),
  )
  deepEqual(account.binds, [])
  ok(plain(faked)->Array.every(l => l != subdomainRead))
})

test("the bind reports the Worker's origin by the token as a bearer, never shown", () => {
  let account = empty()
  let (faked, result) = installed(account, fixture())
  deepEqual(result, Ok())
  let body = Install_bind.bindBody(origin)
  deepEqual(account.binds, [(`${base}/bindings/bind`, `Authorization: Bearer ${token}`, body)])
  deepEqual(
    JSON.parseOrThrow(body),
    JSON.parseOrThrow(
      `{"interface": "bindings", "operation": "bind",
      "input": {"reach": {"name": "origin", "origin": "${origin}"}}}`,
    ),
  )
  ok(faked.said->Array.includes(`bound binding 7, its origin ${origin} recorded`))
  ok(!shows(faked), ~message="a secret was said or in an argument")
  // The bind comes after every Worker is deployed.
  let lines = plain(faked)
  ok(
    lines->Array.indexOf(bindLine) >
      lines->Array.indexOf("wrangler deploy --config <driver> --tag <tag>"),
  )
})

test("a bind the control refuses fails the install, naming its reason", () => {
  ["not_proven", "unreachable", "malformed", "invalid", "denied"]->Array.forEach(reason => {
    let account = empty()
    account.control = Some(
      `{"status": "error", "failure": "rejected", "reason": "${reason}",
      "message": "refused"}`,
    )
    let (faked, result) = installed(account, fixture())
    // A denial is answered in fixed words, the token most likely spent by a bind before.
    deepEqual(
      result,
      Error(
        reason == "denied"
          ? Install_bind.denied
          : `the control refused the bind, ${reason}: refused`,
      ),
    )
    ok(!shows(faked))
  })
})

test("a dry run prints the bind it would make, the token by its name alone", () => {
  let (faked, result) = dryOn(empty(), fixture())
  deepEqual(result, Ok())
  ok(
    faked.said->Array.some(l =>
      l->String.includes("would run curl") && l->String.includes(`${base}/bindings/bind`)
    ),
    ~message=faked.said->Array.join("\n"),
  )
  ok(faked.said->Array.some(l => l->String.includes("the token as BINDING by its name alone")))
  ok(!shows(faked))
  deepEqual(plain(faked)->Array.filter(l => l->String.includes("bindings/bind")), [])
})

test("a host ending in a dot is refused, a local one never passing by it", () => {
  [
    "https://localhost./",
    "https://x.local./",
    "https://control.example.com./v1",
  ]->Array.forEach(text => {
    ok(Install_bind.baseOf(text)->Result.isError, ~message=text)
    ok(Install_bind.originOf(text)->Result.isError, ~message=text)
  })
})

test("a denial says the token may be spent, the install complete and BINDING the new token", () => {
  let said = Install_bind.denied
  ok(said->String.includes("the token may have been used already"))
  ok(said->String.includes("the install itself is complete"))
  ok(said->String.includes("BINDING now holds the token just given"))
  ok(said->String.includes("without the token and DRIVER_CONTROL_BASE updates it without binding"))
  ok(!(said->String.includes(token)))
})

test("an answer recording another origin than the one sent is malformed, never bound", () => {
  let account = empty()
  account.control = Some(recorded("https://elsewhere.example.com"))
  let (faked, result) = installed(account, fixture())
  deepEqual(
    result,
    Error(
      [
        "the control's answer is malformed, recording https://elsewhere.example.com",
        `where ${origin} was sent`,
      ]->Array.join(" "),
    ),
  )
  ok(faked.said->Array.every(l => !(l->String.startsWith("bound binding"))))
})

test("the subdomain read and the bind are held to 10 seconds to connect and 30 in all", () => {
  let (faked, _) = installed(empty(), fixture())
  let timed = l => l->String.includes("--connect-timeout 10 --max-time 30")
  let lines = plain(faked)
  ok(timed(lines->Array.find(l => l->String.endsWith("/workers/subdomain"))->Option.getOr("")))
  ok(timed(lines->Array.find(l => l->String.endsWith("/bindings/bind"))->Option.getOr("")))
})

after(() => fixtures->Array.forEach(root => Host.rmSync(root, {recursive: true, force: true})))
