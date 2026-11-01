/***
 * driver-machine built for a test machine's architecture, copied in, restarted and asked, RFC
 * n0o4l; each phase is timed, and `--watch` does it again on every save. A machine on the driver
 * channel takes it as a version of the updater's layout instead, which a later pointer overwrites.
 */

type spawned = {status: Nullable.t<int>, stdout: Nullable.t<string>}
type spawnOptions = {cwd: string, stdio: array<string>, encoding: string}
@module("node:child_process")
external spawnSync: (string, array<string>, spawnOptions) => spawned = "spawnSync"
@val external isMain: bool = "import.meta.main"

let directory = "/var/lib/driver-machine/dev"
let installed = `${directory}/${Archive.package}`
/** Where the build waits on a channel machine until it is laid out as a version. */
let staged = `${installed}.stage`
/** The updater's directory of versions, `current` and `previous`, monoflake/machine's
 * system/nix/update. */
let channel = "/var/lib/driver"
let service = "driver-machine"
/** The entry's unit, running the same binary, RFC rmll5. */
let entry = "driver-machine-entry"
/** driver-machine's port, its `PORT`, asked on the machine itself. */
let address = "http://localhost:37483"

/** What the program is built from, the platform's crates and contracts among it. */
let watched = [
  "machine",
  "Cargo.toml",
  "Cargo.lock",
  "../platform/code",
  "../platform/model/contracts.json",
]

/** One connection to the machine, kept open between the phases so each costs no handshake. */
let kept = [
  "-o",
  "BatchMode=yes",
  "-o",
  "ControlMaster=auto",
  "-o",
  // Under the home, as the system's own temporary directory is too long a path for a socket.
  "ControlPath=~/.ssh/dev-%C",
  "-o",
  "ControlPersist=120",
]

/** `local` is monoflake/machine's local machine, its sshd on port 2222 of localhost and its host
 * key made in its container, so it is not checked, as a virtual machine's tools do on localhost. */
let named =
  Base.args->Array.slice(~start=2)->Array.find(a => !(a->String.startsWith("--")))
let ssh =
  named == Some("local")
    ? [
        ...kept,
        "-p",
        "2222",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "LogLevel=ERROR",
      ]
    : kept
let reached = name => name == "local" ? "root@localhost" : name

/** A command run on the machine, its error shown, and what it wrote, or none when it failed. */
let remote = (host, command) => {
  let ran = spawnSync(
    "ssh",
    [...ssh, host, command],
    {cwd: Archive.root, stdio: ["ignore", "pipe", "inherit"], encoding: "utf8"},
  )
  ran.status->Nullable.toOption == Some(0)
    ? Some(ran.stdout->Nullable.toOption->Option.getOr("")->String.trim)
    : None
}

/** Builder in monoflake/machine owns the duration format used here. */
let timed = (name, run, said) => {
  let started = Date.now()
  let result = run()
  let took = ((Date.now() -. started) /. 1000.)->Float.toFixed(~digits=1)
  switch result {
  | Ok(value) => Console.log(`dev: ${name} ${took}s, ${said(value)}`)
  | Error(why) => Console.error(`dev: ${name} failed after ${took}s, ${why}`)
  }
  result
}

/** What a machine's driver runs, read without changing anything: a path of the local copy, the
 * channel's `current` with or without the `mac` signer the updater trusts, or a store path. The
 * signers file is the one the updater's own configuration names, monoflake/machine's
 * system/nix/update/default.nix. */
type kind = Local | Channel | Untrusted | Store
let probing = (~installed=installed, ~root=channel) =>
  `exec=$(systemctl show -p ExecStart --value ${service})
machine=$(uname -m)
case $exec in
*"path=${installed} "*) echo "local $machine" ;;
*"path=${root}/current/${Archive.package} "*)
  config=$(systemctl show -p Environment --value update-now@driver.service | tr ' ' '\\n' | sed -n 's/^MACHINE_UPDATE_CONFIG=//p')
  signers=$(sed -n 's/.*"driverSigners":"\\([^"]*\\)".*/\\1/p' "$config" 2>/dev/null)
  if [ -n "$signers" ] && grep -q '^mac ' "$signers" 2>/dev/null; then echo "channel $machine"; else echo "untrusted $machine"; fi ;;
*) echo "store $machine" ;;
esac`

let probed = host =>
  switch remote(host, probing()) {
  | None => Error(`${host} did not answer`)
  | Some(said) =>
    switch said->String.split(" ") {
    | [word, machine] =>
      switch word {
      | "local" => Ok((Local, machine))
      | "channel" => Ok((Channel, machine))
      | "untrusted" => Ok((Untrusted, machine))
      | "store" => Ok((Store, machine))
      | _ => Error(`${host} answered "${said}", which is no kind of driver`)
      }
    | _ => Error(`${host} answered "${said}", which is no kind of driver`)
    }
  }

