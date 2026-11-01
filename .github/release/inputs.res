/** The source inputs compared with the last release, aligned with the landing roll. */
let own = ["machine", "Cargo.toml"]
let sibling = Archive.join([Archive.root, "..", "platform"])
let setup = ".github/actions/setup/action.yml"
/** Where the pin lived before the setup action held it, read at a release older than the action. */
let workflow = ".github/workflows/release.yml"

let disk = path => Ok(Archive.readFileSync(path))

/** Each path in monoflake/platform that driver-machine's crates reach, read by `read`. */
let shared = (~read=disk, ()) => {
  let seen = Dict.make()
  let failed = ref(None)
  let rec visit = directory => {
    if failed.contents == None && !(seen->Dict.get(directory)->Option.getOr(false)) {
      seen->Dict.set(directory, true)
      switch read(Archive.join([directory, "Cargo.toml"])) {
      | Error(why) => failed := Some(why)
      | Ok(manifest) =>
        let paths = /path\s*=\s*"([^"]+)"/g
        let rec next = () =>
          switch paths->RegExp.exec(manifest) {
          | None => ()
          | Some(found) =>
            found
            ->RegExp.Result.matches
            ->Array.get(0)
            ->Option.flatMap(x => x)
            ->Option.forEach(path => visit(Archive.join([directory, path])))
            next()
          }
        next()
      }
    }
  }
  visit(Archive.join([Archive.root, "machine"]))
  switch failed.contents {
  | Some(why) => Error(why)
  | None =>
    Ok(
      [
        "Cargo.toml",
        "model/contracts.json",
        ...seen
        ->Dict.keysToArray
        ->Array.filterMap(path =>
          path->String.startsWith(sibling ++ "/")
            ? Some(path->String.replace(sibling ++ "/", ""))
            : None
        ),
      ],
    )
  }
}

let output = (~cwd=Archive.root, command, args) => {
  let result = Versioned.capture(command, args, {cwd, encoding: "utf8", maxBuffer: 67108864})
  result.status->Nullable.toOption == Some(0)
    ? Ok(result.stdout->Nullable.toOption->Option.getOr("")->String.trim)
    : Error(
        `${command} ${args->Array.join(" ")} failed ${result.stderr
          ->Nullable.toOption
          ->Option.getOr("")
          ->String.trim}`,
      )
}

let jj = cwd => Versioned.existsSync(Archive.join([cwd, ".jj"]))

/** What changed in `paths` from `from` to `to`, or to the working copy where `to` is none. */
let difference = (~cwd, ~from, ~to=?, paths) =>
  jj(cwd)
    ? output(
        ~cwd,
        "jj",
        ["diff", "--from", from, "--to", to->Option.getOr("@"), "--summary", ...paths],
      )
    : output(
        ~cwd,
        "git",
        ["diff", "--name-only", from, ...to->Option.mapOr([], to => [to]), "--", ...paths],
      )

let file = (~cwd, ~from, path) =>
  jj(cwd)
    ? output(~cwd, "jj", ["file", "show", "--revision", from, path])
    : output(~cwd, "git", ["show", `${from}:${path}`])

let platform = source =>
  RegExp.fromString("ref: ([a-f0-9]{40}) # monoflake/platform")
  ->RegExp.exec(source)
  ->Option.flatMap(found => found->RegExp.Result.matches->Array.get(0)->Option.flatMap(x => x))

let current = () => Archive.readFileSync(Archive.join([Archive.root, setup]))

/** The file pinning the platform at `from`, the setup action, or release.yml where it is absent. */
let pinned = (~read, ~from) =>
  switch read(~cwd=Archive.root, ~from, setup) {
  | Ok(text) => Ok(text)
  | Error(_) => read(~cwd=Archive.root, ~from, workflow)
  }

/** The platform commit the last release pinned and the one the working copy's setup action pins,
 * which the next release builds, read from the local monoflake/platform where it holds both. */
let pins = (~read, ~current, entry) =>
  switch entry->Versioned.text("commit") {
  | None => Error("the last release names no source commit")
  | Some(from) =>
    pinned(~read, ~from)->Result.flatMap(last =>
      switch (platform(last), platform(current())) {
      | (None, _) => Error("the last release pins no platform commit")
      | (_, None) => Error(`${setup} pins no platform commit`)
      | (Some(last), Some(now)) => Ok((from, last, now))
      }
    )
  }

/** The shared paths at the commit the working copy pins, its crates read there. */
let sharedAt = (~read, now) =>
  shared(
    ~read=path =>
      path->String.startsWith(sibling ++ "/")
        ? read(~cwd=sibling, ~from=now, path->String.replace(sibling ++ "/", ""))
        : disk(path),
    (),
  )

/** Whether the repository at `cwd` holds `commit`. */
let holds = (~cwd, commit) =>
  (
    jj(cwd)
      ? output(~cwd, "jj", ["log", "--no-graph", "--revisions", commit, "--template", "commit_id"])
      : output(~cwd, "git", ["cat-file", "-e", `${commit}^{commit}`])
  )->Result.isOk

let fetched = (~cwd) =>
  jj(cwd) ? output(~cwd, "jj", ["git", "fetch"]) : output(~cwd, "git", ["fetch", "--quiet"])

/** Whether the local monoflake/platform holds every one of `commits`, fetched once where it lacks
 * one, or the ones it lacks even then. */
let reached = (~holds=holds, ~fetch=fetched, commits) => {
  let lacking = () => commits->Array.filter(commit => !holds(~cwd=sibling, commit))
  switch lacking() {
  | [] => Ok()
  | _ =>
    fetch(~cwd=sibling)->ignore
    switch lacking() {
    | [] => Ok()
    | lacking => Error(lacking)
    }
  }
}

