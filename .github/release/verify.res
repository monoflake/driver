/** What the driver's verify runs of its release, the release's tests and then the provisional
 * source version guard, RFC 8c0rg. */
let undone = "the source version was not checked"

let guard = (~listed=Versioned.listed, ~compare=entry => Inputs.changed(entry), ()) =>
  switch (Archive.version(), listed()) {
  | (None, _) => Versioned.refuse("machine/Cargo.toml names no version")
  | (_, Error(why)) => Versioned.unread(why, ~undone)
  | (Some(manifest), Ok(entries)) =>
    let last = Versioned.lastOf(entries)
    let compared =
      last->Option.mapOr(Ok({Inputs.own: false, shared: false, unknown: []}), entry =>
        compare(entry)
      )
    switch compared {
    | Error(why) => Versioned.unread(why, ~undone)
    | Ok({own, shared, unknown}) =>
      switch Versioned.checked(
        ~manifest,
        ~last=last->Option.flatMap(entry => entry->Versioned.text("version")),
        ~changed=own || shared,
      ) {
      | Error(why) => Versioned.refuse(why)
      | Ok() if unknown != [] =>
        Versioned.warn(
          `monoflake/platform lacks ${unknown->Array.join(
              ", ",
            )} even after a fetch, so its change since the last release was not checked; fetch platform and run again`,
        )
      | Ok() => Console.log("driver-machine source version passed")
      }
    }
  }

if Archive.isMain {
  if Archive.ran("node", ["--test", ".github/release/versioned_test.res.mjs"]) {
    guard()
  } else {
    Versioned.refuse("the release's tests failed")
  }
}
