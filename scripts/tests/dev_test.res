/***
 * `dev`'s two paths on a machine faked as sh shows it: the probe telling a local copy, the channel
 * with and without a mac signer and a store path apart, and the channel's install run over a
 * directory of versions with systemctl, flock and mv's -T faked, RFC n0o4l.
 */
open Asserted

@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:fs") external readlinkSync: string => string = "readlinkSync"
@module("node:fs") external readFileSync: (string, @as("utf8") _) => string = "readFileSync"
@module("node:fs") external readdirSync: string => array<string> = "readdirSync"

type ended = {status: int, said: string}

/** Executables put first on the path: flock that always holds, mv that reads -T as BSD's -h, and
 * systemctl that logs its calls and fails a restart while FAIL names a file and `current` is a dev
 * version. */
let shims = (root, ~exec, ~config) => {
  let bin = Host.join([root, "bin"])
  Archive.mkdirSync(bin, {recursive: true})
  let put = (name, body) => {
    let path = Host.join([bin, name])
    writeFileSync(path, `#!/bin/sh\n${body}\n`)
    Archive.chmodSync(path, 0o755)
  }
  put("flock", "exit 0")
  put("mv", `if [ "$1" = -T ]; then shift; exec /bin/mv -h "$@"; fi\nexec /bin/mv "$@"`)
  put(
    "systemctl",
    `echo "$*" >> "$LOG"
case $1 in
show) case $5 in
  driver-machine) echo "{ path=${exec} ; argv[]=${exec} ; }" ;;
  *) echo "A=b MACHINE_UPDATE_CONFIG=${config}" ;;
  esac ;;
restart) [ -z "$FAIL" ] || case $(readlink "$ROOT/current") in *+dev) exit 1 ;; esac ;;
esac
exit 0`,
  )
  bin
}

let run = (script, ~bin, ~root, ~fail=false) => {
  let env = Dict.fromArray(
    [
      ...Host.processEnv->Dict.toArray,
      ("PATH", `${bin}:${Host.processEnv->Dict.get("PATH")->Option.getOr("")}`),
      ("LOG", Host.join([root, "log"])),
      ("ROOT", Host.join([root, "driver"])),
      ("FAIL", fail ? "yes" : ""),
    ],
  )
  let done = Host.spawnSync(
    "sh",
    ["-c", script],
    {cwd: root, env, stdio: ["ignore", "pipe", "pipe"], encoding: "utf8"},
  )
  {
    status: done.status->Nullable.toOption->Option.getOr(-1),
    said: done.stdout->Nullable.toOption->Option.getOr("")->String.trim,
  }
}

let fixture = () => {
  let root = Host.mkdtempSync(Host.join([Host.tmpdir(), "dev-root-"]))
  Archive.mkdirSync(Host.join([root, "driver"]), {recursive: true})
  writeFileSync(Host.join([root, "stage"]), "binary")
  root
}

let version = "0.1.3+dev"

let laying = root =>
  Dev.laid(~root=Host.join([root, "driver"]), ~stage=Host.join([root, "stage"]), version)

/** A version of the updater's layout, a directory holding its executable, with `current` at it. */
let versioned = (root, name, ~current) => {
  let dir = Host.join([root, "driver", name])
  Archive.mkdirSync(dir, {recursive: true})
  writeFileSync(Host.join([dir, "driver-machine"]), name)
  if current {
    symlinkSync(name, Host.join([root, "driver", "current"]))
  }
}

let at = (root, name) => Host.join([root, "driver", name])

test("a first install lays the version out with no previous and restarts both units", () => {
  let root = fixture()
  let bin = shims(root, ~exec="x", ~config="x")
  let done = run(laying(root), ~bin, ~root)
  deepEqual(done, {status: 0, said: "driver-machine driver-machine-entry"})
  deepEqual(readlinkSync(at(root, "current")), version)
  ok(!Host.existsSync(at(root, "previous")))
  deepEqual(readFileSync(Host.join([at(root, version), "driver-machine"])), "binary")
  deepEqual(readdirSync(at(root, "."))->Array.filter(n => n->String.startsWith(".install")), [])
})

test("an install over a version moves previous to it and leaves it in place", () => {
  let root = fixture()
  versioned(root, "0.1.2", ~current=true)
  let bin = shims(root, ~exec="x", ~config="x")
  deepEqual(run(laying(root), ~bin, ~root).status, 0)
  deepEqual(
    (readlinkSync(at(root, "current")), readlinkSync(at(root, "previous"))),
    (version, "0.1.2"),
  )
  deepEqual(readFileSync(Host.join([at(root, "0.1.2"), "driver-machine"])), "0.1.2")
})

test("a second install of the same version replaces its binary and moves no link", () => {
  let root = fixture()
  versioned(root, "0.1.2", ~current=true)
  let bin = shims(root, ~exec="x", ~config="x")
  run(laying(root), ~bin, ~root)->ignore
  writeFileSync(Host.join([root, "stage"]), "again")
  deepEqual(run(laying(root), ~bin, ~root).status, 0)
  deepEqual(
    (readlinkSync(at(root, "current")), readlinkSync(at(root, "previous"))),
    (version, "0.1.2"),
  )
  deepEqual(readFileSync(Host.join([at(root, version), "driver-machine"])), "again")
})

test("units that do not restart have both links put back and the install refused", () => {
  let root = fixture()
  versioned(root, "0.1.1", ~current=false)
  versioned(root, "0.1.2", ~current=true)
  symlinkSync("0.1.1", at(root, "previous"))
  let bin = shims(root, ~exec="x", ~config="x")
  let done = run(laying(root), ~bin, ~root, ~fail=true)
  deepEqual(done.status, 1)
  deepEqual(
    (readlinkSync(at(root, "current")), readlinkSync(at(root, "previous"))),
    ("0.1.2", "0.1.1"),
  )
})

test(
  "the probe tells a local copy, the channel with and without a mac signer, and a store path",
  () => {
    let root = fixture()
    let signers = Host.join([root, "signers"])
    let config = Host.join([root, "config.json"])
    writeFileSync(config, `{"bucket":"b","driverSigners":"${signers}","machine":"m"}`)
    let asked = (exec, ~lines) => {
      writeFileSync(signers, lines)
      let bin = shims(root, ~exec, ~config)
      let done = run(Dev.probing(~installed="/dev/copy", ~root="/var/lib/driver"), ~bin, ~root)
      done.said->String.split(" ")->Array.get(0)
    }
    let ci = `ci namespaces="driver-pointer" key\n`
    let channel = "/var/lib/driver/current/driver-machine"
    deepEqual(asked("/dev/copy", ~lines=ci), Some("local"))
    deepEqual(asked(channel, ~lines=ci), Some("untrusted"))
    deepEqual(asked(channel, ~lines=ci ++ `mac namespaces="driver-pointer" key\n`), Some("channel"))
    deepEqual(asked("/nix/store/x-driver/bin/driver-machine", ~lines=ci), Some("store"))
  },
)

test("a dry run names the channel's path for a trusted machine and a refusal for the rest", () => {
  let said = kind => Dev.described("root@okra", kind)->Array.join("\n")
  ok(said(Channel)->String.includes("/var/lib/driver/.update-lock"))
  ok(said(Channel)->String.includes("+dev"))
  ok(said(Local)->String.includes("local copy"))
  ok(said(Untrusted)->String.includes("testSigner"))
  ok(said(Store)->String.includes("refused"))
})
