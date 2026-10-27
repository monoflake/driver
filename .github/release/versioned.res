/***
 * `node .github/release/versioned.res.mjs [--dry-run]`, after `mise run archive`, names both
 * archives in target/archives/built.json at machine/Cargo.toml's version, or none if released.
 */
type captured = {status: Nullable.t<int>, stdout: Nullable.t<string>, stderr: Nullable.t<string>}
type capturing = {cwd: string, encoding: string, maxBuffer: int}
@module("node:child_process")
external capture: (string, array<string>, capturing) => captured = "spawnSync"
@module("node:fs") external existsSync: string => bool = "existsSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"

let root = Archive.root
let dry = Base.args->Array.includes("--dry-run")
let built = Archive.join([root, "target", "archives", "built.json"])

let refuse = why => {
  Console.error(`built: ${why}`)
  Base.process->Base.setExitCode(1)
}

let field = (json, key) => json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key))
let text = (json, key) => json->field(key)->Option.flatMap(JSON.Decode.string)
let list = (json, key) => json->field(key)->Option.flatMap(JSON.Decode.array)->Option.getOr([])

/** A version's three numbers, or none where it is not plain `MAJOR.MINOR.PATCH`. */
let numbers = version =>
  if !RegExp.test(/^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$/, version) {
    None
  } else {
    switch version->String.split(".")->Array.map(part => Int.fromString(part)) {
    | [Some(major), Some(minor), Some(patch)] => Some((major, minor, patch))
    | _ => None
    }
  }

let later = ((a, b, c), (x, y, z)) => a != x ? a > x : b != y ? b > y : c > z

/** The version `mise run bump` writes, RFC 8c0rg, the manifest's own where the major is new, the
 * minor raised where an interface it serves is or a change is breaking, and the patch otherwise. */
let incremented = (~manifest, ~last: option<(string, dict<int>)>, ~serves: dict<int>, ~breaking) =>
  switch (numbers(manifest), last->Option.flatMap(((version, _)) => numbers(version))) {
  | (None, _) => None
  | (Some(_), None) => Some(manifest)
  | (Some((major, _, _)), Some((was, _, _))) if major != was => Some(manifest)
  | (Some(_), Some((major, minor, patch))) =>
    let recorded = last->Option.mapOr(Dict.make(), ((_, interfaces)) => interfaces)
    let raised =
      serves
      ->Dict.toArray
      ->Array.some(((name, version)) => version > recorded->Dict.get(name)->Option.getOr(0))
    let (minor, patch) = raised || breaking ? (minor + 1, 0) : (minor, patch + 1)
    Some(`${major->Int.toString}.${minor->Int.toString}.${patch->Int.toString}`)
  }

let next = (~manifest, ~last, ~serves) => incremented(~manifest, ~last, ~serves, ~breaking=false)

let breaking = message =>
  RegExp.test(/^[a-z]+(?:\([^\n)]+\))?!:/, message) ||
  RegExp.test(/(?:^|\n)BREAKING CHANGE: /, message)

/** The version `mise run bump` writes, the manifest's own where no input changed since the last
 * release, and otherwise the higher of it and the incremented one, so a raise by hand is kept. */
let bumped = (~manifest, ~last, ~serves, ~messages, ~changed) =>
  switch numbers(manifest) {
  | None => None
  | Some(_) if !changed => Some(manifest)
  | Some(now) =>
    incremented(
      ~manifest,
      ~last,
      ~serves,
      ~breaking=messages->Array.some(breaking),
    )->Option.map(next =>
      numbers(next)->Option.mapOr(false, next => later(next, now)) ? next : manifest
    )
  }

let checked = (~manifest, ~last, ~changed) =>
  switch (numbers(manifest), last->Option.flatMap(numbers)) {
  | (None, _) => Error("machine/Cargo.toml needs MAJOR.MINOR.PATCH")
  | (Some(now), Some(was)) if changed && !later(now, was) =>
    Error(
      "driver-machine inputs changed without a version above the last release; run mise run bump",
    )
  | _ => Ok()
  }

