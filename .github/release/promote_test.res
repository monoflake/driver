open Asserted

@module("node:fs") external mkdtempSync: string => string = "mkdtempSync"
@module("node:os") external tmpdir: unit => string = "tmpdir"

let commit = "1111111111111111111111111111111111111111"
let pin = "2222222222222222222222222222222222222222"
let repository = "example/driver"
let version = "0.3.7"
let machines = ["x86_64", "aarch64"]
let name = machine => `driver-machine-${version}-linux-${machine}.tar.gz`
let bytes = machine => `tested archive ${machine}\n`
let run = (
  ~path=".github/workflows/build.yml",
  ~status="completed",
  ~conclusion="success",
  ~owner=repository,
  ~sha=commit,
  (),
) =>
  JSON.Encode.object(
    dict{
      "path": JSON.Encode.string(path),
      "status": JSON.Encode.string(status),
      "conclusion": JSON.Encode.string(conclusion),
      "head_sha": JSON.Encode.string(sha),
      "head_repository": JSON.Encode.object(dict{"full_name": JSON.Encode.string(owner)}),
    },
  )

let temporary = () => {
  let directory = mkdtempSync(Archive.join([tmpdir(), "promote-"]))
  after(() => Archive.rmSync(directory, {recursive: true, force: true}))
  directory
}

let archives = directory => {
  machines->Array.forEach(machine =>
    Versioned.writeFileSync(Archive.join([directory, name(machine)]), bytes(machine))
  )
  machines
  ->Array.map(machine => (machine, Versioned.sha256(Archive.join([directory, name(machine)]))))
  ->Dict.fromArray
}

test("only a successful build workflow in the source repository can be promoted", () => {
  deepEqual(Promote.selected(~repository, run()), Ok(commit))
  [
    run(~path=".github/workflows/release.yml", ()),
    run(~status="in_progress", ()),
    run(~conclusion="failure", ()),
    run(~conclusion="cancelled", ()),
    run(~owner="example/other", ()),
    run(~sha="main", ()),
    JSON.parseOrThrow("{}"),
  ]->Array.forEach(value => ok(Promote.selected(~repository, value)->Result.isError))
})

test("metadata comes from the build source and its pinned platform", () => {
  let read = path =>
    switch path {
    | "machine/Cargo.toml" => Ok("[package]\nname = \"driver-machine\"\nversion = \"0.3.7\"\n")
    | "machine/src/served.rs" => Ok(`const SERVED: &str = "management, deployments";`)
    | "model/contracts.json" =>
      Ok(`{"interfaces":{"management":{"version":2},"deployments":{"version":3}}}`)
    | _ => Error("unexpected source path")
    }
  deepEqual(
    Promote.metadata(~read, commit),
    Ok({Promote.commit, version, serves: dict{"management": 2, "deployments": 3}}),
  )
  ["0.0.0", "1.2", "../0.3.7"]->Array.forEach(version => {
    let read = _ => Ok(`[package]\nversion = "${version}"\n`)
    ok(Promote.metadata(~read, commit)->Result.isError)
  })
  ok(Promote.metadata(~read=_ => Error("missing source"), commit)->Result.isError)
  ok(Promote.json("{")->Result.isError)
})

test("both actual archive digests must match the recorded hashes", () => {
  let directory = temporary()
  let hashes = archives(directory)
  deepEqual(Promote.checked(~directory, ~version, ~hashes, ()), Ok())
  let uppercase = hashes->Dict.mapValues(String.toUpperCase)
  deepEqual(Promote.checked(~directory, ~version, ~hashes=uppercase, ()), Ok())
  machines->Array.forEach(machine => {
    let changed = hashes->Dict.copy
    changed->Dict.set(machine, String.repeat("0", 64))
    ok(Promote.checked(~directory, ~version, ~hashes=changed, ())->Result.isError)
    ["", "invalid", String.repeat("0", 63)]->Array.forEach(
      value => {
        changed->Dict.set(machine, value)
        ok(Promote.checked(~directory, ~version, ~hashes=changed, ())->Result.isError)
      },
    )
    changed->Dict.delete(machine)
    ok(Promote.checked(~directory, ~version, ~hashes=changed, ())->Result.isError)
  })
  Versioned.writeFileSync(Archive.join([directory, name("aarch64")]), "changed after testing")
  ok(Promote.checked(~directory, ~version, ~hashes, ())->Result.isError)
})

