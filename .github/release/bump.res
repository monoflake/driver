/** The source version raised before a change is committed, RFC 8c0rg. */
let undone = "nothing was bumped"

/** Whether anything driver-machine is built from changed since `entry`'s release, and each
 * message since, a platform the local checkout cannot read counted as changed. */
let since = (
  ~compare=entry => Inputs.changed(entry),
  ~breaking=(~reach, entry) => Inputs.breakingSince(~reach, entry),
  entry,
) =>
  compare(entry)->Result.flatMap(({Inputs.own: own, shared, unknown}) =>
    switch (own || shared, unknown) {
    | (false, []) => Ok((false, []))
    | (_, []) =>
      breaking(~reach=commits => Inputs.reached(commits), entry)->Result.map(({messages}) => (
        true,
        messages,
      ))
    | (_, unknown) =>
      Versioned.warn(
        `monoflake/platform lacks ${unknown->Array.join(
            ", ",
          )} even after a fetch, so a minor raise could not be inferred from it; the patch is raised at least`,
      )
      breaking(~reach=_ => Error(unknown), entry)->Result.map(({messages}) => (true, messages))
    }
  )

/** `machine/Cargo.toml` at `version`, `Cargo.lock` synchronized, or why it could not be. */
let written = (~manifest, version) => {
  let path = Archive.join([Archive.root, "machine", "Cargo.toml"])
  let source = Archive.readFileSync(path)
  Versioned.writeFileSync(
    path,
    source->String.replace(`version = "${manifest}"`, `version = "${version}"`),
  )
  if Archive.ran("cargo", ["update", "--workspace", "--offline"]) {
    Ok()
  } else {
    Versioned.writeFileSync(path, source)
    Error("Cargo.lock could not be synchronized")
  }
}

let main = (~listed=Versioned.listed, ~since=entry => since(entry), ~write=written, ()) =>
  switch (Archive.version(), listed()) {
  | (None, _) => Versioned.refuse("machine/Cargo.toml names no version")
  | (_, Error(why)) => Versioned.unread(why, ~undone)
  | (Some(manifest), Ok(entries)) =>
    let last = Versioned.lastOf(entries)
    switch last->Option.mapOr(Ok((false, [])), since) {
    | Error(why) => Versioned.unread(why, ~undone)
    | Ok((changed, messages)) =>
      switch Versioned.bumped(
        ~manifest,
        ~last=last->Option.map(Inputs.recorded),
        ~serves=Versioned.served(),
        ~messages,
        ~changed,
      ) {
      | None => Versioned.refuse("machine/Cargo.toml needs MAJOR.MINOR.PATCH")
      | Some(version) if version == manifest => Console.log(`driver-machine ${manifest}, kept`)
      | Some(version) =>
        switch Versioned.dry ? Ok() : write(~manifest, version) {
        | Error(why) => Versioned.refuse(why)
        | Ok() => Console.log(`driver-machine ${manifest} -> ${version}`)
        }
      }
    }
  }

if Archive.isMain {
  main()
}
