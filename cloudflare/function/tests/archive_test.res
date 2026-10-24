/*** `Function.unpack` held to driver(machine)'s `function/src/bundle.rs`, on archives made here. */
open Node

let named = (bundle: Function.bundle) => bundle.modules->Array.map(m => (m.name, m.kind))

let refused = result =>
  switch result {
  | Ok(_) => None
  | Error({Function.reason: reason, message}) => Some((reason, message))
  }

let malformed = message => Some(("malformed", message))

test("a bundle is its main module first, then the rest by name, typed by extension", async () => {
  let bytes = Tar.bundled([
    Tar.file("words.txt", "hello"),
    Tar.file("lib/util.cjs", "module.exports = 1"),
    Tar.file("main.js", "export default {}"),
    Tar.file("./data.bin", "\x01"),
    {...Tar.file("lib", ""), flag: "5"},
    Tar.file("add.wasm", ""),
    Tar.file("table.json", "{}"),
    Tar.file("inner.mjs", ""),
  ])
  switch Function.unpack(bytes) {
  | Ok(bundle) =>
    deepEqual(
      named(bundle),
      [
        ("main.js", Function.Es),
        ("add.wasm", Wasm),
        ("data.bin", Data),
        ("inner.mjs", Es),
        ("lib/util.cjs", CommonJs),
        ("table.json", Json),
        ("words.txt", Text),
      ],
    )
    deepEqual(bundle.compatibilityDate, "2026-10-21")
    deepEqual(bundle.compatibilityFlags, [])
    deepEqual(
      bundle.modules->Array.get(0)->Option.map(m => m.bytes),
      Some(Web.utf8("export default {}")),
    )
  | Error(_) => ok(false, ~message="the bundle was refused")
  }
})

test("a path's ustar prefix and a pax header's path name its module", async () => {
  let bytes = Tar.bundled([
    Tar.file("main.js", ""),
    {...Tar.file("deep.js", ""), prefix: "a/b"},
    {...Tar.file("ignored", "27 path=pax/named/module.js\n"), flag: "x"},
    Tar.file("short.js", "x"),
  ])
  deepEqual(
    Function.unpack(bytes)->Result.map(named),
    Ok([("main.js", Function.Es), ("a/b/deep.js", Es), ("pax/named/module.js", Es)]),
  )
})

test("its metadata names its main module and a date, and its flags as strings", async () => {
  let metadata = text => Tar.bundled(~metadata=text, [Tar.file("main.js", "")])->Function.unpack
  deepEqual(
    refused(Tar.archive([Tar.file("main.js", "")])->Function.unpack),
    malformed("a bundle holds its metadata.json"),
  )
  deepEqual(refused(metadata("{")), malformed("metadata.json is not JSON"))
  deepEqual(
    refused(metadata(`{"compatibility_date": "2026-10-21"}`)),
    malformed("metadata.json names its main_module"),
  )
  deepEqual(
    refused(metadata(`{"main_module": "main.js", "compatibility_date": "21 October"}`)),
    malformed("metadata.json names its compatibility_date, YYYY-MM-DD"),
  )
  let flagged = `{"main_module": "main.js", "compatibility_date": "2026-10-21",
    "compatibility_flags": [1]}`
  deepEqual(
    refused(metadata(flagged)),
    malformed("metadata.json's compatibility_flags are strings"),
  )
  let flags = `{"main_module": "main.js", "compatibility_date": "2026-10-21",
    "compatibility_flags": ["nodejs_compat"]}`
  deepEqual(metadata(flags)->Result.map(b => b.compatibilityFlags), Ok(["nodejs_compat"]))
  deepEqual(
    refused(Tar.bundled([Tar.file("other.js", "")])->Function.unpack),
    malformed("the main module main.js is not in the bundle"),
  )
})

test("a module lies inside the bundle, once, as a file of a known type", async () => {
  let unpacked = files => Tar.bundled([Tar.file("main.js", ""), ...files])->Function.unpack
  deepEqual(
    refused(unpacked([Tar.file("../up.js", "")])),
    malformed("../up.js lies outside the bundle"),
  )
  deepEqual(
    refused(unpacked([Tar.file("/root.js", "")])),
    malformed("/root.js lies outside the bundle"),
  )
  deepEqual(
    refused(unpacked([Tar.file("./main.js", "")])),
    malformed("the bundle holds main.js twice"),
  )
  deepEqual(
    refused(unpacked([Tar.file("style.css", "")])),
    malformed("style.css: a module is named .js, .mjs, .cjs, .wasm, .txt, .bin or .json"),
  )
  deepEqual(
    refused(unpacked([{...Tar.file("link.js", ""), flag: "2"}])),
    malformed("a bundle holds files and directories alone"),
  )
})

test("bytes that are no archive are malformed", async () => {
  let broken = Tar.bundled([Tar.file("main.js", "")])
  broken->TypedArray.set(0, 0x41)
  deepEqual(
    refused(Function.unpack(broken)),
    malformed("the artifact is no tar archive of modules, a header's checksum fails"),
  )
  let cut = Tar.bundled([Tar.file("main.js", "x")])->TypedArray.slice(~start=0, ~end=2048)
  ok(Function.unpack(cut)->Result.isOk)
  let short =
    Tar.bundled([Tar.file("main.js", String.repeat("x", 600))])->TypedArray.slice(
      ~start=0,
      ~end=1536,
    )
  deepEqual(
    refused(Function.unpack(short)),
    malformed("the artifact is no tar archive of modules, it ends inside an entry"),
  )
})
