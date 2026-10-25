/***
 * What `install` takes of node, its files, processes, stdin and bytes, gathered where it is seen.
 */

@module("node:fs") external readFileSync: (string, @as("utf8") _) => string = "readFileSync"
@module("node:fs") external readBytes: string => Uint8Array.t = "readFileSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:fs") external existsSync: string => bool = "existsSync"
@module("node:fs") external mkdtempSync: string => string = "mkdtempSync"
type removed = {recursive: bool, force: bool}
@module("node:fs") external rmSync: (string, removed) => unit = "rmSync"
type listed = {recursive: bool}
@module("node:fs") external readdirSync: (string, listed) => array<string> = "readdirSync"
type stats
@module("node:fs") external statSync: string => stats = "statSync"
@send external isFile: stats => bool = "isFile"
@module("node:os") external tmpdir: unit => string = "tmpdir"
@module("node:path") @variadic external join: array<string> => string = "join"
@module("node:path") external basename: string => string = "basename"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@val external importMetaUrl: string = "import.meta.url"
@val external isMain: bool = "import.meta.main"
@val external processEnv: Dict.t<string> = "process.env"
@val external argv: array<string> = "process.argv"
type proc
@val external process: proc = "process"
@set external setExitCode: (proc, int) => unit = "exitCode"

/** Whether stdin is a terminal, asked of descriptor 0 without making process.stdin. */
@module("node:tty") external stdinTerminal: @as(0) _ => bool = "isatty"
/** One read of stdin into a buffer from its start, the count of bytes read, 0 at its end. */
@module("node:fs")
external readStdinInto: (@as(0) _, Uint8Array.t, @as(0) _, int, @as(json`null`) _) => int =
  "readSync"
/** The code a node error names itself by, as `EAGAIN`. */
@get external errorCode: JsExn.t => Nullable.t<string> = "code"
type shared
@new external sharedBuffer: int => shared = "SharedArrayBuffer"
@new external int32sOf: shared => Int32Array.t = "Int32Array"
@val @scope("Atomics") external waitOn: (Int32Array.t, int, int, int) => string = "wait"
/** The thread held still for some milliseconds, as a synchronous read waits. */
let pause = milliseconds => waitOn(int32sOf(sharedBuffer(4)), 0, 0, milliseconds)->ignore

type hash
@module("node:crypto") external createHash: string => hash = "createHash"
@send external update: (hash, Uint8Array.t) => hash = "update"
@send external updateText: (hash, string) => hash = "update"
@send external digest: (hash, @as("hex") _) => string = "digest"

type buffer
@module("node:buffer") @scope("Buffer")
external fromEncoded: (string, string) => Uint8Array.t = "from"
@module("node:buffer") @scope("Buffer") external fromBytes: Uint8Array.t => buffer = "from"
@module("node:buffer") @scope("Buffer") external joined: array<Uint8Array.t> => buffer = "concat"
@send external encoded: (buffer, string) => string = "toString"

type spawned = {status: Nullable.t<int>, stdout: Nullable.t<string>, stderr: Nullable.t<string>}
type spawnOptions = {
  cwd: string,
  input?: string,
  env: Dict.t<string>,
  stdio: array<string>,
  encoding: string,
}
@module("node:child_process")
external spawnSync: (string, array<string>, spawnOptions) => spawned = "spawnSync"
