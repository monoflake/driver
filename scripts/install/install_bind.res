/***
 * The binding bound once the Worker `driver` is deployed, its origin reported to the control's
 * `bindings.bind` with the binding token read on stdin, platform RFC 8j7b0.
 */
open Install_world

type parsed = {
  protocol: string,
  hostname: string,
  port: string,
  username: string,
  password: string,
  pathname: string,
  search: string,
  hash: string,
  origin: string,
}
@new external parse: string => parsed = "URL"

/** A host whose last label is a number, as an IP literal is, or one the public never reaches. */
let local = host =>
  host->String.startsWith("[") ||
  /^[0-9]+$/->RegExp.test(host->String.split(".")->Array.at(-1)->Option.getOr("")) ||
  host == "localhost" ||
  [".localhost", ".local", ".internal", ".home.arpa"]->Array.some(end =>
    host->String.endsWith(end)
  ) ||
  host == "home.arpa" ||
  !(host->String.includes("."))

/** An `https` address on a DNS host and the default port, with no user, query or fragment. */
let reachable = (text, ~what) =>
  switch parse(text) {
  | url if url.protocol != "https:" => Error(`${what} ${text} is not https`)
  // A host ending in a dot is refused, so `localhost.` is never read as another host.
  | url if url.hostname->String.endsWith(".") =>
    Error(`${what} ${text} names a host ending in a dot, which it never holds`)
  | url if local(url.hostname) => Error(`${what} ${text} names no DNS host the public reaches`)
  | url if url.port != "" => Error(`${what} ${text} names a port, where only the default is`)
  | url if url.username != "" || url.password != "" =>
    Error(`${what} ${text} names a user, which it never holds`)
  | url
    if url.search != "" ||
    url.hash != "" ||
    text->String.includes("?") ||
    text->String.includes("#") =>
    Error(`${what} ${text} holds a query or a fragment, which it never holds`)
  | url => Ok(url)
  | exception JsExn(_) => Error(`${what} ${text} is no URL`)
  }

/**
 * Where the control's calls are sent, `DRIVER_CONTROL_BASE`, its path kept and a trailing `/`
 * dropped, as the runner's `--base` is.
 */
let baseOf = text =>
  reachable(text, ~what="the base")->Result.map(url => {
    let path = url.pathname->String.replaceRegExp(/\/+$/, "")
    `${url.origin}${path}`
  })

/** The Worker's origin as 8j7b0 judges one, a base with no path at all. */
let originOf = text =>
  reachable(text, ~what="the origin")->Result.flatMap(url =>
    url.pathname == "/" && !(text->String.endsWith("/"))
      ? Ok(url.origin)
      : Error(`the origin ${text} holds a path, which an origin never holds`)
  )

/** A call's address, the base and `/{interface}/{operation}` joined by exactly one `/`. */
let callTo = (base, ~interface, ~operation) => `${base}/${interface}/${operation}`

/**
 * The bind's two halves, the token on stdin and the base, both or neither, one alone refused
 * by the name of the other, and a base of no control's form is refused, before anything runs.
 */
let bindOf = (w, ~token: option<string>) =>
  switch (token, value(w.env, controlBase)) {
  | (None, None) => Ok(None)
  | (Some(_), None) =>
    Error(`a token on stdin and no ${controlBase}, so the bind has half its inputs`)
  | (None, Some(_)) =>
    Error(`${controlBase} and no token on stdin, so the bind has half its inputs`)
  | (Some(token), Some(base)) => baseOf(base)->Result.map(base => Some((token, base)))
  }

/** The account's workers.dev subdomain, read by curl with the install token on stdin. */
let subdomainRead = w => {
  program: "curl",
  args: [
    "-q",
    "--silent",
    "--show-error",
    "--fail-with-body",
    "--connect-timeout",
    "10",
    "--max-time",
    "30",
    "--header",
    "@-",
    `https://api.cloudflare.com/client/v4/accounts/${value(w.env, account)->Option.getOr(
        "",
      )}/workers/subdomain`,
  ],
  cwd: ".",
  input: `Authorization: Bearer ${value(w.env, installToken)->Option.getOr("")}`,
  env: quiet(w.env),
}

