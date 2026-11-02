-- The driver's state, RFC nrs5v, src/kept.res; an applied migration is never edited.

-- One row, the list's generation, the policy's and its grace in seconds, a binding new holding a
-- week; `listed` is 1 once an apply named the tokens, which `tokens` then holds.
CREATE TABLE held (
	one INTEGER PRIMARY KEY CHECK (one = 1),
	generation INTEGER NOT NULL,
	policy INTEGER NOT NULL,
	grace INTEGER NOT NULL,
	listed INTEGER NOT NULL
);
INSERT INTO held (one, generation, policy, grace, listed) VALUES (1, 0, 0, 604800, 0);

-- Each item of the list, its capacity by kind, `bytes` its memory or size, its credentials' BLAKE3
-- in hex separated by spaces, and where it stands, `since` in milliseconds.
CREATE TABLE items (
	id INTEGER PRIMARY KEY,
	kind TEXT NOT NULL,
	millicores INTEGER,
	bytes INTEGER NOT NULL,
	credentials TEXT NOT NULL,
	state TEXT NOT NULL,
	address TEXT,
	reason TEXT,
	message TEXT,
	since INTEGER
);

-- The binding's tokens in force by the BLAKE3 of each secret in hex, RFC 3d3nt.
CREATE TABLE tokens (hash TEXT PRIMARY KEY);

-- Each deployment by its Worker, the version it runs in hex, and the version a stop replaced.
CREATE TABLE deployments (
	worker TEXT PRIMARY KEY,
	version TEXT NOT NULL,
	state TEXT NOT NULL,
	reason TEXT,
	replaced TEXT
);