// The setup action pins the contracts used to infer a minor raise.
let served = (
  ~read=file,
  ~current=current,
  ~reach=commits => reached(commits),
  ~source=() => Archive.readFileSync(Archive.join([Archive.root, "machine", "src", "served.rs"])),
  (),
) =>
  switch platform(current()) {
  | None => Error(`${setup} pins no platform commit`)
  | Some(now) =>
    switch reach([now]) {
    | Error(unknown) =>
      Versioned.warn(
        `monoflake/platform lacks ${unknown->Array.join(
            ", ",
          )} even after a fetch, so its served interface versions were not read; the patch is raised at least`,
      )
      Ok(Dict.make())
    | Ok() =>
      read(~cwd=sibling, ~from=now, "model/contracts.json")->Result.flatMap(text =>
        switch JSON.parseOrThrow(text) {
        | contracts => Ok(Versioned.interfaces(~source=source(), ~contracts))
        | exception JsExn(_) => Error("the pinned platform contracts are not JSON")
        }
      )
    }
  }

/** What changed since the last release, the driver's own inputs and the platform's, and the
 * platform commits that could not be read even after a fetch, where the platform is not known. */
type compared = {own: bool, shared: bool, unknown: array<string>}

/** The exclusions in the workspace's scripts/versions/counted.res also hold at a release. */
let counts = path => {
  let parts = path->String.split("/")
  let name = parts->Array.at(-1)->Option.getOr("")
  let settings = [
    ".editorconfig",
    ".gitattributes",
    ".gitignore",
    ".oxfmtrc.json",
    ".oxlintrc.json",
    "actionlint.yaml",
    "clippy.toml",
    "deny.toml",
    "jujutsu.toml",
    "rustfmt.toml",
  ]
  !(parts->Array.some(part => part == "docs" || part == "tests")) &&
  !(settings->Array.includes(name)) &&
  !RegExp.test(/_test\.[^\/]+$/, name) &&
  !RegExp.test(/(\.md|^LICENSE[^\/]*)$/, name)
}

let paths = line => {
  let path = line->String.replaceRegExp(/^[A-Z] /, "")
  switch /^(.*)\{(.*) => (.*)\}(.*)$/->RegExp.exec(path) {
  | Some(found) =>
    switch found->RegExp.Result.matches->Array.map(part => part->Option.getOr("")) {
    | [before, from, to, after] => [
        `${before}${from}${after}`->String.replaceAll("//", "/"),
        `${before}${to}${after}`->String.replaceAll("//", "/"),
      ]
    | _ => [path]
    }
  | None => [path]
  }
}

/** Only the paths a landing counts are carried into the release input guard. */
let carried = summary =>
  summary
  ->String.split("\n")
  ->Array.filter(line => line != "" && paths(line)->Array.some(counts))
  ->Array.join("\n")

let changed = (
  ~diff=difference,
  ~read=file,
  ~current=current,
  ~reach=commits => reached(commits),
  entry,
) =>
  pins(~read, ~current, entry)->Result.flatMap(((from, last, now)) =>
    diff(~cwd=Archive.root, ~from, own)->Result.flatMap(own => {
      let own = carried(own) != ""
      if last == now {
        Ok({own, shared: false, unknown: []})
      } else {
        switch reach([last, now]) {
        | Error(unknown) => Ok({own, shared: false, unknown})
        | Ok() =>
          sharedAt(~read, now)
          ->Result.flatMap(paths => diff(~cwd=sibling, ~from=last, ~to=now, paths))
          ->Result.map(shared => {own, shared: carried(shared) != "", unknown: []})
        }
      }
    })
  )

/** Each commit's message from `from` to `to`, or to the working copy, that touches `paths`. */
let messages = (~cwd, ~from, ~to=?, paths) =>
  (
    jj(cwd)
      ? output(
          ~cwd,
          "jj",
          [
            "log",
            "--no-graph",
            "--revisions",
            `${from}..${to->Option.getOr("@")}`,
            "--template",
            `description ++ "\\0"`,
            ...paths,
          ],
        )
      : output(
          ~cwd,
          "git",
          ["log", "--format=%B%x00", `${from}..${to->Option.getOr("HEAD")}`, "--", ...paths],
        )
  )->Result.map(log =>
    log->String.split("\u0000")->Array.map(String.trim)->Array.filter(message => message != "")
  )

/** Each commit's message since the last release, the driver's and the platform's, and the
 * platform commits that could not be read even after a fetch, whose messages are not among them. */
type since = {messages: array<string>, unread: array<string>}

let breakingSince = (
  ~log=messages,
  ~read=file,
  ~current=current,
  ~reach=commits => reached(commits),
  entry,
) =>
  pins(~read, ~current, entry)->Result.flatMap(((from, last, now)) =>
    log(~cwd=Archive.root, ~from, own)->Result.flatMap(own =>
      if last == now {
        Ok({messages: own, unread: []})
      } else {
        switch reach([last, now]) {
        | Error(unread) => Ok({messages: own, unread})
        | Ok() =>
          sharedAt(~read, now)
          ->Result.flatMap(paths => log(~cwd=sibling, ~from=last, ~to=now, paths))
          ->Result.map(shared => {messages: [...own, ...shared], unread: []})
        }
      }
    )
  )

let recorded = entry => (
  entry->Versioned.text("version")->Option.getOr(""),
  entry
  ->Versioned.field("interfaces")
  ->Option.flatMap(JSON.Decode.object)
  ->Option.getOr(Dict.make())
  ->Dict.toArray
  ->Array.filterMap(((name, value)) =>
    value->JSON.Decode.float->Option.map(v => (name, v->Float.toInt))
  )
  ->Dict.fromArray,
)
