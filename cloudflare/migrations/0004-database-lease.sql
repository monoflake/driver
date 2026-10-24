-- The database handed to an item under a lease, RFC nrs5v, database/src/held.res; an applied
-- migration is never edited.

-- `cleared` is 1 once the database was emptied for the item, and `clearing_since` in milliseconds
-- when the call clearing it took its lease; a row from before was cleared as it was handed.
ALTER TABLE database_held ADD COLUMN cleared INTEGER NOT NULL DEFAULT 1;
ALTER TABLE database_held ADD COLUMN clearing_since INTEGER NOT NULL DEFAULT 0;
