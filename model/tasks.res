/**
 * This repository's tasks, `check`, `brief`, `accept` and `built`, each run by monoflake/platform's
 * own code over this repository's blocks and fill, RFC 7ykg6.
 */
@module("node:fs") external write: (string, string) => unit = "writeFileSync"
@module("node:fs") external temporary: string => string = "mkdtempSync"
@module("node:os") external tmpdir: unit => string = "tmpdir"
@module("node:path") @variadic external join: array<string> => string = "join"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@val external importMetaUrl: string = "import.meta.url"
@val external env: Dict.t<string> = "process.env"
@val external copy: (@as(json`{}`) _, Dict.t<string>) => Dict.t<string> = "Object.assign"
type options = {env: Dict.t<string>, stdio: string}
type spawned = {status: Nullable.t<int>}
@module("node:child_process")
external spawn: (string, array<string>, options) => spawned = "spawnSync"

/** monoflake/platform's check run with this fill, its status, as cloud's whole model runs it. */
let platform = () => {
  let here = fileURLToPath(importMetaUrl)
  let check = join([here, "..", "..", "..", "platform", "model", "check.res.mjs"])
  let fill = join([temporary(join([tmpdir(), "monoflake-fill-"])), "fill.json"])
  write(fill, JSON.stringifyAny({"drivers": Filling.given})->Option.getOr("{}"))
  let given = copy(env)
  given->Dict.set("MONOFLAKE_FILL", fill)
  spawn("node", [check], {env: given, stdio: "inherit"}).status->Nullable.getOr(1)
}

let given = Base.args->Array.slice(~start=3)
switch Base.args->Array.get(2) {
| Some("check") =>
  let status = platform()
  Tree.check(Filling.tree(), ~title="Driver blocks held", ~work="model/plan/progress.res")
  Base.shownInWork()
  Base.process->Base.setExitCode(status != 0 || Base.failed.contents ? 1 : 0)
| Some("brief") => Tree.brief(Filling.tree(), given)
| Some("accept") => Tree.accept(Filling.tree(), given)
| Some("built") => Tree.built(Filling.tree())
| _ =>
  Console.error("tasks check | brief <package> | accept <package> | built")
  Base.process->Base.setExitCode(2)
}
