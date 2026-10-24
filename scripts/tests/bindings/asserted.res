/***
 * What the scripts' tests take of node, its test runner, its assertions and its files.
 */
@module("node:test") external test: (string, unit => unit) => unit = "test"
@module("node:test") external after: (unit => unit) => unit = "after"
@module("node:assert/strict")
external deepEqual: ('a, 'a, ~message: string=?) => unit = "deepStrictEqual"
@module("node:assert/strict") external ok: (bool, ~message: string=?) => unit = "ok"
type made = {recursive: bool}
@module("node:fs") external mkdirSync: (string, made) => unit = "mkdirSync"
@module("node:fs") external copyFileSync: (string, string) => unit = "copyFileSync"
@module("node:fs") external symlinkSync: (string, string) => unit = "symlinkSync"
type looked = {throwIfNoEntry: bool}
@module("node:fs") external lstatSync: (string, looked) => Nullable.t<Host.stats> = "lstatSync"

/** Whether a path names anything, a link to nothing among it. */
let named = path => lstatSync(path, {throwIfNoEntry: false})->Nullable.toOption->Option.isSome