/** The target built for the machine's architecture, as `uname -m` names it. A machine whose driver
 * runs a store path, as cloud's `switch --driver` leaves it, is refused, RFC ehm48, and so is a
 * channel machine whose updater trusts no `mac` signer, so no production machine takes a build. */
let asked = host =>
  probed(host)->Result.flatMap(((kind, machine)) =>
    switch kind {
    | Store =>
      Error(
        `${service} runs a store path, not ${installed}; a switch without --driver returns to it`,
      )
    | Untrusted =>
      Error(
        `${host} is on the driver channel but its updater trusts no mac signer, machine.update.testSigner is unset; a dev build goes to a test machine alone`,
      )
    | Local | Channel =>
      switch Archive.targets->Array.find(((_, named, _)) => named == machine) {
      | Some(target) => Ok((target, kind))
      | None => Error(`${host} is ${machine}, which no target builds`)
      }
    }
  )

/** The binary copied in last is kept beside it as `.new`, so a copy starts from it; on the
 * channel it is the stage that is kept, laid out as a version by `laid`. */
let copied = (host, kind, binary) => {
  let local = kind == Local
  let into = local ? `${installed}.new` : staged
  let prepared = local
    ? `mkdir -p ${directory} && { [ ! -f ${installed} ] || cp ${installed} ${into}; }`
    : `mkdir -p ${directory}`
  if remote(host, prepared) == None {
    Error(`${directory} not made`)
  } else if (
    !Archive.ran(
      "scp",
      ["-q", ...ssh->Array.map(a => a == "-p" ? "-P" : a), binary, `${host}:${into}`],
    )
  ) {
    Error("scp failed")
  } else if !local {
    Ok(staged)
  } else if remote(host, `chmod 755 ${into} && mv -f ${into} ${installed}`) == None {
    Error(`${installed} not renamed into place`)
  } else {
    Ok(installed)
  }
}

/** The driver restarted, then the entry where the machine runs one, each waited on until active; a
 * function so the channel's install can restart again after restoring the links. */
let restarting = `restart_all() {
  systemctl restart ${service} || return 1
  units=${service}
  if systemctl cat ${entry} > /dev/null 2>&1; then systemctl restart ${entry} || return 1; units="$units ${entry}"; fi
  for _ in $(seq 50); do
    all=1; for u in $units; do systemctl is-active --quiet "$u" || all=; done
    [ -n "$all" ] && { echo "$units"; return 0; }
    sleep 0.2
  done
  return 1
}
`
let restart = `${restarting}restart_all || exit 1
`

let restarted = host =>
  switch remote(host, restart) {
  | Some(units) => Ok(units->String.split(" ")->Array.join(" and "))
  | None => Error(`${service} or ${entry} not active, journalctl -u <unit> says why`)
  }

/** The version a dev build is laid out as, beside the updater's own. */
let labeled = version => `${version}+dev`

/** The stage laid out as `<root>/<version>` as the updater lays one out, under the updater's lock
 * file, then `current` and `previous` moved by a link made beside and renamed over, the units
 * restarted and the links restored where they do not come up. A version already current has its
 * binary renamed over and nothing else moved. */
let laid = (~root=channel, ~stage=staged, version) =>
  `${restarting}d=${root}
v=${version}
exec 9>> "$d/.update-lock" && flock -x 9 || exit 1
link() { ln -s "$2" "$d/.$1.dev.$$" && mv -T "$d/.$1.dev.$$" "$d/$1"; }
cur=$(readlink "$d/current" 2> /dev/null); cur=\${cur##*/}
prev=$(readlink "$d/previous" 2> /dev/null); prev=\${prev##*/}
work=$(mktemp -d "$d/.install.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
cp ${stage} "$work/${Archive.package}" && chmod 755 "$work" "$work/${Archive.package}" || exit 1
if [ "$cur" = "$v" ]; then
  mv -f "$work/${Archive.package}" "$d/$v/${Archive.package}" || exit 1
else
  rm -rf "$d/$v"; mv "$work" "$d/$v" || exit 1
  link current "$v" || exit 1
  if [ -n "$cur" ]; then link previous "$cur" || exit 1; fi
fi
if units=$(restart_all); then echo "$units"; exit 0; fi
if [ -n "$cur" ] && [ "$cur" != "$v" ]; then
  link current "$cur"
  if [ -n "$prev" ]; then link previous "$prev"; else rm -f "$d/previous"; fi
  restart_all > /dev/null
fi
exit 1
`

let layout = host =>
  switch Archive.version() {
  | None => Error("the version in machine/Cargo.toml was not read")
  | Some(version) =>
    let label = labeled(version)
    switch remote(host, laid(label)) {
    | Some(units) => Ok((label, units->String.split(" ")->Array.join(" and ")))
    | None => Error(`${label} not taken, journalctl -u ${service} says why`)
    }
  }

