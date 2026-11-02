open Asserted

@module("node:fs") external mkdtempSync: string => string = "mkdtempSync"
type removing = {recursive: bool, force: bool}
@module("node:fs") external rmSync: (string, removing) => unit = "rmSync"
@module("node:os") external tmpdir: unit => string = "tmpdir"

let recorded = Some(("0.3.7", dict{"management": 1}))
let serves = dict{"management": 1}

test("a served interface raise increments the minor and clears the patch", () => {
  deepEqual(
    Versioned.next(~manifest="0.3.7", ~last=recorded, ~serves=dict{"management": 2}),
    Some("0.4.0"),
  )
})

test("a nonbreaking change increments the patch", () => {
  deepEqual(Versioned.next(~manifest="0.3.7", ~last=recorded, ~serves), Some("0.3.8"))
})

test("the author alone changes the major", () => {
  deepEqual(Versioned.next(~manifest="2.0.0", ~last=recorded, ~serves), Some("2.0.0"))
})

test("changed inputs require a version above the last release", () => {
  ok(Versioned.checked(~manifest="0.3.7", ~last=Some("0.3.7"), ~changed=true)->Result.isError)
  deepEqual(Versioned.checked(~manifest="0.3.8", ~last=Some("0.3.7"), ~changed=true), Ok())
  deepEqual(Versioned.checked(~manifest="0.3.7", ~last=Some("0.3.7"), ~changed=false), Ok())
  ok(Versioned.checked(~manifest="0.3.6", ~last=Some("0.3.7"), ~changed=true)->Result.isError)
})

test("any manifest listing the source version suppresses another build", () => {
  let entries = [
    JSON.parseOrThrow(`{"name":"driver-machine","version":"0.3.7"}`),
    JSON.parseOrThrow(`{"name":"driver-machine","version":"0.4.0"}`),
  ]
  ok(Versioned.already(entries, "0.3.7"))
  ok(!Versioned.already(entries, "0.3.8"))
})

let release = JSON.parseOrThrow(`{"commit":"released"}`)
let last = "1111111111111111111111111111111111111111"
let now = "2222222222222222222222222222222222222222"
let pinning = commit => `ref: ${commit} # monoflake/platform@main`
let present = _ => Ok()
let unchanged = {Inputs.own: false, shared: false, unknown: []}

/** A reader of the last release's setup action, and of each platform crate at the working copy's
 * pin from the disk, as the local monoflake/platform would show it. */
let read = (~cwd, ~from, path) =>
  if cwd == Archive.root {
    ok(from == "released" && path == Inputs.setup)
    Ok(pinning(last))
  } else {
    ok(cwd == Inputs.sibling && from == now)
    Ok(Archive.readFileSync(Archive.join([cwd, path])))
  }

test("a change confined to machine's tests is no input change", () => {
  [
    "M machine/container/tests/roots.rs",
    "M machine/guide.md",
    "machine/docs/a.txt",
    "M machine/src/a_test.rs",
    "machine/src/a_test.res.mjs",
    "M machine/.gitignore",
    "machine/rustfmt.toml",
    "machine/LICENSE-MIT",
    "M machine/tests/a.rs\nM machine/object/tests/b.rs",
  ]->Array.forEach(summary => deepEqual(Inputs.carried(summary), ""))
  deepEqual(
    Inputs.carried("M machine/container/tests/roots.rs\nM machine/container/src/lib.rs"),
    "M machine/container/src/lib.rs",
  )
})

test(
  "the input comparison includes every local Rust dependency and the generated contracts",
  () => {
    let shared = Inputs.shared()->Result.getOr([])
    [
      "code/libs/codec",
      "code/libs/envelope",
      "code/tools/envelope-generator",
      "model/contracts.json",
    ]->Array.forEach(path => ok(shared->Array.includes(path)))
    [true, false]->Array.forEach(own => {
      let diff = (~cwd, ~from, ~to=?, paths) => {
        if cwd == Archive.root {
          ok(from == "released" && to == None && paths->Array.includes("machine"))
          ok(!(paths->Array.includes("Cargo.lock")))
          Ok(own ? "M machine/src/served.rs" : "")
        } else {
          ok(paths->Array.includes("code/libs/envelope"))
          Ok(own ? "" : "M code/libs/envelope/src/lib.rs")
        }
      }
      deepEqual(
        Inputs.changed(~diff, ~read, ~current=() => pinning(now), ~reach=present, release),
        Ok({own, shared: !own, unknown: []}),
      )
    })
    let diff = (~cwd as _, ~from as _, ~to as _=?, _) => Error("history could not be read")
    ok(
      Inputs.changed(
        ~diff,
        ~read,
        ~current=() => pinning(now),
        ~reach=present,
        release,
      )->Result.isError,
    )
  },
)

