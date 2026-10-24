/*** A batch D1 failed, read by SQLite's code or the words its message ends with, RFC nrs5v. */

/**
 * The reason a failed batch is answered with, read from D1's message by SQLite's code or its words,
 * a fault where neither tells.
 */
let reasonOf = message => {
  let has = word => message->String.includes(word)
  if has("SQLITE_CONSTRAINT") || has("constraint failed") {
    "constraint"
  } else if has("SQLITE_TOOBIG") || has("too big") || has("too many") {
    "beyond_limit"
  } else if has("SQLITE_FULL") || has("database or disk is full") {
    "storage_full"
  } else if has("SQLITE_READONLY") || has("readonly") {
    "read_only"
  } else if has("overloaded") {
    "overloaded"
  } else if (
    has("SQLITE_ERROR") ||
    has("SQLITE_RANGE") ||
    has("SQLITE_MISMATCH") ||
    has("syntax error") ||
    has("no such") ||
    has("D1_EXEC_ERROR") ||
    has("D1_TYPE_ERROR") ||
    has("D1_COLUMN_NOTFOUND")
  ) {
    "invalid"
  } else {
    "fault"
  }
}
