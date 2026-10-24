/***
 * What the Worker takes of D1, statements run alone or in a batch, as
 * https://developers.cloudflare.com/d1/worker-api/ and its return object's page document them.
 */
@notUndefined
type database
type statement

/** A value bound to a statement, text, a number, bytes or none. */
@unboxed
type value = Text(string) | Number(float) | @as(null) Null

/** Bytes bound as a BLOB, the one value no case of `value` carries. */
external bytes: Uint8Array.t => value = "%identity"

@send external prepare: (database, string) => statement = "prepare"
@send @variadic external bind: (statement, array<value>) => statement = "bind"
/** The first row, its columns read as the caller's record names them. */
@send external first: statement => promise<Nullable.t<'row>> = "first"

type rows<'row> = {results: array<'row>}
@send external all: statement => promise<rows<'row>> = "all"

/** What a statement run changed, the rows it changed, whether it changed the database, its size. */
type meta = {
  changes: float,
  @as("changed_db") changedDb: bool,
  @as("size_after") sizeAfter: float,
}
type ran = {meta: meta}
@send external run: statement => promise<ran> = "run"

/** A value as D1 answers it in a row, read by its JavaScript type alone. */
type cell

/** A statement's answer in a batch, its rows each a column's name to its value. */
type result = {results: Nullable.t<array<dict<cell>>>, meta: meta}

/** Statements run as one transaction, each answered in order, none kept where one fails. */
@send external batch: (database, array<statement>) => promise<array<result>> = "batch"

/** A cell read as D1 gives one, a BLOB as numbers or a buffer, an integer past a number large. */
type read =
  | Absent
  | Numeric(float)
  | Textual(string)
  | Binary(Uint8Array.t)
  | Large
  | Other

external asFloat: cell => float = "%identity"
external asString: cell => string = "%identity"
external asNumbers: cell => array<int> = "%identity"
external asView: cell => Uint8Array.t = "%identity"
external asBuffer: cell => ArrayBuffer.t = "%identity"
@val external isView: cell => bool = "ArrayBuffer.isView"
@val external isArray: cell => bool = "Array.isArray"
let isBuffer: cell => bool = %raw(`cell => cell instanceof ArrayBuffer`)

let readOf = (cell: cell) =>
  switch Type.typeof(cell) {
  | #number => Numeric(asFloat(cell))
  | #string => Textual(asString(cell))
  | #undefined => Absent
  | #object if Nullable.isNullable(cell->Obj.magic) => Absent
  | #object if isArray(cell) => Binary(Uint8Array.fromArray(asNumbers(cell)))
  | #object if isView(cell) => Binary(asView(cell))
  | #object if isBuffer(cell) => Binary(Uint8Array.fromBuffer(asBuffer(cell)))
  | #bigint => Large
  | #object | #boolean | #symbol | #function => Other
  }
