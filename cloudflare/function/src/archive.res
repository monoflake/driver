/***
 * A bundle read from its artifact, a tar archive of its modules and its metadata, RFC dg903, by the
 * rules driver(machine)'s `function/src/bundle.rs` reads it with.
 */
open Script

/** What names a bundle's main module and its compatibility, beside its modules. */
let metadata = "metadata.json"

/** A tar archive's block, its headers and its contents padded to it. */
let block = 512

exception Refused(string)

let malformed = message => {reason: "malformed", message}

let byte = (bytes, at) => bytes->TypedArray.get(at)->Option.getOr(0)

let slice = (bytes, ~start, ~length) => bytes->TypedArray.subarray(~start, ~end=start + length)

/** A header's text field, up to its first zero byte. */
let field = (header, ~start, ~length) => {
  let bytes = header->slice(~start, ~length)
  let end = bytes->TypedArray.findIndex(b => b == 0)
  let text = bytes->slice(~start=0, ~length=end < 0 ? length : end)->Web.fromUtf8
  switch text {
  | Some(text) => text
  | None => throw(Refused("a module's name is UTF-8"))
  }
}

/** A header's octal number, spaces and zero bytes around it passed over. */
let octal = (header, ~start, ~length) => {
  let text = header->field(~start, ~length)->String.trim
  if text == "" || !(/^[0-7]+$/->RegExp.test(text)) {
    throw(Refused("an entry's size or checksum is no octal number"))
  }
  text
  ->String.split("")
  ->Array.reduce(0., (n, digit) => n *. 8. +. Int.toFloat(Int.fromString(digit)->Option.getOr(0)))
}

/** Whether a header's checksum is the sum of its bytes, its own field read as spaces. */
let checked = header => {
  let sum = ref(0.)
  for at in 0 to block - 1 {
    let b = at >= 148 && at < 156 ? 32 : byte(header, at)
    sum := sum.contents +. Int.toFloat(b)
  }
  sum.contents == header->octal(~start=148, ~length=8)
}

/** An entry's path as a module's name, its parts joined by `/`, never `..` or a root. */
let named = path => {
  if path->String.startsWith("/") {
    throw(Refused(`${path} lies outside the bundle`))
  }
  let parts = path->String.split("/")->Array.filter(part => part != "" && part != ".")
  if parts->Array.includes("..") {
    throw(Refused(`${path} lies outside the bundle`))
  }
  if parts == [] {
    throw(Refused("an entry of the bundle names nothing"))
  }
  parts->Array.join("/")
}

/** The `path` a pax extended header gives, each record `<length> <key>=<value>\n`. */
let paxPath = content => {
  let text = switch Web.fromUtf8(content) {
  | Some(text) => text
  | None => throw(Refused("a pax header is UTF-8"))
  }
  text
  ->String.split("\n")
  ->Array.findMap(record =>
    switch record->String.indexOf(" ") {
    | -1 => None
    | space =>
      let pair = record->String.slice(~start=space + 1)
      pair->String.startsWith("path=") ? Some(pair->String.slice(~start=5)) : None
    }
  )
}

