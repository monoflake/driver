/** The source inputs compared with the last release, RFC 8c0rg. */
let own = ["machine", "Cargo.toml", "Cargo.lock"]
let sibling = Archive.join([Archive.root, "..", "platform"])
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

let current = () => Archive.readFileSync(Archive.join([Archive.root, workflow]))

/** The platform commit the last release pinned and the one the working copy's release.yml pins,
 * which the next release builds, read from the local monoflake/platform where it holds both. */
let pins = (~read, ~current, entry) =>
  switch entry->Versioned.text("commit") {
  | None => Error("the last release names no source commit")
  | Some(from) =>
    read(~cwd=Archive.root, ~from, workflow)->Result.flatMap(last =>
      switch (platform(last), platform(current())) {
      | (None, _) => Error("the last release pins no platform commit")
      | (_, None) => Error(`${workflow} pins no platform commit`)
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

/** What changed since the last release, the driver's own inputs and the platform's, and the
 * platform commits that could not be read even after a fetch, where the platform is not known. */
type compared = {own: bool, shared: bool, unknown: array<string>}

let changed = (
  ~diff=difference,
  ~read=file,
  ~current=current,
  ~reach=commits => reached(commits),
  entry,
) =>
  pins(~read, ~current, entry)->Result.flatMap(((from, last, now)) =>
    diff(~cwd=Archive.root, ~from, own)->Result.flatMap(own => {
      let own = own != ""
      if last == now {
        Ok({own, shared: false, unknown: []})
      } else {
        switch reach([last, now]) {
        | Error(unknown) => Ok({own, shared: false, unknown})
        | Ok() =>
          sharedAt(~read, now)
          ->Result.flatMap(paths => diff(~cwd=sibling, ~from=last, ~to=now, paths))
          ->Result.map(shared => {own, shared: shared != "", unknown: []})
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
