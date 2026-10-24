/***
 * What is read of a statement before D1 runs it, its length against the bound this driver declares
 * and its first keyword, which tells a read from a write, RFC nrs5v.
 */

/** The most bytes a statement's SQL holds, D1's own bound, declared as the bound `statement`. */
let bound = 100_000

/** Whether a statement's SQL in UTF-8 passes the bound. */
let past = sql => TypedArray.length(Web.utf8(sql)) > bound

/** Whether a character is space as SQLite reads it between tokens. */
let space = character =>
  character == " " ||
  character == "\t" ||
  character == "\n" ||
  character == "\r" ||
  character == "\x0c"

/** The SQL from its first token on, the space and comments before it passed over. */
let rec trimmed = sql =>
  switch sql->String.charAt(0) {
  | "" => ""
  | character if space(character) => trimmed(sql->String.slice(~start=1))
  | "-" if sql->String.startsWith("--") =>
    switch sql->String.indexOf("\n") {
    | -1 => ""
    | at => trimmed(sql->String.slice(~start=at + 1))
    }
  | "/" if sql->String.startsWith("/*") =>
    switch sql->String.indexOfFrom("*/", 2) {
    | -1 => ""
    | at => trimmed(sql->String.slice(~start=at + 2))
    }
  | _ => sql
  }

/** The first keyword of a statement in capitals, empty where it begins with none. */
let keyword = sql => {
  let rest = trimmed(sql)
  let letters = /^[A-Za-z]+/
  switch letters->RegExp.exec(rest) {
  | Some(found) => found[0]->Option.flatMap(x => x)->Option.getOr("")->String.toUpperCase
  | None => ""
  }
}

/** Whether a statement only reads, by its first keyword, so a full database still answers it. */
let reads = sql =>
  switch keyword(sql) {
  | "SELECT" | "EXPLAIN" | "VALUES" => true
  | _ => false
  }

/** Whether the rows a statement changed are counted, SQLite counting those of these alone. */
let counts = sql =>
  switch keyword(sql) {
  | "INSERT" | "UPDATE" | "DELETE" | "REPLACE" | "WITH" => true
  | _ => false
  }
