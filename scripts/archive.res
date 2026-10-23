/***
 * driver-machine built static against musl for each machine's architecture by cargo-zigbuild, and
 * archived with the licenses as `driver-machine-<version>-linux-<machine>.tar.gz`, RFC 8c0rg.
 */

type spawned = {status: Nullable.t<int>, stdout: Nullable.t<string>}
type spawnOptions = {cwd: string, stdio?: string, encoding?: string, env?: Dict.t<string>}
@module("node:child_process")
external spawnSync: (string, array<string>, spawnOptions) => spawned = "spawnSync"
type made = {recursive: bool}
type removed = {recursive: bool, force: bool}
type stats = {size: float}
@module("node:fs") external readFileSync: (string, @as("utf8") _) => string = "readFileSync"
@module("node:fs") external readBytes: string => Uint8Array.t = "readFileSync"
@module("node:fs") external mkdirSync: (string, made) => unit = "mkdirSync"
@module("node:fs") external rmSync: (string, removed) => unit = "rmSync"
@module("node:fs") external copyFileSync: (string, string) => unit = "copyFileSync"
@module("node:fs") external chmodSync: (string, int) => unit = "chmodSync"
@module("node:fs") external utimesSync: (string, int, int) => unit = "utimesSync"
@module("node:fs") external writeBytes: (string, Uint8Array.t) => unit = "writeFileSync"
@module("node:zlib") external gzipSync: Uint8Array.t => Uint8Array.t = "gzipSync"
@module("node:fs") external statSync: string => stats = "statSync"
type hash
@module("node:crypto") external createHash: string => hash = "createHash"
@send external update: (hash, Uint8Array.t) => hash = "update"
@send external digest: (hash, @as("hex") _) => string = "digest"
@module("node:path") @variadic external join: array<string> => string = "join"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@val external importMetaUrl: string = "import.meta.url"
@val external isMain: bool = "import.meta.main"
@val external env: Dict.t<string> = "process.env"
@val external copy: (@as(json`{}`) _, Dict.t<string>) => Dict.t<string> = "Object.assign"

let root = join([fileURLToPath(importMetaUrl), "..", ".."])
let package = "driver-machine"

/** Each target built, the machine its archive is named by, and what `file` says of its machine. */
let targets = [
  ("x86_64-unknown-linux-musl", "x86_64", "x86-64"),
  ("aarch64-unknown-linux-musl", "aarch64", "ARM aarch64"),
]

/** The program's version, its manifest's `[package]` version. */
let version = () => {
  let section = ref("")
  readFileSync(join([root, "machine", "Cargo.toml"]))
  ->String.split("\n")
  ->Array.findMap(line => {
    let line = line->String.trim
    if line->String.startsWith("[") {
      section := line
      None
    } else if section.contents == "[package]" && line->String.startsWith("version") {
      line->String.split("\"")->Array.get(1)
    } else {
      None
    }
  })
}

/** A command run in the repository's root, its output shown, and whether it passed. */
let ran = (command, arguments, ~environment=?) =>
  spawnSync(
    command,
    arguments,
    {cwd: root, stdio: "inherit", env: ?environment},
  ).status->Nullable.toOption == Some(0)

/** The flags for an archive with no extended attributes, root its owner and group and ustar its
 * format, as GNU tar on Linux and bsdtar on macOS each spell them. */
let plain = () =>
  switch spawnSync("tar", ["--version"], {cwd: root, encoding: "utf8"}).stdout->Nullable.toOption {
  | Some(said) if said->String.includes("GNU tar") => [
      "--format=ustar",
      "--no-xattrs",
      "--owner=root:0",
      "--group=root:0",
      "--mtime=@0",
    ]
  | _ => [
      "--format=ustar",
      "--no-xattrs",
      "--no-mac-metadata",
      "--uid",
      "0",
      "--gid",
      "0",
      "--uname",
      "root",
      "--gname",
      "root",
    ]
  }

/** What `file` says of a binary. */
let described = binary =>
  spawnSync("file", ["-b", binary], {cwd: root, encoding: "utf8"}).stdout
  ->Nullable.toOption
  ->Option.getOr("")

/** Where cargo writes the program built for a target. */
let binary = target => join([root, "target", target, "release", package])

/** The program built for one target, and held static and of its machine, its path or why not. */
let built = ((target, _, named)) => {
  let binary = binary(target)
  if !ran("cargo", ["zigbuild", "--release", "--locked", "-p", package, "--target", target]) {
    Error(`${target}: cargo zigbuild failed`)
  } else {
    let said = described(binary)
    said->String.includes("statically linked") && said->String.includes(named)
      ? Ok(binary)
      : Error(`${binary}: ${said->String.trim}, not a static ${named} binary`)
  }
}

/** One target built, held static and of its machine, and archived, its path or why not. */
let archived = (~version, (target, machine, named)) => {
  let directory = join([root, "target", "archives"])
  let name = `${package}-${version}-linux-${machine}`
  let archive = join([directory, `${name}.tar.gz`])
  switch built((target, machine, named)) {
  | Error(_) as failed => failed
  | Ok(binary) =>
    let staged = join([directory, name])
    rmSync(staged, {recursive: true, force: true})
    mkdirSync(staged, {recursive: true})
    copyFileSync(binary, join([staged, package]))
    chmodSync(join([staged, package]), 0o755)
    ["LICENSE-MIT", "LICENSE-APACHE"]->Array.forEach(text => {
      copyFileSync(join([root, text]), join([staged, text]))
      chmodSync(join([staged, text]), 0o644)
    })
    // macOS's tar writes no metadata of its own beside each file with this set.
    let quiet = copy(env)
    quiet->Dict.set("COPYFILE_DISABLE", "1")
    let files = [package, "LICENSE-MIT", "LICENSE-APACHE"]
    // Every file dated the epoch, so a binary built again the same gives the same archive.
    files->Array.forEach(file => utimesSync(join([staged, file]), 0, 0))
    let tar = join([directory, `${name}.tar`])
    let packed = ran("tar", ["-cf", tar, ...plain(), "-C", staged, ...files], ~environment=quiet)
    rmSync(staged, {recursive: true, force: true})
    if packed {
      // zlib's header carries no time or name, as either tar's own gzip might.
      writeBytes(archive, gzipSync(readBytes(tar)))
    }
    rmSync(tar, {force: true, recursive: false})
    packed ? Ok(archive) : Error(`${archive}: tar failed`)
  }
}

let dry = Base.args->Array.includes("--dry-run")
if isMain {
  switch version() {
  | None =>
    Console.error("machine/Cargo.toml: no [package] version")
    Base.process->Base.setExitCode(1)
  | Some(version) if dry =>
    targets->Array.forEach(((target, machine, _)) => {
      Console.log(`would run cargo zigbuild --release --locked -p ${package} --target ${target}`)
      Console.log(`would write target/archives/${package}-${version}-linux-${machine}.tar.gz`)
    })
  | Some(version) =>
    targets->Array.forEach(target =>
      switch archived(~version, target) {
      | Ok(archive) =>
        let sha256 = createHash("sha256")->update(readBytes(archive))->digest
        let size = statSync(archive).size->Float.toString
        Console.log(`${sha256}  ${archive->String.replace(root ++ "/", "")}  ${size} bytes`)
      | Error(why) =>
        Console.error(why)
        Base.process->Base.setExitCode(1)
      }
    )
  }
}