test("missing extra and differently versioned archive files are refused", () => {
  let directory = temporary()
  let hashes = archives(directory)
  [
    [],
    [name("x86_64")],
    [name("x86_64"), name("aarch64"), "extra.tar.gz"],
    [name("x86_64"), "driver-machine-0.3.8-linux-aarch64.tar.gz"],
  ]->Array.forEach(found =>
    ok(Promote.checked(~directory, ~version, ~hashes, ~files=_ => found, ())->Result.isError)
  )
})

let fixture = () => {
  let directory = temporary()
  let hashes = archives(directory)
  let calls = []
  let execute = (command, args) => {
    calls->Array.push((command, args))
    deepEqual(command, "gh")
    switch args {
    | ["api", "repos/example/driver/actions/runs/123"] => Ok(JSON.stringify(run()))
    | ["api", path] if path == `repos/${repository}/compare/main...${commit}` =>
      Ok(`{"status":"behind"}`)
    | ["api", path, "-H", "Accept: application/vnd.github.raw+json"] =>
      if path == `repos/${repository}/contents/${Inputs.setup}?ref=${commit}` {
        Ok(`ref: ${pin} # monoflake/platform`)
      } else if path == `repos/${repository}/contents/machine/Cargo.toml?ref=${commit}` {
        Ok(`[package]\nversion = "${version}"\n`)
      } else if path == `repos/${repository}/contents/machine/src/served.rs?ref=${commit}` {
        Ok(`const SERVED: &str = "management";`)
      } else if path == `repos/monoflake/platform/contents/model/contracts.json?ref=${pin}` {
        Ok(`{"interfaces":{"management":{"version":2}}}`)
      } else {
        Error("unexpected source request")
      }
    | [
        "run",
        "download",
        "123",
        "--repo",
        "example/driver",
        "--name",
        "driver-machine",
        "--dir",
        download,
      ] =>
      deepEqual(download, Archive.join([directory, "download"]))
      ignore(archives(download))
      Ok("")
    | _ => Error("unexpected command")
    }
  }
  (directory, hashes, calls, execute)
}

test("promotion downloads the given run and publishes the same bytes with source metadata", () => {
  let (directory, hashes, calls, execute) = fixture()
  let source = Promote.prepare(~run="123", ~repository, ~hashes, ~execute, ~directory, ())
  deepEqual(source, Ok({Promote.commit, version, serves: dict{"management": 2}}))
  deepEqual(calls->Array.length, 7)
  let {Promote.commit: commit, version, serves} =
    source->Result.getOr({commit: "", version: "", serves: Dict.make()})
  let root = temporary()
  let staged = Archive.join([root, "target", "archives"])
  Archive.mkdirSync(staged, {recursive: true})
  machines->Array.forEach(machine =>
    Archive.copyFileSync(
      Archive.join([directory, name(machine)]),
      Archive.join([staged, name(machine)]),
    )
  )
  let written = ref(None)
  Versioned.main(
    ~root,
    ~manifest=Some(version),
    ~commit,
    ~serves=() => serves,
    ~listed=() => Ok([]),
    ~holds=_ => Ok(false),
    ~write=document => written := Some(document),
    (),
  )
  let artifact =
    written.contents
    ->Option.flatMap(document => document->Versioned.field("artifacts"))
    ->Option.flatMap(JSON.Decode.array)
    ->Option.flatMap(entries => entries->Array.get(0))
    ->Option.getOr(JSON.Encode.null)
  deepEqual(artifact->Versioned.text("commit"), Some(commit))
  deepEqual(artifact->Versioned.text("version"), Some(version))
  deepEqual(
    artifact->Versioned.field("interfaces"),
    Some(JSON.Encode.object(dict{"management": JSON.Encode.int(2)})),
  )
  machines->Array.forEach(machine => {
    let path = Archive.join([staged, "release", name(machine)])
    deepEqual(Archive.readFileSync(path), bytes(machine))
    deepEqual(Versioned.sha256(path), hashes->Dict.get(machine)->Option.getOr(""))
  })
  let assets =
    artifact->Versioned.field("assets")->Option.flatMap(JSON.Decode.array)->Option.getOr([])
  deepEqual(assets->Array.length, 2)
  assets->Array.forEach(asset => {
    let path = asset->Versioned.text("path")->Option.getOr("")
    ok(path->String.startsWith("target/archives/release/"))
    ok(Versioned.existsSync(Archive.join([root, path])))
    deepEqual(asset->Versioned.text("kind"), Some("binary"))
  })
})

