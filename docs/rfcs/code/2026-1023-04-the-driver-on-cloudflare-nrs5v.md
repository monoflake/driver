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
  Trigger, where the Options had a Durable Object and its alarm; the instance kind waits. **The
  Cron Trigger is struck by monoflake/cloud's RFC rxmd9**, which puts every timer on a machine: the
  grace is swept as each request to the management arrives, never one to a kind, and which machine
  calls the sweep on a timer, and how, is **Pending**.
- **A database is D1.**
- **The first slice is management and function**, hello deployed through the platform to the test
  account; then object on R2; then database on D1.
- **Settled as it is built, provisionally, and written here then**: how a deployment's `network` is
  answered where it cannot be enforced; whether the binding's token or its hash is the Worker's
  secret; the account's Workers subdomain or a Custom Domain for a deployment's name; a bucket per object item or a
  prefix in one; how D1's size is held to an item's capacity. The first slice's, each provisional,
  chosen by the advisor on 2026-10-24:
  - **Names.** The driver's Worker is `driver` and its D1 database `driver`, its tables `held`, one
    row of the generation, the policy and the grace, `items`, `tokens` and `deployments`. Its
    account's token is the secret `API_TOKEN`, an account-owned token holding Workers Scripts Edit
    alone, and the account's id the variable `ACCOUNT_ID`.
  - **The binding's token** is kept as its BLAKE3 in hex, the secret `BINDING`, as RFC 3d3nt keeps
    only a hash; once an `apply` carries `tokens`, the list in D1 stands in its place.
  - **A deployment's Worker** is `app-<id>`, or `component-<name>` for a component, with no prefix,
    a binding being an account of its own. Its version is the tag `version-<hash in hex>`, cut
    short where a tag holds less, the rule written here when it is. Its address is
    `<Worker>.<the account's subdomain>.workers.dev`, a Custom Domain waiting on a domain, RFC
    vr5lw.
  - **Stopping** deploys a stub version answering every request 503 `stopped`, and keeps the
    version it replaced in D1, which resuming deploys again in whole.
  - **The footing** is a plain text binding, `MONOFLAKE_FOOTING`, as driver(machine) names it to a
    worker, and a deployment's secrets are secret text bindings.
  - **A deployment's `network`** asking `udp` or `icmp` is refused as `beyond_host`, a Worker having
    neither; one asking `http`, `tcp` or both is taken, and since an ordinary account holds no
    Worker back from `fetch` or `connect()`, the driver logs a warning at deploy naming each way out
    given beyond those asked; the paid namespace's outbound Worker would hold it to them. This
    replaces the advisor's first choice, refusing whatever asked less than every way out, which
    refused hello and every sample's deploy.
  - **The management's state is read and written whole**, its sweep writing only where an item's
    grace has passed. It rests on the control calling the management one call at a time: D1's batch
    makes a write one transaction, but leaves a race between a read and the write after it.
  - **A database item** is held `failed` as `beyond_host`, its message that it waits on this RFC's
    third slice, until that slice is built.
  - **Implementers' defaults, let stand by the advisor**: an artifact past 64 MiB is refused as
    `too_large`; a list holding a `container` or `volume` item is refused whole as `beyond_host`, as
    driver(machine) refuses a list it cannot hold; a bundle's `.json` module is refused as
    `beyond_host`, since turning JSON into an ES module goes past mapping the metadata field for
    field, until an app needs one; a version's tag is 72 bytes, within the 100 a tag holds, so none
    is cut.
  - **Its tests** are each block's own, Cloudflare's API answered by fixtures taken from its
    documents' examples, each naming its address; the function's samples run against those fakes,
    and the program's are the management's three and `lifecycle.json`.

  The second slice's, object on R2, each provisional, chosen by the advisor on 2026-10-24:
  - **A binding holds one bucket**, as driver(machine)'s `bucketed` holds one, so a bucket per item
    or a prefix in one is answered by neither: a list holding two `object` items or more is refused
    whole as `beyond_host`, and one holding an item past 1 TiB too, the most this driver takes
    while its cost is watched.
  - **Names.** The adapter is the block `cloudflare/object` and the Worker `object`, its bucket
    `objects` and its account in the driver's D1 the table `objects`, the bucket and the table one
    word since they name one thing; it answers `POST /object/{operation}`, the binding's token
    held as the driver holds it.
  - **The Worker `object` and the bucket `objects` are made with the Worker `driver`**, by
    wrangler, so `API_TOKEN` holds nothing of R2; with no `object` item a read answers
    `not_found` and a list nothing, as on a machine. An `object` item is `made` at the Worker
    `object`'s address.
  - **What the bucket holds** is counted in `objects`, a write past the item's size refused as
    `storage_full` and an object past 16 MiB as `too_large`. A second write to one key within a
    second, which R2 refuses, is a `fault` whose message names R2's limit on a key and asks for a
    retry, never `storage_full`, which would tell a caller to make room, RFC 49qyg.

Out of date in this repository's neighbors, to be corrected when one is decided: a Worker's size is
64 MiB uncompressed on every plan, where RFC vr5lw and `monoflake/platform`'s
`docs/lessons/cloudflare.md` say 3 MB free and 10 MB paid, compressed; D1 keeps seven days of Time
Travel on free; on a free account Workers, Durable Objects and D1 fail past their limits where R2
alone bills.
