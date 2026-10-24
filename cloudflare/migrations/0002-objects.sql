-- What the bucket `objects` holds, RFC nrs5v, object/src/held.res; an applied migration is never
-- edited.

-- Each object by its item and its name, its key `<item>/<name>`, and its size in bytes, the sum of
-- an item's held to that item's size.
CREATE TABLE objects (
	item INTEGER NOT NULL,
	name TEXT NOT NULL,
	size INTEGER NOT NULL,
	PRIMARY KEY (item, name)
);
