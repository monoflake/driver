/*** A tar archive written as ustar for the tests to unpack, each header as POSIX writes it. */

/** An entry, its type a header's flag, `0` a file, `5` a directory and `x` a pax header. */
type entry = {name: string, bytes: Uint8Array.t, flag: string, prefix: string}

let file = (name, text) => {name, bytes: Web.utf8(text), flag: "0", prefix: ""}

let write = (header, ~at, text) =>
  Web.utf8(text)->TypedArray.forEachWithIndex((b, i) => header->TypedArray.set(at + i, b))

/** A number in octal, so many digits long, as a header writes it. */
let octal = (n, digits) => Int.toString(n, ~radix=8)->String.padStart(digits, "0")

let header = (entry, ~size) => {
  let header = Uint8Array.fromLength(512)
  header->write(~at=0, entry.name)
  header->write(~at=100, "0000644")
  header->write(~at=108, "0000000")
  header->write(~at=116, "0000000")
  header->write(~at=124, octal(size, 11))
  header->write(~at=136, "00000000000")
  header->write(~at=148, "        ")
  header->write(~at=156, entry.flag)
  header->write(~at=257, "ustar")
  header->write(~at=263, "00")
  header->write(~at=345, entry.prefix)
  let sum = header->TypedArray.reduce((sum, b) => sum + b, 0)
  header->write(~at=148, octal(sum, 6))
  header->TypedArray.set(154, 0)
  header
}

let concat = (parts: array<Uint8Array.t>) => {
  let whole = Uint8Array.fromLength(parts->Array.reduce(0, (n, p) => n + TypedArray.length(p)))
  parts
  ->Array.reduce(0, (at, p) => {
    whole->TypedArray.setArrayFrom(
      Array.fromInitializer(~length=TypedArray.length(p), i =>
        p->TypedArray.get(i)->Option.getOr(0)
      ),
      at,
    )
    at + TypedArray.length(p)
  })
  ->ignore
  whole
}

/** The archive of the entries in order, each padded to its block, ended by two empty blocks. */
let archive = entries =>
  concat(
    entries
    ->Array.flatMap(entry => {
      let size = TypedArray.length(entry.bytes)
      let padding = Int.mod(512 - Int.mod(size, 512), 512)
      [header(entry, ~size), entry.bytes, Uint8Array.fromLength(padding)]
    })
    ->Array.concat([Uint8Array.fromLength(1024)]),
  )

/** A bundle's archive, its metadata naming `main.js` and a date. */
let metadata = `{"main_module": "main.js", "compatibility_date": "2026-10-21"}`

let bundled = (~metadata=metadata, files) => archive([file("metadata.json", metadata), ...files])
