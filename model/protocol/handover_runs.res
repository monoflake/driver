/** Completed handover runs from TLC in stable JSONL order. */
@module("node:fs") external readText: (string, string) => string = "readFileSync"
@val external argv: array<string> = "process.argv"

let field = (line, name) =>
  switch RegExp.fromString(`${name}=([a-z0-9,:]*)`)->RegExp.exec(line) {
  | Some(found) =>
    found->RegExp.Result.matches->Array.get(0)->Option.flatMap(x => x)->Option.getOr("")
  | None => ""
  }

let runOf = line => {
  let steps = switch field(line, "steps") {
  | "" => []
  | text => text->String.split(",")->Array.map(step => `"${step}"`)
  }
  `{"case":{"crashes":${field(line, "crashes")}},"steps":[${steps->Array.join(
      ",",
    )}],"end":{"serving":"${field(line, "serving")}","acked":${field(line, "acked")},"kept":${field(
      line,
      "kept",
    )}}}`
}

let fixtureOf = out =>
  out
  ->String.split("\n")
  ->Array.filter(line => line->String.includes("run crashes="))
  ->Array.map(runOf)
  ->Set.fromArray
  ->Set.values
  ->Array.fromIterator
  ->Array.toSorted(String.compare)
  ->Array.join("\n")

Console.log(fixtureOf(readText(argv->Array.getUnsafe(2), "utf8")))
