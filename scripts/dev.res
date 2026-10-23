/***
 * driver-machine built for a test machine's architecture, copied in, restarted and asked, RFC
 * n0o4l; each phase is timed, and `--watch` does it again on every save.
 */

type spawned = {status: Nullable.t<int>, stdout: Nullable.t<string>}
type spawnOptions = {cwd: string, stdio: array<string>, encoding: string}
@module("node:child_process")
external spawnSync: (string, array<string>, spawnOptions) => spawned = "spawnSync"
@val external isMain: bool = "import.meta.main"

let directory = "/var/lib/driver-machine/dev"
let installed = `${directory}/${Archive.package}`
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

/** A phase run and its time printed, beside what `said` makes of its value or why it failed. */
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

/** The target built for the machine's architecture, as `uname -m` names it; the binary copied in
 * last is kept beside it as `.new`, so rsync sends only what changed. A machine whose driver runs
 * a store path, as cloud's `switch --driver` leaves it, is refused, RFC ehm48. */
let asked = host =>
  switch remote(
    host,
    `systemctl show -p ExecStart --value ${service} | grep -qF "path=${installed} " || { echo store; exit; }
uname -m && mkdir -p ${directory} && { [ ! -f ${installed} ] || cp ${installed} ${installed}.new; }`,
  ) {
  | None => Error(`${host} did not answer`)
  | Some("store") =>
    Error(`${service} runs a store path, not ${installed}; a switch without --driver returns to it`)
  | Some(machine) =>
    switch Archive.targets->Array.find(((_, named, _)) => named == machine) {
    | Some(target) => Ok(target)
    | None => Error(`${host} is ${machine}, which no target builds`)
    }
  }

let copied = (host, binary) =>
  if (
    !Archive.ran(
      "rsync",
      ["-tz", "-e", ["ssh", ...ssh]->Array.join(" "), binary, `${host}:${installed}.new`],
    )
  ) {
    Error("rsync failed")
  } else if (
    remote(host, `chmod 755 ${installed}.new && mv -f ${installed}.new ${installed}`) == None
  ) {
    Error(`${installed} not renamed into place`)
  } else {
    Ok(installed)
  }

/** The driver restarted on the binary copied in, then the entry where the machine runs one, each
 * waited on until active. */
let restart = `systemctl restart ${service} || exit 1
units=${service}
if systemctl cat ${entry} > /dev/null 2>&1; then systemctl restart ${entry} || exit 1; units="$units ${entry}"; fi
for _ in $(seq 50); do
  all=1; for u in $units; do systemctl is-active --quiet "$u" || all=; done
  [ -n "$all" ] && { echo "$units"; exit; }
  sleep 0.2
done
exit 1
`

let restarted = host =>
  switch remote(host, restart) {
  | Some(units) => Ok(units->String.split(" ")->Array.join(" and "))
  | None => Error(`${service} or ${entry} not active, journalctl -u <unit> says why`)
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
    timed("ask", () => asked(host), ((_, machine, _)) => machine)
    // The release profile, a change rebuilt in seconds, so the machine runs what a release would.
    ->Result.flatMap(target => timed("build", () => Archive.built(target), _ => "release profile"))
    ->Result.flatMap(binary => timed("copy", () => copied(host, binary), path => `to ${path}`))
    ->Result.flatMap(_ => timed("restart", () => restarted(host), units => `${units} active`))
    ->Result.flatMap(_ => timed("check", () => answered(host), code => `no token answered ${code}`))
  let took = ((Date.now() -. started) /. 1000.)->Float.toFixed(~digits=1)
  switch result {
  | Ok(_) => Console.log(`dev: ${host} serves the build, ${took}s in all`)
  | Error(_) => Base.process->Base.setExitCode(1)
  }
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
    Console.error("dev: name the machine as ssh reaches it, `dev root@buf`, or `dev local`")
    Base.process->Base.setExitCode(1)
  | Some(name) if dry =>
    let host = reached(name)
    if name == "local" {
      Console.log(`would reach the local machine as ${host} on port 2222, its host key unchecked`)
    }
    Console.log(`would ask ${host} its architecture by uname -m, refusing a driver on a store path`)
    Console.log(`would run cargo zigbuild --release --locked -p ${Archive.package} --target <it>`)
    Console.log(`would rsync it to ${host}:${installed}.new and rename it into place`)
    Console.log(`would restart ${service} there, then ${entry} where it runs, and wait on both`)
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