/** A call with no token refused `denied`, 403 by `answer.rs`, which proves it serves while needing
 * no token to ask. */
let answered = host => {
  let asked = `curl -s -o /dev/null -w '%{http_code}' -X POST ${address}/management/describe`
  let waited = `for _ in $(seq 50); do c=$(${asked}) && [ "$c" != 000 ] && break; sleep 0.2; done; echo "$c"`
  switch remote(host, waited) {
  | Some("403") => Ok("403")
  | Some(code) => Error(`POST /management/describe with no token answered ${code}, not 403`)
  | None => Error(`${host} did not answer`)
  }
}

let once = host => {
  let started = Date.now()
  let result =
    timed(
      "ask",
      () => asked(host),
      (((_, machine, _), kind)) => kind == Channel ? `${machine}, on the driver channel` : machine,
    )
    // The release profile, a change rebuilt in seconds, so the machine runs what a release would.
    ->Result.flatMap(((target, kind)) =>
      timed("build", () => Archive.built(target), _ => "release profile")->Result.map(binary => (
        binary,
        kind,
      ))
    )
    ->Result.flatMap(((binary, kind)) =>
      timed("copy", () => copied(host, kind, binary), path => `to ${path}`)->Result.map(_ => kind)
    )
    ->Result.flatMap(kind =>
      kind == Channel
        ? timed(
            "install",
            () => layout(host),
            ((label, units)) => `${label} current, ${units} active`,
          )->Result.map(_ => ())
        : timed("restart", () => restarted(host), units => `${units} active`)->Result.map(_ => ())
    )
    ->Result.flatMap(_ => timed("check", () => answered(host), code => `no token answered ${code}`))
  let took = ((Date.now() -. started) /. 1000.)->Float.toFixed(~digits=1)
  switch result {
  | Ok(_) => Console.log(`dev: ${host} serves the build, ${took}s in all`)
  | Error(_) => Base.process->Base.setExitCode(1)
  }
}

/** What a dry run says of the path a kind of machine takes, the build and the check the same on
 * both. */
let described = (host, kind) =>
  switch kind {
  | Channel => [
      `${host} is on the driver channel and its updater trusts a mac signer, so the build is taken as a version of the updater's layout`,
      `would scp it to ${host}:${staged}`,
      `would lay it out as ${channel}/<version>+dev under ${channel}/.update-lock, \`previous\` and \`current\` moved by a link renamed over, a later pointer overwriting it`,
      `would restart ${service} there, then ${entry} where it runs, and wait on both, the links restored if they do not come up`,
    ]
  | Untrusted => [
      `${host} is on the driver channel but its updater trusts no mac signer, machine.update.testSigner is unset, so it would be refused`,
    ]
  | Store => [`${host} runs a store path, so it would be refused`]
  | Local => [
      `${host} runs ${installed}, so the build is taken as the local copy`,
      `would scp it to ${host}:${installed}.new and rename it into place`,
      `would restart ${service} there, then ${entry} where it runs, and wait on both`,
    ]
  }

/** watchexec runs this again without `--watch`, a save during a run queued for after it. */
let watching = host =>
  Archive.ran(
    "watchexec",
    [
      // The project this repository, as the workspace's ignore holds everything under repos/.
      "--project-origin",
      ".",
      ...watched->Array.flatMap(path => ["--watch", path]),
      "--exts",
      "rs,toml,lock,json",
      "--on-busy-update",
      "queue",
      "--",
      "node",
      "scripts/dev.res.mjs",
      host,
    ],
  )

let dry = Base.args->Array.includes("--dry-run")
let watch = Base.args->Array.includes("--watch")
if isMain {
  switch named {
  | None =>
    Console.error(
      "dev: name the machine as ssh reaches it, `dev root@machine.example`, or `dev local`",
    )
    Base.process->Base.setExitCode(1)
  | Some(name) if dry =>
    let host = reached(name)
    if name == "local" {
      Console.log(`would reach the local machine as ${host} on port 2222, its host key unchecked`)
    }
    Console.log(`would ask ${host} its architecture by uname -m and what its driver runs`)
    switch probed(host) {
    | Ok((kind, _)) => described(host, kind)->Array.forEach(Console.log)
    | Error(why) =>
      Console.log(`could not tell which path it would take, ${why}`)
      Console.log(`it would take the local copy, or on the driver channel with a mac signer a version of the updater's layout`)
    }
    Console.log(`would run cargo zigbuild --release --locked -p ${Archive.package} --target <it>`)
    Console.log(`would POST ${address}/management/describe there with no token, and want 403`)
    if watch {
      Console.log(`would do it again on every save under ${watched->Array.join(", ")}`)
    }
  | Some(host) if watch =>
    if !watching(host) {
      Base.process->Base.setExitCode(1)
    }
  | Some(host) => once(reached(host))
  }
}
