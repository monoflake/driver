/** A published source version suppresses the build before either archive is made. */
@module("node:fs") external appendFileSync: (string, string) => unit = "appendFileSync"

switch (Archive.version(), Versioned.listed()) {
| (Some(version), Ok(entries)) if Versioned.numbers(version)->Option.isSome && version != "0.0.0" =>
  let ready = !Versioned.already(entries, version)
  Console.log(`driver-machine ${version}, ${ready ? "ready" : "released already"}`)
  Versioned.environment("GITHUB_OUTPUT")->Option.forEach(path =>
    appendFileSync(path, `ready=${ready ? "true" : "false"}\n`)
  )
| (None, _) => Versioned.refuse("machine/Cargo.toml names no version")
| (_, Error(why)) => Versioned.refuse(why)
| (Some(_), Ok(_)) => Versioned.refuse("releases need a source version above 0.0.0")
}