test("the platform is compared from the last release's pin to the working copy's", () => {
  let compared = []
  let diff = (~cwd, ~from, ~to=?, _) => {
    if cwd == Inputs.sibling {
      compared->Array.push((from, to))
    }
    Ok("")
  }
  ignore(Inputs.changed(~diff, ~read, ~current=() => pinning(now), ~reach=present, release))
  deepEqual(compared, [(last, Some(now))])
})

test("a release older than the setup action has its pin read from release.yml", () => {
  let asked = []
  let older = (~cwd, ~from, path) =>
    if cwd == Archive.root {
      ok(from == "released")
      asked->Array.push(path)
      path == Inputs.workflow ? Ok(pinning(last)) : Error(`${path} is absent at released`)
    } else {
      read(~cwd, ~from, path)
    }
  deepEqual(
    Inputs.pins(~read=older, ~current=() => pinning(now), release),
    Ok(("released", last, now)),
  )
  deepEqual(asked, [Inputs.setup, Inputs.workflow])
  let compared = []
  let diff = (~cwd, ~from, ~to=?, _) => {
    if cwd == Inputs.sibling {
      compared->Array.push((from, to))
    }
    Ok("")
  }
  ignore(Inputs.changed(~diff, ~read=older, ~current=() => pinning(now), ~reach=present, release))
  deepEqual(compared, [(last, Some(now))])
  let neither = (~cwd as _, ~from as _, path) => Error(`${path} is absent at released`)
  ok(Inputs.pins(~read=neither, ~current=() => pinning(now), release)->Result.isError)
  let unpinned = (~cwd as _, ~from as _, path) =>
    path == Inputs.setup ? Ok("name: setup\n") : Ok(pinning(last))
  deepEqual(
    Inputs.pins(~read=unpinned, ~current=() => pinning(now), release),
    Error("the last release pins no platform commit"),
  )
  deepEqual(
    Inputs.pins(~read, ~current=() => "name: setup\n", release),
    Error(`${Inputs.setup} pins no platform commit`),
  )
  ok(Inputs.platform(Inputs.current())->Option.isSome)
})

test("inputs unchanged since the last release compare as unchanged", () => {
  let diff = (~cwd as _, ~from as _, ~to as _=?, _) => Ok("")
  deepEqual(
    Inputs.changed(~diff, ~read, ~current=() => pinning(now), ~reach=present, release),
    Ok(unchanged),
  )
  let diff = (~cwd, ~from as _, ~to as _=?, _) => {
    ok(cwd == Archive.root)
    Ok("")
  }
  let reach = _ => {
    ok(false, ~message="no platform history is needed where the pins are equal")
    Ok()
  }
  deepEqual(
    Inputs.changed(~diff, ~read, ~current=() => pinning(last), ~reach, release),
    Ok(unchanged),
  )
})

@get external exitCode: Base.process => Nullable.t<int> = "exitCode"

/** Each line `run` printed, to stdout or stderr. */
let printed: (unit => unit) => array<string> = %raw(`function (run) {
  const seen = [], log = console.log, error = console.error
  console.log = (...said) => seen.push(said.join(" "))
  console.error = (...said) => seen.push(said.join(" "))
  try { run() } finally { console.log = log; console.error = error }
  return seen
}`)

/** What `run` leaves the exit code at, `Base.process`'s reset to 0 before and after. */
let exited = run => {
  Base.process->Base.setExitCode(0)
  run()
  let code = exitCode(Base.process)->Nullable.toOption->Option.getOr(0)
  Base.process->Base.setExitCode(0)
  code
}

