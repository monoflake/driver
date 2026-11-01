@module("node:fs") external readdirSync: string => array<string> = "readdirSync"
@module("node:fs") external appendFileSync: (string, string) => unit = "appendFileSync"

type source = {commit: string, version: string, serves: dict<int>}

let output = (command, args) => {
  let result = Versioned.capture(
    command,
    args,
    {
      cwd: Archive.root,
      encoding: "utf8",
      maxBuffer: 67108864,
    },
  )
  result.status->Nullable.toOption == Some(0)
    ? Ok(result.stdout->Nullable.toOption->Option.getOr(""))
    : Error(`${command} failed ${result.stderr->Nullable.toOption->Option.getOr("")->String.trim}`)
}

let json = text =>
  switch JSON.parseOrThrow(text) {
  | value => Ok(value)
  | exception JsExn(_) => Error("the build run returned invalid JSON")
  }

let selected = (~repository, run) => {
  let commit = run->Versioned.text("head_sha")->Option.getOr("")
  let owner =
    run
    ->Versioned.field("head_repository")
    ->Option.flatMap(value => value->Versioned.text("full_name"))
  if run->Versioned.text("path") != Some(".github/workflows/build.yml") {
    Error("the selected run is not build.yml")
  } else if (
    run->Versioned.text("status") != Some("completed") ||
      run->Versioned.text("conclusion") != Some("success")
  ) {
    Error("the selected build run did not complete successfully")
  } else if owner != Some(repository) || !RegExp.test(/^[a-f0-9]{40}$/, commit) {
    Error("the selected build run has no source commit in this repository")
  } else {
    Ok(commit)
  }
}

/** A source commit is on main where main is at it or ahead of it. */
let merged = (~commit, comparison) =>
  switch comparison->Versioned.text("status") {
  | Some("identical" | "behind") => Ok(commit)
  | _ => Error(`the build source ${commit} is not on main`)
  }

let metadata = (~read, commit) =>
  read("machine/Cargo.toml")->Result.flatMap(manifest => {
    let package =
      manifest
      ->String.split("[package]")
      ->Array.get(1)
      ->Option.getOr("")
      ->String.split("\n[")
      ->Array.get(0)
      ->Option.getOr("")
    let version =
      /^version\s*=\s*"([^"]+)"/m
      ->RegExp.exec(package)
      ->Option.flatMap(found => found->RegExp.Result.matches->Array.get(0)->Option.flatMap(x => x))
    switch version {
    | Some(version) if Versioned.numbers(version)->Option.isSome && version != "0.0.0" =>
      read("machine/src/served.rs")->Result.flatMap(source =>
        read("model/contracts.json")->Result.flatMap(
          contracts =>
            json(contracts)->Result.map(
              contracts => {
                commit,
                version,
                serves: Versioned.interfaces(~source, ~contracts),
              },
            ),
        )
      )
    | _ => Error("the build source needs a version above 0.0.0")
    }
  })

let checked = (~directory, ~version, ~hashes, ~files=readdirSync, ~digest=Versioned.sha256, ()) => {
  let expected =
    Archive.targets->Array.map(((_, machine, _)) => (
      machine,
      `${Archive.package}-${version}-linux-${machine}.tar.gz`,
    ))
  let names = expected->Array.map(((_, name)) => name)
  let found = files(directory)
  if found->Array.toSorted(String.compare) != names->Array.toSorted(String.compare) {
    Error("the build artifact must contain exactly the two source version archives")
  } else {
    expected->Array.reduce(Ok(), (done, (machine, name)) =>
      done->Result.flatMap(() => {
        let recorded = hashes->Dict.get(machine)->Option.getOr("")
        if !RegExp.test(/^[a-fA-F0-9]{64}$/, recorded) {
          Error(`a recorded sha256 is required for ${machine}`)
        } else if digest(Archive.join([directory, name])) != recorded->String.toLowerCase {
          Error(`${name} differs from the recorded sha256`)
        } else {
          Ok()
        }
      })
    )
  }
}

let prepare = (
  ~run,
  ~repository,
  ~hashes,
  ~execute=output,
  ~directory=Archive.join([Archive.root, "target", "archives"]),
  (),
) => {
  if !RegExp.test(/^[1-9][0-9]*$/, run) {
    Error("run must be a build.yml run id")
  } else {
    let api = path => execute("gh", ["api", `repos/${repository}/${path}`])
    let read = (~repository, ~commit, path) =>
      execute(
        "gh",
        [
          "api",
          `repos/${repository}/contents/${path}?ref=${commit}`,
          "-H",
          "Accept: application/vnd.github.raw+json",
        ],
      )
    api(`actions/runs/${run}`)
    ->Result.flatMap(json)
    ->Result.flatMap(value => selected(~repository, value))
    ->Result.flatMap(commit =>
      api(`compare/main...${commit}`)
      ->Result.flatMap(json)
      ->Result.flatMap(comparison => merged(~commit, comparison))
    )
    ->Result.flatMap(commit =>
      read(~repository, ~commit, Inputs.setup)->Result.flatMap(setup =>
        switch Inputs.platform(setup) {
        | None => Error("the build source pins no platform commit")
        | Some(platform) =>
          metadata(
            ~read=path =>
              path == "model/contracts.json"
                ? read(~repository="monoflake/platform", ~commit=platform, path)
                : read(~repository, ~commit, path),
            commit,
          )
        }
      )
    )
    ->Result.flatMap(source => {
      let download = Archive.join([directory, "download"])
      Archive.rmSync(download, {recursive: true, force: true})
      Archive.mkdirSync(download, {recursive: true})
      execute(
        "gh",
        [
          "run",
          "download",
          run,
          "--repo",
          repository,
          "--name",
          Archive.package,
          "--dir",
          download,
        ],
      )->Result.flatMap(_ =>
        checked(~directory=download, ~version=source.version, ~hashes, ())->Result.map(
          () => {
            Archive.targets->Array.forEach(
              ((_, machine, _)) => {
                let name = `${Archive.package}-${source.version}-linux-${machine}.tar.gz`
                Archive.copyFileSync(
                  Archive.join([download, name]),
                  Archive.join([directory, name]),
                )
              },
            )
            source
          },
        )
      )
    })
  }
}

if Archive.isMain {
  let env = name => Versioned.environment(name)->Option.getOr("")
  let hashes = dict{
    "x86_64": env("RELEASE_SHA256_X86_64"),
    "aarch64": env("RELEASE_SHA256_AARCH64"),
  }
  switch prepare(~run=env("RELEASE_RUN"), ~repository=Versioned.repository, ~hashes, ()) {
  | Error(why) => Versioned.refuse(why)
  | Ok({commit, version, serves}) =>
    Versioned.main(
      ~manifest=Some(version),
      ~commit,
      ~serves=() => serves,
      ~recorded=hashes,
      ~write=document => {
        Versioned.write(document)
        let ready =
          document
          ->Versioned.field("artifacts")
          ->Option.flatMap(JSON.Decode.array)
          ->Option.getOr([]) != []
        Versioned.environment("GITHUB_OUTPUT")->Option.forEach(path =>
          appendFileSync(path, `ready=${ready ? "true" : "false"}\n`)
        )
      },
      (),
    )
  }
}