test("invalid run ids fail before any command", () => {
  ["", "0", "-1", "1.5", "123; exit 0", " 123"]->Array.forEach(run => {
    let execute = (_, _) => {
      ok(false, ~message="an invalid run must not execute a command")
      Error("unexpected command")
    }
    ok(Promote.prepare(~run, ~repository, ~hashes=Dict.make(), ~execute, ())->Result.isError)
  })
})

test("a version already released keeps the release manifest empty", () => {
  let root = temporary()
  let written = ref(None)
  Versioned.main(
    ~root,
    ~manifest=Some(version),
    ~commit,
    ~serves=() => {
      ok(false, ~message="the served interfaces are not read where nothing is released")
      Dict.make()
    },
    ~listed=() => Ok([]),
    ~holds=selected => {
      deepEqual(selected, version)
      Ok(true)
    },
    ~write=document => written := Some(document),
    (),
  )
  deepEqual(written.contents, Some(JSON.Encode.object(dict{"artifacts": JSON.Encode.array([])})))
  ok(!Versioned.existsSync(Archive.join([root, "target", "archives", "release"])))
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

let listing = (~x86_64, ~aarch64) => {
  let entry = (version, x86_64, aarch64) =>
    JSON.parseOrThrow(
      `{"name":"driver-machine","version":"${version}","assets":[{"target":"linux-x86_64","sha256":"${x86_64}"},{"target":"linux-aarch64","sha256":"${aarch64}"}]}`,
    )
  [entry(version, x86_64, aarch64)]
}

let released = (~entries, ~recorded) => {
  let root = temporary()
  let written = ref(None)
  let lines = ref([])
  let code = ref(0)
  Base.process->Base.setExitCode(0)
  let output = printed(() =>
    Versioned.main(
      ~root,
      ~manifest=Some(version),
      ~commit,
      ~serves=() => Dict.make(),
      ~recorded?,
      ~listed=() => Ok(entries),
      ~holds=_ => Ok(true),
      ~write=document => written := Some(document),
      (),
    )
  )
  lines := output
  code := exitCode(Base.process)->Nullable.toOption->Option.getOr(0)
  Base.process->Base.setExitCode(0)
  (code.contents, lines.contents, written.contents)
}

test("a released version passes only where the released hashes are the recorded ones", () => {
  let hashes = dict{"x86_64": String.repeat("a", 64), "aarch64": String.repeat("b", 64)}
  let same = listing(~x86_64=String.repeat("a", 64), ~aarch64=String.repeat("B", 64))
  let (code, lines, written) = released(~entries=same, ~recorded=Some(hashes))
  deepEqual(code, 0)
  ok(lines->Array.some(line => line->String.includes("is released already")))
  deepEqual(written, Some(JSON.Encode.object(dict{"artifacts": JSON.Encode.array([])})))
  let other = listing(~x86_64=String.repeat("a", 64), ~aarch64=String.repeat("c", 64))
  let (code, lines, written) = released(~entries=other, ~recorded=Some(hashes))
  deepEqual(code, 1)
  ok(lines->Array.some(line => line->String.includes(String.repeat("c", 64))))
  ok(lines->Array.some(line => line->String.includes(String.repeat("b", 64))))
  deepEqual(written, None)
  let (code, _, _) = released(~entries=[], ~recorded=Some(hashes))
  deepEqual(code, 1)
})

test("an older version is refused after a newer one is released", () => {
  let root = temporary()
  let attempt = (~last) => {
    let written = ref(None)
    Base.process->Base.setExitCode(0)
    let lines = printed(() =>
      Versioned.main(
        ~root,
        ~manifest=Some(version),
        ~commit,
        ~serves=() => Dict.make(),
        ~listed=() => Ok([
          JSON.parseOrThrow(`{"name":"driver-machine","version":"${last}","release":"r"}`),
        ]),
        ~holds=_ => Ok(false),
        ~write=document => written := Some(document),
        (),
      )
    )
    let code = exitCode(Base.process)->Nullable.toOption->Option.getOr(0)
    Base.process->Base.setExitCode(0)
    (code, lines, written.contents)
  }
  let (code, lines, written) = attempt(~last="0.3.8")
  deepEqual(code, 1)
  ok(lines->Array.some(line => line->String.includes("0.3.8")))
  deepEqual(written, None)
  let (code, _, _) = attempt(~last="0.10.0")
  deepEqual(code, 1)
})

test("a build source not on main is refused after the run is read", () => {
  [`{"status":"ahead"}`, `{"status":"diverged"}`, "{}"]->Array.forEach(status => {
    let (directory, hashes, calls, execute) = fixture()
    let comparing = (command, args) =>
      switch args {
      | ["api", path] if path->String.includes("/compare/") => Ok(status)
      | _ => execute(command, args)
      }
    ok(
      Promote.prepare(
        ~run="123",
        ~repository,
        ~hashes,
        ~execute=comparing,
        ~directory,
        (),
      )->Result.isError,
    )
    ok(calls->Array.every(((_, args)) => args->Array.get(0) != Some("run")))
  })
  deepEqual(Promote.merged(~commit, JSON.parseOrThrow(`{"status":"identical"}`)), Ok(commit))
})

test("API source and download failures stop promotion", () => {
  for failure in 1 to 7 {
    let (directory, hashes, calls, execute) = fixture()
    let attempt = ref(0)
    let failing = (command, args) => {
      attempt := attempt.contents + 1
      attempt.contents == failure ? Error("injected failure") : execute(command, args)
    }
    deepEqual(
      Promote.prepare(~run="123", ~repository, ~hashes, ~execute=failing, ~directory, ()),
      Error("injected failure"),
    )
    deepEqual(calls->Array.length, failure - 1)
  }
})

test("a hash mismatch copies neither downloaded archive into the release inputs", () => {
  let (directory, hashes, _, execute) = fixture()
  hashes->Dict.set("aarch64", String.repeat("0", 64))
  machines->Array.forEach(machine =>
    Versioned.writeFileSync(Archive.join([directory, name(machine)]), "previous input")
  )
  ok(Promote.prepare(~run="123", ~repository, ~hashes, ~execute, ~directory, ())->Result.isError)
  machines->Array.forEach(machine =>
    deepEqual(Archive.readFileSync(Archive.join([directory, name(machine)])), "previous input")
  )
})

test("release dispatch requires the run and hashes and invokes promotion before publishing", () => {
  let workflow = Archive.readFileSync(Archive.join([Archive.root, ".github/workflows/release.yml"]))
  ok(workflow->String.includes("  workflow_dispatch:\n"))
  ok(!(workflow->String.includes("  push:")))
  ok(!(workflow->String.includes("  schedule:")))
  ["run", "sha256_x86_64", "sha256_aarch64"]->Array.forEach(input => {
    let declaration = RegExp.fromString(
      `${input}:\\n        description: [^\\n]+\\n        required: true\\n        type: string`,
    )
    ok(RegExp.test(declaration, workflow))
    ok(workflow->String.includes(`\u0024{{ inputs.${input} }}`))
  })
  ok(workflow->String.includes("  actions: read"))
  ok(workflow->String.includes("node .github/release/promote.res.mjs"))
  ok(workflow->String.includes("run: mise run release"))
  ok(workflow->String.includes("if: steps.promote.outputs.ready == 'true'"))
  ok(workflow->String.includes("if: steps.promote.outputs.ready != 'true'"))
  ok(workflow->String.includes("release.res.mjs\" notes"))
  ok(!(workflow->String.includes("mise run archive")))
  ok(!(workflow->String.includes("mise run ready")))
  ok(!(workflow->String.includes("mise run versioned")))
  ok(!(workflow->String.includes("rust-cache")))
})
