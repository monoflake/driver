---
name: 'The Driver on Cloudflare'
title: '`driver(cloudflare)`: where it runs, how a binding is kept apart, and what each kind is on an account'
status: accepted
supersedes: []
blocked-by: []
commits: []
references:
  - url: https://developers.cloudflare.com/workers/platform/limits/
    took: "a request's CPU, subrequests, Workers an account and a Worker's size of 64 MiB on every plan"
  - url: https://developers.cloudflare.com/d1/platform/limits/
    took: 'ten databases of 500 MB on free and 10 GB on paid, the queries an invocation'
  - url: https://developers.cloudflare.com/d1/reference/time-travel/
    took: 'seven days of Time Travel on free and thirty on paid'
  - url: https://developers.cloudflare.com/durable-objects/platform/limits/
    took: "a SQLite class's limits on free"
  - url: https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/
    took: "a database's size and bookmarks inside a Durable Object"
  - url: https://developers.cloudflare.com/r2/get-started/
    took: 'the subscription R2 asks even for its free tier'
  - url: https://developers.cloudflare.com/r2/platform/limits/
    took: 'one write a second to a key and a key of 1,024 bytes'
  - url: https://developers.cloudflare.com/r2/api/workers/workers-api-reference/
    took: 'put, get with a range, head, delete and list as the object contract asks them'
  - url: https://developers.cloudflare.com/workers/configuration/multipart-upload-metadata/
    took: "an upload's main module, compatibility date, flags and bindings"
  - url: https://developers.cloudflare.com/cloudflare-for-platforms/workers-for-platforms/platform/pricing/
    took: "a dispatch namespace's price, not on the free plan"
  - url: https://developers.cloudflare.com/fundamentals/api/get-started/account-owned-tokens/
    took: 'an account-owned token scoped to one account'
  - url: https://developers.cloudflare.com/workers/configuration/routing/custom-domains/
    took: "a Custom Domain's hostname, record and certificate"
---

## Question

`monoflake/platform` asks `driver(cloudflare)` for function, instance, object and database through
their contracts, the `workers` runtime taking `modules` on `isolate`, `model/ground/drivers.res`;
none of it is built. Where does the driver run, how is one binding kept apart from another on an
account, and what is each kind there, first on a free account. Read from Cloudflare's documents
on 2026-10-23 by a research worker; what only running tells is marked to try.

## Options

Raised with the author on 2026-10-23, from a research worker's reading of Cloudflare's documents.

- **Where it runs**: Workers on the bound account, as RFC vr5lw reads, a driver Worker serving
  management and deployments, its state in one SQLite Durable Object whose alarm keeps the grace,
  an adapter Worker each for object and database; or a process elsewhere calling the API, with no
  CPU limit but a ground the model lacks; or a command that installs those Workers. On a free
  account a request has 10 ms of CPU and 50 external subrequests; fetching, hashing, untarring and
  uploading hello is to try.
- **A binding kept apart**: an account per binding, Cloudflare's own isolation, each with its whole
  free plan; a prefix in one account, `b<binding>-`, the driver's isolation alone, the account's 100
  Workers, 100 Durable Object classes and 10 D1 databases shared; or a Workers for Platforms
  namespace per binding, which alone enforces a deployment's `network` and bounds its CPU, at 25
  US dollars a month and not on the free plan. The first two can stand together.
- **The plan**: free, with small declared bounds, an artifact near 1 MiB until measured; or paid.
  Either way on an account apart from the platform's own, which is never bound, RFC v7v3w.
- **function**: a deployment a Worker, its tar's `metadata.json` mapped field for field onto the
  upload's metadata, its version kept as a tag so a deploy sent again does nothing, its address
  its the account's Workers subdomain name, stopped by a stub version answering `stopped` and resumed by the version
  it replaced. `network` cannot be enforced on an ordinary account: refuse what asks less than
  every way out, accept it with a warning, or an outbound Worker on the paid namespace.
- **instance**: a SQLite Durable Object class per deployment, its bundle naming the class as RFC
  dg903 proposes, its first deploy by the script upload that alone takes a migration.
- **object**: R2, which needs its subscription checkout even for the free tier and bills past it
  with no cap; an item a bucket of its own or a prefix in one bucket per binding; capacity counted
  by the adapter, R2 having no quota; one write a second to a key, so a sample may need a retry.
- **database**: D1, ten an account and seven days of Time Travel on free, so the contract's thirty
  days fail there, no way found to cap a database's size, its rewind a REST call needing a D1 token;
  or a Durable Object's SQLite, no count limit, thirty days, its size likely checkable inside a
  transaction; or both, by size.
- **The binding's token**: a Worker secret holding it, so the account holds the token itself where
  RFC 3d3nt keeps only its hash; or a secret holding `<id>.<hash>`.
- **Names**: the account's Workers subdomain; a Custom Domain per deployment on a zone the account holds; or a gateway
  Worker, whose dispatch is static without the paid namespace.
- **The token the driver holds**: an account-owned API token scoped to one account, Workers Scripts
  Edit for function and instance, R2 Storage Edit only if the driver makes buckets, D1 Edit only
  for D1, zone Workers Routes and DNS Edit only for names on a zone.
- **The first slice**: management and function, hello deployed through the platform to an account,
  then object.

## Decision

Decided by the author on 2026-10-23, from the research the Options below record.

- **The driver runs as Workers on the bound account**, as RFC vr5lw reads: a driver Worker serving
  management and deployments, an adapter Worker each for object and database.
- **A binding is an account of its own**, kept apart by Cloudflare: the first is a test account of
  the author's, apart from the platform's own, which is never bound, RFC v7v3w.
- **On the paid Workers plan the author holds**, so a request has the paid plan's CPU and D1 keeps
  thirty days of Time Travel. **Its cost is watched**: whatever a test makes on the account is
  removed when the test ends, and a run reports what it left.
- **Workers, R2 and D1 alone, no Durable Object yet**: the driver's own state, its tokens' hashes,
  its lists and when each item went unasked, is kept in D1, and the grace is swept by a Cron
  Trigger, where the Options had a Durable Object and its alarm; the instance kind waits.
- **A database is D1.**
- **The first slice is management and function**, hello deployed through the platform to the test
  account; then object on R2; then database on D1.
- **Settled as it is built, provisionally, and written here then**: how a deployment's `network` is
  answered where it cannot be enforced; whether the binding's token or its hash is the Worker's
  secret; the account's Workers subdomain or a Custom Domain for a deployment's name; a bucket per object item or a
  prefix in one; how D1's size is held to an item's capacity.

Out of date in this repository's neighbors, to be corrected when one is decided: a Worker's size is
64 MiB uncompressed on every plan, where RFC vr5lw and `monoflake/platform`'s
`docs/lessons/cloudflare.md` say 3 MB free and 10 MB paid, compressed; D1 keeps seven days of Time
Travel on free; on a free account Workers, Durable Objects and D1 fail past their limits where R2
alone bills.