/** Every file of the archive by its name, its directories passed over. */
let files = (bytes: Uint8Array.t) => {
  let found = Map.make()
  let length = TypedArray.length(bytes)
  let at = ref(0)
  let next = ref(None)
  let ended = ref(false)
  while !ended.contents && at.contents + block <= length {
    let header = bytes->slice(~start=at.contents, ~length=block)
    if header->TypedArray.every(b => b == 0) {
      ended := true
    } else {
      if !checked(header) {
        throw(Refused("the artifact is no tar archive of modules, a header's checksum fails"))
      }
      let size = header->octal(~start=124, ~length=12)->Float.toInt
      let start = at.contents + block
      if start + size > length {
        throw(Refused("the artifact is no tar archive of modules, it ends inside an entry"))
      }
      let content = bytes->slice(~start, ~length=size)
      at := start + (size + block - 1) / block * block
      let ustar = header->field(~start=257, ~length=5) == "ustar"
      let prefix = ustar ? header->field(~start=345, ~length=155) : ""
      let name = header->field(~start=0, ~length=100)
      let path = switch next.contents {
      | Some(path) => path
      | None => prefix == "" ? name : `${prefix}/${name}`
      }
      switch header->byte(156) {
      // A pax header or a GNU long name gives the next entry's path.
      | 120 => next := paxPath(content)
      | 76 =>
        let end = content->TypedArray.findIndex(b => b == 0)
        next := content->slice(~start=0, ~length=end < 0 ? size : end)->Web.fromUtf8
      | 53 | 103 => next := None
      | 0 | 48 =>
        next := None
        let name = named(path)
        if found->Map.has(name) {
          throw(Refused(`the bundle holds ${name} twice`))
        }
        found->Map.set(name, content)
      | _ => throw(Refused("a bundle holds files and directories alone"))
      }
    }
  }
  found
}

/** A module's type, by its name's extension. */
let kindOf = name => {
  let extension = switch name->String.lastIndexOf(".") {
  | -1 => ""
  | at => name->String.slice(~start=at + 1)
  }
  switch extension {
  | "js" | "mjs" => Es
  | "cjs" => CommonJs
  | "wasm" => Wasm
  | "txt" => Text
  | "bin" => Data
  | "json" => Json
  | _ => throw(Refused(`${name}: a module is named .js, .mjs, .cjs, .wasm, .txt, .bin or .json`))
  }
}

let moduleOf = (name, bytes) => {name, kind: kindOf(name), bytes}

/** Whether a date is written `YYYY-MM-DD`. */
let dated = date => /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/->RegExp.test(date)

let unpack = (bytes: Uint8Array.t) =>
  try {
    let files = files(bytes)
    let described = switch files->Map.get(metadata) {
    | Some(described) => described
    | None => throw(Refused(`a bundle holds its ${metadata}`))
    }
    files->Map.delete(metadata)->ignore
    let read = switch Web.fromUtf8(described)->Option.map(text => JSON.parseOrThrow(text)) {
    | Some(read) => read
    | None => throw(Refused(`${metadata} is not JSON`))
    | exception JsExn(_) => throw(Refused(`${metadata} is not JSON`))
    }
    let member = key => read->JSON.Decode.object->Option.flatMap(fields => fields->Dict.get(key))
    let main = switch member("main_module")->Option.flatMap(JSON.Decode.string) {
    | Some(main) => main
    | None => throw(Refused(`${metadata} names its main_module`))
    }
    let compatibilityDate = switch member("compatibility_date")->Option.flatMap(
      JSON.Decode.string,
    ) {
    | Some(date) if dated(date) => date
    | Some(_) | None => throw(Refused(`${metadata} names its compatibility_date, YYYY-MM-DD`))
    }
    let flagged = `${metadata}'s compatibility_flags are strings`
    let compatibilityFlags = switch member("compatibility_flags") {
    | None => []
    | Some(flags) =>
      switch flags->JSON.Decode.array {
      | Some(flags) =>
        flags->Array.map(flag =>
          switch flag->JSON.Decode.string {
          | Some(flag) => flag
          | None => throw(Refused(flagged))
          }
        )
      | None => throw(Refused(flagged))
      }
    }
    let first = switch files->Map.get(main) {
    | Some(first) => first
    | None => throw(Refused(`the main module ${main} is not in the bundle`))
    }
    files->Map.delete(main)->ignore
    let rest =
      files
      ->Map.entries
      ->Array.fromIterator
      ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
      ->Array.map(((name, bytes)) => moduleOf(name, bytes))
    Ok({modules: [moduleOf(main, first), ...rest], compatibilityDate, compatibilityFlags})
  } catch {
  | Refused(message) => Error(malformed(message))
  }