test("a lookup that fails is warned of and passes, in CI or not", () => {
  let environment = Archive.env->Dict.copy
  let workspace = mkdtempSync(Archive.join([tmpdir(), "workspace-"]))
  after(() => rmSync(workspace, {recursive: true, force: true}))
  Archive.mkdirSync(Archive.join([workspace, "scripts", "release"]), {recursive: true})
  Versioned.writeFileSync(
    Archive.join([workspace, "scripts", "release", "release.res.mjs"]),
    "process.exit(1)\n",
  )
  Archive.env->Dict.set("WORKSPACE", workspace)
  let manifest = Archive.readFileSync(Archive.join([Archive.root, "machine", "Cargo.toml"]))
  [None, Some("true")]->Array.forEach(value => {
    switch value {
    | Some(value) => Archive.env->Dict.set("CI", value)
    | None => Archive.env->Dict.delete("CI")
    }
    deepEqual(exited(() => Verify.guard()), 0)
  })
  deepEqual(Archive.readFileSync(Archive.join([Archive.root, "machine", "Cargo.toml"])), manifest)
  ["WORKSPACE", "CI"]->Array.forEach(name =>
    switch environment->Dict.get(name) {
    | Some(value) => Archive.env->Dict.set(name, value)
    | None => Archive.env->Dict.delete(name)
    }
  )
})

test("a pin the local platform lacks is fetched once, then read", () => {
  let fetches = ref(0)
  let held = ref([last])
  let holds = (~cwd, commit) => {
    ok(cwd == Inputs.sibling)
    held.contents->Array.includes(commit)
  }
  let fetch = (~cwd as _) => {
    fetches := fetches.contents + 1
    held := [last, now]
    Ok("")
  }
  deepEqual(Inputs.reached(~holds, ~fetch, [last, now]), Ok())
  deepEqual(fetches.contents, 1)
  deepEqual(Inputs.reached(~holds, ~fetch, [last, now]), Ok())
  deepEqual(fetches.contents, 1)
  held := [last]
  let fetch = (~cwd as _) => {
    fetches := fetches.contents + 1
    Ok("")
  }
  deepEqual(Inputs.reached(~holds, ~fetch, [last, now]), Error([now]))
  deepEqual(fetches.contents, 2)
  let diff = (~cwd, ~from as _, ~to as _=?, _) => {
    ok(cwd == Archive.root, ~message="the platform is not diffed without its commits")
    Ok("")
  }
  deepEqual(
    Inputs.changed(~diff, ~read, ~current=() => pinning(now), ~reach=_ => Error([now]), release),
    Ok({own: false, shared: false, unknown: [now]}),
  )
})

test("with a pin still missing, verify warns and passes", () => {
  let compare = _ => Ok({Inputs.own: false, shared: false, unknown: [now]})
  let version = Archive.version()->Option.getOr("")
  let listed = () => Ok([
    JSON.parseOrThrow(`{"name":"driver-machine","version":"${version}","commit":"released"}`),
  ])
  let code = ref(1)
  let lines = printed(() => code := exited(() => Verify.guard(~listed, ~compare, ())))
  deepEqual(code.contents, 0)
  deepEqual(
    lines,
    [
      `built: warning: monoflake/platform lacks ${now} even after a fetch, so its change since the last release was not checked; fetch platform and run again`,
    ],
  )
  let compare = _ => Ok({Inputs.own: true, shared: false, unknown: [now]})
  deepEqual(exited(() => Verify.guard(~listed, ~compare, ())), 1)
})

test("release membership delegates the name and version and keeps lookup errors", () => {
  let before = Archive.env->Dict.get("WORKSPACE")
  let workspace = mkdtempSync(Archive.join([tmpdir(), "holds-"]))
  after(() => rmSync(workspace, {recursive: true, force: true}))
  Archive.mkdirSync(Archive.join([workspace, "scripts", "release"]), {recursive: true})
  let script = Archive.join([workspace, "scripts", "release", "release.res.mjs"])
  Archive.env->Dict.set("WORKSPACE", workspace)
  [(0, Ok(true)), (2, Ok(false)), (1, Error(`${script} holds failed`))]->Array.forEach(((
    code,
    expected,
  )) => {
    Versioned.writeFileSync(
      script,
      `if (process.argv.slice(2, 5).join(' ') !== 'holds driver-machine 0.3.7') process.exit(99); process.exit(${code->Int.toString});`,
    )
    deepEqual(Versioned.holds("0.3.7"), expected)
  })
  switch before {
  | Some(value) => Archive.env->Dict.set("WORKSPACE", value)
  | None => Archive.env->Dict.delete("WORKSPACE")
  }
})
