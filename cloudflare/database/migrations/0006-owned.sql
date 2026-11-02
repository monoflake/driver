-- Each name the driver holds on the account and its role, RFC nrs5v's bare ids, src/owned.res; an
-- applied migration is never edited.

-- `state` is this D1, `driver`, `object` and `database` the Workers, `bucket` the bucket and
-- `user_database` the database kind's D1, each written by install before it makes them, and
-- `deployment` a deployment's Worker, written before the first call that makes it.
CREATE TABLE owned (
	name TEXT PRIMARY KEY,
	role TEXT NOT NULL CHECK (
		role IN ('state', 'driver', 'object', 'bucket', 'database', 'user_database', 'deployment')
	)
);

-- Each of the driver's own parts is one name.
CREATE UNIQUE INDEX owned_part ON owned (role) WHERE role != 'deployment';

-- A deployment's Worker kept before is the driver's own, since it made it, a listed one excepted,
-- and one listed and released since, its row kept beside its warning.
INSERT INTO owned (name, role)
SELECT worker, 'deployment' FROM deployments
WHERE worker NOT IN (SELECT name FROM adopted) AND worker NOT IN (SELECT name FROM warnings);
