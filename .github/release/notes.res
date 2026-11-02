/** The day's release notes rendered again by the workspace's scripts/release/release.res. */
type options = {cwd: string, stdio: string}
type spawned = {status: Nullable.t<int>}
@module("node:child_process")
external spawn: (string, array<string>, options) => spawned = "spawnSync"

switch Archive.env->Dict.get("WORKSPACE") {
| None => Versioned.refuse("no WORKSPACE, which mise sets from the workspace's mise.toml")
| Some(workspace) =>
  let script = Archive.join([workspace, "scripts", "release", "release.res.mjs"])
  let status = spawn("node", [script, "notes"], {cwd: Archive.root, stdio: "inherit"}).status
  Base.process->Base.setExitCode(status->Nullable.getOr(1))
}