/** The subdomain an answer names, or why it names none. */
let subdomainOf = body =>
  switch parsed(body) {
  | Some(json) if json->member("success") == JSON.Boolean(true) =>
    switch json->member("result")->text("subdomain") {
    | Some(subdomain) if /^[a-z0-9-]+$/->RegExp.test(subdomain) => Ok(subdomain)
    | Some(_) | None => Error("the account's workers.dev subdomain is named nowhere")
    }
  | Some(_) | None => Error("the account's workers.dev subdomain was not read")
  }

/** The call's body, `bindings.bind` reaching by the origin, as JSON. */
let bindBody = origin =>
  JSON.stringify(
    JSON.Object(
      dict{
        "interface": JSON.String("bindings"),
        "operation": JSON.String("bind"),
        "input": JSON.Object(
          dict{
            "reach": JSON.Object(
              dict{"name": JSON.String("origin"), "origin": JSON.String(origin)},
            ),
          },
        ),
      },
    ),
  )

/**
 * The call made once, the token a bearer on stdin as `driver-machine bind` sends it, its body the
 * origin alone, https alone and following no redirect, so the token goes nowhere else.
 */
let bindCall = (~token, ~base, ~origin, ~env) => {
  program: "curl",
  args: [
    "-q",
    "--silent",
    "--show-error",
    "--connect-timeout",
    "10",
    "--max-time",
    "30",
    "--proto",
    "=https",
    "--header",
    "@-",
    "--header",
    "content-type: application/json",
    "--header",
    "accept: application/json",
    "--data",
    bindBody(origin),
    callTo(base, ~interface="bindings", ~operation="bind"),
  ],
  cwd: ".",
  input: `Authorization: Bearer ${token}`,
  env: quiet(env),
}

/** What the control answered, the origin it recorded, or the reason it refused. */
/**
 * What a control answers `denied`, its own words never shown, since it most likely means the token
 * was spent by a bind before, RFC 8j7b0's Ledger.
 */
let denied = [
  "the control denied the bind, so the token may have been used already;",
  `the install itself is complete, and ${binding} now holds the token just given;`,
  `a run without the token and ${controlBase} updates it without binding`,
]->Array.join(" ")

let answeredBy = (body, ~sent) =>
  switch parsed(body) {
  | Some(json) =>
    switch json->text("status") {
    | Some("success") =>
      let data = json->member("data")
      switch (data->member("binding")->JSON.Decode.float, data->member("reached")->text("origin")) {
      | (Some(binding), Some(origin)) if origin == sent => Ok((binding, origin))
      | (Some(_), Some(origin)) =>
        Error(`the control's answer is malformed, recording ${origin} where ${sent} was sent`)
      | _ => Error("the control's answer names no binding and origin")
      }
    | Some("error") =>
      switch json->text("reason") {
      | Some("denied") => Error(denied)
      | reason =>
        let message = json->text("message")->Option.getOr("")
        Error(`the control refused the bind, ${reason->Option.getOr("unknown")}: ${message}`)
      }
    | Some(_) | None => Error("the control's answer is no envelope")
    }
  | None => Error("the control's answer is not JSON")
  }

/** The binding bound to the origin of the Worker `worker`, or the bind passed over. */
let bound = (w, ~dry, ~bind, ~worker) =>
  switch bind {
  | None =>
    w.say(`no token on stdin and no ${controlBase}, so the bind is passed over`)
    Ok()
  | Some((token, base)) =>
    let read = subdomainRead(w)
    if dry {
      let origin = `https://${worker}.<the account's subdomain>.workers.dev`
      w.say(`would run ${shown(read)}, and bind the origin ${origin}`)
      let call = bindCall(~token, ~base, ~origin, ~env=w.env)
      w.say(`would run ${shown(call)}`)
      w.say(`  the token as ${binding} by its name alone, on stdin as a bearer`)
      Ok()
    } else {
      w.run(read)
      ->then(subdomainOf)
      ->then(subdomain => originOf(`https://${worker}.${subdomain}.workers.dev`))
      ->then(origin =>
        w.run(bindCall(~token, ~base, ~origin, ~env=w.env))->then(answeredBy(_, ~sent=origin))
      )
      ->Result.map(((binding, origin)) =>
        w.say(`bound binding ${Float.toString(binding)}, its origin ${origin} recorded`)
      )
    }
  }
