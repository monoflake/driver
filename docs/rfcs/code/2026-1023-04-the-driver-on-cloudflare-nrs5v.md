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
  - **An item's objects are kept apart by its id**, each key `<item id>/<name>` and each row of
    `objects` naming its item, and the Worker `object` reads and writes under the prefix of the one
    `object` item made now alone, so a new item never sees an ended one's objects, as a machine's
    volume goes with its item. What belongs to no item made now is deleted a batch at a time, at
    most 1,000 keys on each request the Worker `object` answers, the driver binding no R2. Its cost
    is that what an ended item left stays in the bucket while no request comes.
  - **Implementers' defaults, let stand by the advisor**: a new `object` item is failed as
    `beyond_host` while an older one unasked still holds the bucket, as `bucketed` does; a list's
    `after` is R2's `startAfter`; a range past an object's end is read empty with its size; an
    object call's body is bounded as driver(machine)'s `LARGEST_OBJECT`, refused as `malformed`
    past it.
  - **What is cleared and what is counted, after review**: a prefix or a row is cleared only where
    its item is absent from the driver's `items`, read after the bucket was listed, so an item that
    exists keeps its keys though it holds the bucket no more, until the driver removes it; after a
    put, its row is settled by a head of the key, forgotten where the key is gone, and where the put
    and that head both fail it goes back to what it counted before; where the put succeeds and
    the head fails, it counts what was written. One gap is left: a put settling
    its row between a delete's removal of the key and of its row leaves that object uncounted,
    closing which would ask a head after every delete.
  - **A binding holds one database**, as it holds one bucket: a list holding two `database` items
    or more is refused whole as `beyond_host`, and one past 10 GB too, D1's bound on a database; a
    new item is failed as `beyond_host` while an older one unasked still holds it.
  - **Names.** The block `cloudflare/database`, the Worker `database` and its D1 database
    `database`, made with the rest by `install` where `DRIVER_LOCATION` places them, answering
    `POST /database/{operation}`, the binding's token held as the driver holds it; a `database`
    item is `made` at the Worker's address.
  - **A new item holds nothing of an old one.** The driver's D1 records which item the database
    is held for, and the first request for another drops every object a user made in it, tables,
    indexes, views and triggers, and none named `_cf_` or `sqlite_`; a rewind to a moment before
    the item was made, or within a second after, is refused as `beyond_window`, the second a margin
    for the Worker's clock against D1's, until a live account shows whether a Time Travel bookmark
    taken after the clear can bound it instead. What an ended item left stays while no request
    comes. The item is taken over by one conditional update of `database_held`, and only the call
    that changed it clears. One gap is left: a call of the old item that found it held before the
    old item ended, its batch landing after the clear, writes into the new item's database; a
    marker checked by every batch would close it, which waits on the author.
  - **A rewind is Time Travel's restore**, a REST call, by a token of its own holding D1 Edit
    alone, the Worker `database`'s secret `API_TOKEN`, which `install` reads from
    `DATABASE_API_TOKEN`; the account's id and the database's are its variables. Thirty days are
    kept, the paid plan's.
  - **A database's size** is held two ways. Before a batch runs, its statements' and parameters'
    bytes are added to the size last read, and a batch that would pass the item's size is refused
    as `storage_full`; after it runs, `size_after` is kept, and once it holds the item's size every
    write is refused alike. What passes the size is what that reckoning misses, an index's or a
    page's own room. Ending each batch with a statement that fails past the size, so D1 rolls the
    batch back, waits on a live account showing D1 answers `pragma_page_count`, and replaces the
    reckoning then.
  - **Its samples** are `statements.json`, `batches.json`, `limits.json` and `rewinds.json`;
    `copies.json` is left out, since the driver sees one copy of a D1 database and cannot be
    read-only below a majority of copies.
  - **What D1 cannot answer as the contract asks**: an integer and a real alike come back as
    numbers, so a whole real reads as an integer; an integer past 2^53 is found once the batch
    ran, so a write returning one has already happened; and a batch's rows come back as objects,
    workerd's `batch()` ending in `toArrayOfObjects` (`src/cloudflare/internal/d1-api.ts`), so a
    result's columns are read from its first row, in the order JavaScript gives an object's keys,
    integer-like names first, a statement with no rows names none, and two columns of one name are
    one. `raw()` keeps them but runs one statement alone with no meta, so
    a batch stays one transaction with its `size_after` and `changes`. A batch of reads alone is
    never refused for room.
  - **Implementers' defaults, let stand by the advisor**: a statement of at most 100,000 bytes, D1's
    own; a call's body of at most 100,000,000, a Worker's request's; 10 GB as 10^10 bytes; with no
    `database` item an execute is `storage_full` and a rewind `beyond_window`; only `SELECT`,
    `EXPLAIN` and `VALUES` are reads, so a full database refuses `WITH` and `PRAGMA` too; D1's
    errors read by their `SQLITE_` code or words. The item a database is held for is the one row
    of the driver's table `database_held`, its item, `since` and the `size` last read.

  What makes it on an account, provisional, chosen by the advisor on 2026-10-24:
  - **`mise run install`**, `scripts/install.res` beside `archive` and `dev`, makes what is absent
    and passes over what is there, as monoflake/cloud's `install` does: the D1 database `driver`
    and its migrations, the bucket `objects`, the Workers `driver` and `object` with the database's
    id and the account's in a configuration of the moment, a deploy passed over where nothing
    changed, and each secret put only where its name is missing; `--dry-run` prints each wrangler
    command, a secret by its name alone.
  - **What it is given comes from the environment**, this repository being public: wrangler's own
    `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`, and the Worker `driver`'s `API_TOKEN` as
    `DRIVER_API_TOKEN`. The binding's token is read on stdin, as `driver-machine bind` reads it,
    and put as `BINDING` by its BLAKE3; with nothing on stdin that step is passed over, how a
    binding is made waiting on monoflake/platform's RFC 7i2at.
  - **Where the parts are placed is `DRIVER_LOCATION`**, a location hint given to the database and
    the bucket, `wnam` on the test account; with none given no hint is passed and Cloudflare places
    them, so a user binding an account of their own chooses. `install` builds each Worker's package
    before it bundles it.

Out of date in this repository's neighbors, to be corrected when one is decided: a Worker's size is
64 MiB uncompressed on every plan, where RFC vr5lw and `monoflake/platform`'s
`docs/lessons/cloudflare.md` say 3 MB free and 10 MB paid, compressed; D1 keeps seven days of Time
Travel on free; on a free account Workers, Durable Objects and D1 fail past their limits where R2
alone bills.