let already = (entries, version) =>
  entries->Array.some(entry =>
    entry->text("name") == Some(Archive.package) && entry->text("version") == Some(version)
  )

/** The interfaces the program serves, as served.rs names them, each at the version
 * monoflake/platform's contracts give it. */
let served = () => {
  let source = Archive.readFileSync(Archive.join([root, "machine", "src", "served.rs"]))
  let contracts = JSON.parseOrThrow(
    Archive.readFileSync(Archive.join([root, "..", "platform", "model", "contracts.json"])),
  )
  switch /const SERVED: &str = "([^"]*)";/->RegExp.exec(source) {
  | Some(found) =>
    found
    ->RegExp.Result.matches
    ->Array.get(0)
    ->Option.flatMap(x => x)
    ->Option.getOr("")
    ->String.split(",")
    ->Array.map(String.trim)
    ->Array.filterMap(name =>
      contracts
      ->field("interfaces")
      ->Option.flatMap(interfaces => interfaces->field(name))
      ->Option.flatMap(interface => interface->field("version"))
      ->Option.flatMap(JSON.Decode.float)
      ->Option.map(version => (name, version->Float.toInt))
    )
    ->Dict.fromArray
  | None => Dict.make()
  }
}

/** What every published release here lists, read by the workspace's scripts/release. */
let listed = () =>
  switch Archive.env->Dict.get("WORKSPACE") {
  | None => Error("no WORKSPACE, which mise sets from the workspace's mise.toml")
  | Some(workspace) =>
    let script = Archive.join([workspace, "scripts", "release", "release.res.mjs"])
    switch capture(
      "node",
      [script, "listed", ...dry ? ["--dry-run"] : []],
      {cwd: root, encoding: "utf8", maxBuffer: 67108864},
    ) {
    | {status, stdout} if status->Nullable.toOption == Some(0) =>
      switch JSON.parseOrThrow(stdout->Nullable.toOption->Option.getOr(""))->JSON.Decode.array {
      | Some(entries) => Ok(entries)
      | None => Error(`${script} listed printed no list`)
      | exception JsExn(_) => Error(`${script} listed printed no JSON`)
      }
    | _ => Error(`${script} listed failed`)
    }
  }

/** The highest version a published release lists of the program, with its assets and interfaces. */
let lastOf = entries =>
  entries
  ->Array.filter(entry => entry->text("name") == Some(Archive.package))
  ->Array.filterMap(entry =>
    entry->text("version")->Option.flatMap(numbers)->Option.map(n => (n, entry))
  )
  ->Array.reduce(None, (best, (n, entry)) =>
    switch best {
    | Some((m, _)) if !later(n, m) => best
    | _ => Some((n, entry))
    }
  )
  ->Option.map(((_, entry)) => entry)

let environment = name => Archive.env->Dict.get(name)

let warn = why => Console.error(`built: warning: ${why}`)

/** A comparison or release lookup that failed, warned of and passed, so an offline or rate limited
 * machine is not held from committing, RFC 8c0rg; `undone` says what was left undone. */
let unread = (why, ~undone) => warn(`${why}; ${undone}`)

let commit = switch environment("GITHUB_SHA") {
| Some(sha) => sha
| None =>
  capture("git", ["rev-parse", "HEAD"], {cwd: root, encoding: "utf8", maxBuffer: 1048576}).stdout
  ->Nullable.toOption
  ->Option.getOr("unknown")
  ->String.trim
}

let repository = environment("GITHUB_REPOSITORY")->Option.getOr("monoflake/driver")

let sha256 = path =>
  Archive.createHash("sha256")->Archive.update(Archive.readBytes(path))->Archive.digest

let write = document => {
  let shown = JSON.stringify(document, ~space=2) ++ "\n"
  if dry {
    Console.log("would write target/archives/built.json")
    shown->String.trimEnd->String.split("\n")->Array.forEach(line => Console.log(`  ${line}`))
  } else {
    Archive.mkdirSync(Archive.join([root, "target", "archives"]), {recursive: true})
    writeFileSync(built, shown)
    Console.log("wrote target/archives/built.json")
  }
}

