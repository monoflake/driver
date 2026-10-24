-- The item the D1 database `database` is held for, RFC nrs5v, database/src/held.res; an applied
-- migration is never edited.

-- One row once the Worker `database` answered for an item, `since` in milliseconds when the
-- database was emptied for it, and `size` its bytes after the last batch run on it.
CREATE TABLE database_held (
	one INTEGER PRIMARY KEY CHECK (one = 1),
	item INTEGER NOT NULL,
	since INTEGER NOT NULL,
	size INTEGER NOT NULL
);
