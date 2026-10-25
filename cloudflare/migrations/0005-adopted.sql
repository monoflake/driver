-- The exception list and the warnings standing, RFCs nrs5v and vbg0u, src/kept.res; an applied
-- migration is never edited.

-- Each resource of the organization's own the driver manages, by its exact name, its kind, and
-- what it stands for, `runs` app, component or item, by `id` or by `component`.
CREATE TABLE adopted (
	name TEXT PRIMARY KEY,
	kind TEXT NOT NULL,
	runs TEXT NOT NULL,
	id INTEGER,
	component TEXT
);

-- What a person should act on, by the resource it names, kept until that resource no longer exists.
CREATE TABLE warnings (
	name TEXT PRIMARY KEY,
	reason TEXT NOT NULL,
	message TEXT NOT NULL
);
