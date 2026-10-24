/*** What the driver takes of a Worker's D1, statements prepared, bound, run and batched. */
@notUndefined
type database
type statement

/** A value bound to a statement, text, a number or none. */
@unboxed
type value = Text(string) | Number(float) | @as(null) Null

@send external prepare: (database, string) => statement = "prepare"
@send @variadic external bind: (statement, array<value>) => statement = "bind"
/** The first row, its columns read as the caller's record names them. */
@send external first: statement => promise<Nullable.t<'row>> = "first"

type rows<'row> = {results: array<'row>}
@send external all: statement => promise<rows<'row>> = "all"

/** The statements run in order as one transaction. */
@send external batch: (database, array<statement>) => promise<unit> = "batch"
