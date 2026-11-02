-- What each deployment's row stands for, RFC nrs5v's Ledger, src/kept.res; an applied migration is
-- never edited.

-- `runs` the deployment it is, `app <id>` or `component <id>`, a row taken by it and never by its
-- Worker's name alone; a row from before holds none, so no deployment reads it.
ALTER TABLE deployments ADD COLUMN runs TEXT;
