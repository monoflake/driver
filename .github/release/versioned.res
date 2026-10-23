/***
 * `node .github/release/versioned.res.mjs [--dry-run]`, after `mise run archive`, names both
 * archives in target/archives/built.json at RFC 8c0rg's version, or none if the last release's.
 */
type captured = {status: Nullable.t<int>, stdout: Nullable.t<string>}
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
  switch version->String.split(".")->Array.map(part => Int.fromString(part)) {
  | [Some(major), Some(minor), Some(patch)] => Some((major, minor, patch))
  | _ => None
  }

let later = ((a, b, c), (x, y, z)) => a != x ? a > x : b != y ? b > y : c > z

/** The version this build takes, RFC 8c0rg, the manifest's own where the major is new, the minor
 * raised where an interface it serves is, and the patch raised otherwise. */
let next = (~manifest, ~last: option<(string, dict<int>)>, ~serves: dict<int>) =>
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
    let (minor, patch) = raised ? (minor + 1, 0) : (minor, patch + 1)
    Some(`${major->Int.toString}.${minor->Int.toString}.${patch->Int.toString}`)
  }

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
    let recorded = last->Option.map(entry => (
      entry->text("version")->Option.getOr(""),
      entry
      ->field("interfaces")
      ->Option.flatMap(JSON.Decode.object)
      ->Option.getOr(Dict.make())
      ->Dict.toArray
      ->Array.filterMap(((name, v)) =>
        v->JSON.Decode.float->Option.map(v => (name, v->Float.toInt))
      )
      ->Dict.fromArray,
    ))
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
    let unchanged =
      missing == [] &&
        last->Option.mapOr(false, entry =>
          archives->Array.every(((target, path)) =>
            entry
            ->list("assets")
            ->Array.some(
              asset =>
                asset->text("target") == Some(target) &&
                  asset->text("sha256") == Some(sha256(path)),
            )
          )
        )
    switch next(~manifest, ~last=recorded, ~serves) {
    | _ if missing != [] && !dry =>
      refuse(`not built: ${missing->Array.map(((_, path)) => path)->Array.join(", ")}`)
    | _ if unchanged =>
      Console.log("both archives are the last release's, so nothing is released")
      write(JSON.Encode.object(dict{"artifacts": JSON.Encode.array([])}))
    | None => refuse(`machine/Cargo.toml's version ${manifest} is not MAJOR.MINOR.PATCH`)
    | Some(version) =>
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
        Archive.package,
        version,
        `[\`${commit->String.slice(
            ~start=0,
            ~end=7,
          )}\`](https://github.com/${repository}/commit/${commit})`,
        assets
        ->Array.map(((target, _, _, file)) => `[${target}](${link(file)})`)
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

main()