let main = () =>
  switch (Archive.version(), listed()) {
  | (None, _) => refuse("machine/Cargo.toml: no [package] version")
  | (_, Error(why)) => refuse(why)
  | (Some("0.0.0"), _) =>
    Console.log("driver-machine is 0.0.0, its releases not opened yet, so nothing is released")
    write(JSON.Encode.object(dict{"artifacts": JSON.Encode.array([])}))
  | (Some(manifest), Ok(entries)) =>
    let archives =
      Archive.targets->Array.map(((_, machine, _)) => (
        `linux-${machine}`,
        Archive.join([
          root,
          "target",
          "archives",
          `${Archive.package}-${manifest}-linux-${machine}.tar.gz`,
        ]),
      ))
    let missing = archives->Array.filter(((_, path)) => !existsSync(path))
    let last = lastOf(entries)
    let serves = served()
    Console.log(
      `serves ${serves
        ->Dict.toArray
        ->Array.map(((name, v)) => `${name} ${v->Int.toString}`)
        ->Array.join(", ")}`,
    )
    Console.log(
      last->Option.mapOr("no release lists driver-machine yet", entry =>
        `last released ${entry->text("version")->Option.getOr("")} in ${entry
          ->text("release")
          ->Option.getOr("")}`
      ),
    )
    switch numbers(manifest) {
    | _ if already(entries, manifest) =>
      Console.log(`${manifest} is released already, so nothing is released`)
      write(JSON.Encode.object(dict{"artifacts": JSON.Encode.array([])}))
    | _ if missing != [] && !dry =>
      refuse(`not built: ${missing->Array.map(((_, path)) => path)->Array.join(", ")}`)
    | None => refuse(`machine/Cargo.toml's version ${manifest} is not MAJOR.MINOR.PATCH`)
    | Some(_) =>
      let version = manifest
      Console.log(`releases ${version}`)
      let directory = Archive.join([root, "target", "archives", "release"])
      let assets = archives->Array.map(((target, path)) => {
        let file = `${Archive.package}-${version}-${target}.tar.gz`
        (target, path, Archive.join([directory, file]), file)
      })
      if !dry {
        Archive.rmSync(directory, {recursive: true, force: true})
        Archive.mkdirSync(directory, {recursive: true})
        assets->Array.forEach(((_, from, to, _)) => Archive.copyFileSync(from, to))
      }
      let link = file => `https://github.com/${repository}/releases/download/{release}/${file}`
      let row = [
        "machine",
        version,
        `[\`${commit->String.slice(
            ~start=0,
            ~end=7,
          )}\`](https://github.com/${repository}/commit/${commit})`,
        assets
        ->Array.map(((target, _, _, file)) =>
          `[${target->String.replace("linux-", "")}](${link(file)})`
        )
        ->Array.join(" "),
      ]
      write(
        JSON.Encode.object(
          dict{
            "artifacts": JSON.Encode.array([
              JSON.Encode.object(
                dict{
                  "name": JSON.Encode.string(Archive.package),
                  "version": JSON.Encode.string(version),
                  "commit": JSON.Encode.string(commit),
                  "interfaces": serves->Dict.mapValues(v => JSON.Encode.int(v))->JSON.Encode.object,
                  "assets": assets
                  ->Array.map(((target, _, to, _)) =>
                    JSON.Encode.object(
                      dict{
                        "target": JSON.Encode.string(target),
                        "kind": JSON.Encode.string("binary"),
                        "path": JSON.Encode.string(to->String.replace(root ++ "/", "")),
                      },
                    )
                  )
                  ->JSON.Encode.array,
                  "row": row->Array.map(JSON.Encode.string)->JSON.Encode.array,
                },
              ),
            ]),
          },
        ),
      )
    }
  }

if Archive.isMain {
  main()
}
