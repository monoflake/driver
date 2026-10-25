/***
 * install's stdin as the world holds it, a pipe written late read to its end, an empty one read as
 * no token, and one that fails to read refused by its code, each in a child of its own.
 */
open Asserted
open Faked_install

type io
external piped: string => io = "%identity"
external descriptor: int => io = "%identity"
type ended = {status: Nullable.t<int>, stdout: string, stderr: string}
type options = {
  stdio: array<io>,
  encoding: string,
  timeout: int,
  input?: string,
  env?: Dict.t<string>,
}
@module("node:child_process")
external spawnSync: (string, array<string>, options) => ended = "spawnSync"
@module("node:fs") external openSync: (string, string) => int = "openSync"
@module("node:fs") external closeSync: int => unit = "closeSync"
@val external execPath: string = "process.execPath"

let child = Host.join([
  Host.fileURLToPath(Host.importMetaUrl),
  "..",
  "fakes",
  "stdin_child.res.mjs",
])
let output = [piped("pipe"), piped("pipe")]

/** Each way the child's stdin is held, as it is given and made non-blocking as node makes it. */
let ways = [[], ["--non-blocking"]]

test("a pipe written only after a delay is read to its end, the token it holds taken", () => {
  ways->Array.forEach(way => {
    let env = Dict.fromArray(
      [
        ...Host.processEnv->Dict.toArray,
        ("TOKEN", token),
        ("NODE", execPath),
        ("CHILD", child),
        ("WAY", way->Array.join(" ")),
      ],
    )
    let late = `(sleep 1.5; printf '%s\\n' "$TOKEN") | "$NODE" "$CHILD" $WAY`
    let done = spawnSync(
      "sh",
      ["-c", late],
      {stdio: [piped("ignore"), ...output], encoding: "utf8", timeout: 30000, env},
    )
    deepEqual(done.stdout->String.trim, `token ${token}`, ~message=done.stderr)
  })
})

test("an empty pipe closed at once reads as no token", () => {
  ways->Array.forEach(way => {
    let done = spawnSync(
      execPath,
      [child, ...way],
      {stdio: [piped("pipe"), ...output], encoding: "utf8", timeout: 30000, input: ""},
    )
    deepEqual(done.stdout->String.trim, "no token", ~message=done.stderr)
  })
})

test("a stdin that fails to read refuses the install by its code, nothing run", () => {
  // A directory opens for reading and fails at its first read, EISDIR.
  let directory = openSync(Host.tmpdir(), "r")
  let done = spawnSync(
    execPath,
    [child, "--install"],
    {stdio: [descriptor(directory), ...output], encoding: "utf8", timeout: 30000},
  )
  closeSync(directory)
  let said = done.stdout->String.trim
  ok(
    said->String.startsWith("refused ") &&
    said->String.includes("EISDIR") &&
    said->String.endsWith(", 0 run"),
    ~message=`${said}\n${done.stderr}`,
  )
})

@send external copied: (Uint8Array.t, Uint8Array.t) => unit = "set"

/** A read answering each of its steps in turn, bytes written into the chunk or an error thrown. */
type step = Bytes(string) | Failed(string)
let reading = steps => {
  let left = steps->Array.copy
  chunk =>
    switch left->Array.shift {
    | Some(Bytes(text)) =>
      let bytes = Host.fromEncoded(text, "utf8")
      chunk->copied(bytes)
      TypedArray.length(bytes)
    | Some(Failed(code)) => JsExn.throw({"code": code, "message": `${code}: made up, read`})
    | None => 0
    }
}

test("a read that would block is waited on and tried again until the pipe ends", () => {
  let waited = ref(0)
  let wait = () => waited := waited.contents + 1
  let steps = [Failed("EAGAIN"), Bytes("7.AAECAwQF"), Failed("EWOULDBLOCK"), Bytes("BgcI\n")]
  deepEqual(Install.readWhole(~read=reading(steps), ~wait), Ok("7.AAECAwQFBgcI\n"))
  deepEqual(waited.contents, 2)
})

test("a read failing for another reason is an error naming its code, never an empty stdin", () => {
  ["EBADF", "EIO", "EISDIR"]->Array.forEach(code => {
    let read = reading([Bytes("7.AAEC"), Failed(code)])
    switch Install.readWhole(~read, ~wait=() => ()) {
    | Error(why) => ok(why->String.includes(code), ~message=why)
    | Ok(held) => ok(false, ~message=`${code} read as ${held}`)
    }
  })
})

test("a stdin that cannot be read refuses the install before anything runs", () => {
  let faked = make(~answer=_ => Ok(""))
  let why = "stdin could not be read, EBADF, so whether it holds a token is not known"
  let world = {...faked.world, stdin: () => throw(Install.Unread(why))}
  deepEqual(Install.install(world, ~dry=false, ~root=fixture()), Error(why))
  deepEqual(faked.ran, [])
})

after(() => fixtures->Array.forEach(root => Host.rmSync(root, {recursive: true, force: true})))
