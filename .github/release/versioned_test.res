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

test("both Conventional Commits breaking signals increment the minor", () => {
  [
    "feat!: change the format",
    "fix(machine)!: change the format",
    "fix: change\n\nBREAKING CHANGE: old data is refused",
  ]->Array.forEach(message => {
    ok(Versioned.breaking(message))
    deepEqual(
      Versioned.bumped(
        ~manifest="0.3.7",
        ~last=recorded,
        ~serves,
        ~messages=[message],
        ~changed=true,
      ),
      Some("0.4.0"),
    )
  })
  ok(!Versioned.breaking("fix: mention a BREAKING CHANGE: in prose"))
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

/** A reader of the last release's workflow, and of each platform crate at the working copy's pin
 * from the disk, as the local monoflake/platform would show it. */
let read = (~cwd, ~from, path) =>
  if cwd == Archive.root {
    ok(from == "released" && path == Inputs.workflow)
    Ok(pinning(last))
  } else {
    ok(cwd == Inputs.sibling && from == now)
    Ok(Archive.readFileSync(Archive.join([cwd, path])))
  }

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
          ok(from == "released" && to == None && paths->Array.includes("Cargo.lock"))
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
  let logged = []
  let log = (~cwd, ~from, ~to=?, _) => {
    logged->Array.push((cwd == Inputs.sibling, from, to))
    Ok([])
  }
  ignore(Inputs.breakingSince(~log, ~read, ~current=() => pinning(now), ~reach=present, release))
  deepEqual(logged, [(false, "released", None), (true, last, Some(now))])
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

test("bump keeps a version raised by hand and never lowers one", () => {
  let bumped = (manifest, messages) =>
    Versioned.bumped(~manifest, ~last=recorded, ~serves, ~messages, ~changed=true)
  deepEqual(bumped("0.5.0", []), Some("0.5.0"))
  deepEqual(bumped("0.3.9", []), Some("0.3.9"))
  deepEqual(bumped("0.3.8", ["feat!: change the format"]), Some("0.4.0"))
  deepEqual(bumped("0.4.0", ["feat!: change the format"]), Some("0.4.0"))
  deepEqual(bumped("0.3.7", []), Some("0.3.8"))
})

test("bump writes nothing new where no input changed since the last release", () => {
  deepEqual(
    Versioned.bumped(
      ~manifest="0.3.7",
      ~last=recorded,
      ~serves=dict{"management": 2},
      ~messages=["feat!: change the format"],
      ~changed=false,
    ),
    Some("0.3.7"),
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
    deepEqual(exited(() => Bump.main()), 0)
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

test("with a pin still missing, bump raises the patch and verify warns and passes", () => {
  let entry = JSON.parseOrThrow(`{"name":"driver-machine","version":"0.3.7","commit":"released"}`)
  let compare = _ => Ok({Inputs.own: false, shared: false, unknown: [now]})
  let reached = ref(Ok())
  let breaking = (~reach, _) => {
    reached := reach([last, now])
    Ok({Inputs.messages: ["fix: a"], unread: [now]})
  }
  deepEqual(Bump.since(~compare, ~breaking, entry), Ok((true, ["fix: a"])))
  deepEqual(reached.contents, Error([now]))
  deepEqual(
    Versioned.bumped(
      ~manifest="0.3.7",
      ~last=recorded,
      ~serves,
      ~messages=["fix: a"],
      ~changed=true,
    ),
    Some("0.3.8"),
  )
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

test("each commit's message since a release is read apart, in jj and in git alike", () => {
  let messages = ["feat!: change the format", "fix: change\n\nBREAKING CHANGE: refused", "fix: a"]
  let made = (init, commit, head) => {
    let cwd = mkdtempSync(Archive.join([tmpdir(), "inputs-"]))
    after(() => rmSync(cwd, {recursive: true, force: true}))
    let run = ((command, args)) => Inputs.output(~cwd, command, args)
    let write = (path, text) => Versioned.writeFileSync(Archive.join([cwd, path]), text)
    ok(run(init)->Result.isOk)
    write("a", "0")
    ok(run(commit("chore: before"))->Result.isOk)
    let from = run(head)
    let middle = ref(Error("not made"))
    messages->Array.forEachWithIndex((message, index) => {
      write("a", Int.toString(index + 1))
      ok(run(commit(message))->Result.isOk)
      if index == 1 {
        middle := run(head)
      }
    })
    write("b", "elsewhere")
    ok(run(commit("feat!: touches another path"))->Result.isOk)
    let to = middle.contents->Result.getOr("")
    deepEqual(
      from->Result.flatMap(from => Inputs.messages(~cwd, ~from, ~to, ["a"])),
      Ok(["fix: change\n\nBREAKING CHANGE: refused", "feat!: change the format"]),
    )
    from->Result.flatMap(from => Inputs.messages(~cwd, ~from, ["a"]))
  }
  let config = mkdtempSync(Archive.join([tmpdir(), "jj-"]))
  after(() => rmSync(config, {recursive: true, force: true}))
  Archive.env->Dict.set("JJ_CONFIG", config)
  Archive.env->Dict.set("JJ_USER", "test")
  Archive.env->Dict.set("JJ_EMAIL", "test@example.com")
  let jj = made(
    ("jj", ["git", "init"]),
    message => ("jj", ["commit", "--message", message]),
    ("jj", ["log", "--no-graph", "--revisions", "@-", "--template", "commit_id"]),
  )
  let git = made(
    ("git", ["init", "--quiet"]),
    message => (
      "sh",
      [
        "-c",
        `git add -A && git -c user.name=test -c user.email=t@example.com commit -qm "$0"`,
        message,
      ],
    ),
    ("git", ["rev-parse", "HEAD"]),
  )
  [jj, git]->Array.forEach(read => {
    let sorted = list => list->Array.toSorted(String.compare)
    deepEqual(read->Result.map(sorted), Ok(sorted(messages)))
    ok(read->Result.getOr([])->Array.filter(Versioned.breaking)->Array.length == 2)
  })
})

test("bump stops at a refusal and says nothing after it", () => {
  let version = Archive.version()->Option.getOr("")
  let listed = () => Ok([
    JSON.parseOrThrow(`{"name":"driver-machine","version":"${version}","commit":"released"}`),
  ])
  let since = _ => Ok((true, []))
  let write = (~manifest as _, _) => Error("Cargo.lock could not be synchronized")
  let code = ref(0)
  let lines = printed(() => code := exited(() => Bump.main(~listed, ~since, ~write, ())))
  deepEqual(code.contents, 1)
  deepEqual(lines, ["built: Cargo.lock could not be synchronized"])
  let write = (~manifest as _, _) => Ok()
  let lines = printed(() => code := exited(() => Bump.main(~listed, ~since, ~write, ())))
  deepEqual(code.contents, 0)
  ok(
    lines->Array.length == 1 &&
      lines->Array.getUnsafe(0)->String.startsWith(`driver-machine ${version} -> `),
  )
})
