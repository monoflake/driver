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
- **A binding is an account of its own**, kept apart by Cloudflare, apart from the platform's own,
  which is never bound, RFC v7v3w.
- **On an organization's own free account**, amended by the author on 2026-10-24, which struck "on
  the paid Workers plan the author holds": an organization brings its own free account for light
  work and front ends. There the driver offers `function`; `object` only where the account has R2
  enabled, since R2 asks a payment method even on its free tier; and never `database`, an
  organization's databases going on vendor machines through driver(machine). The free plan's 10 ms
  of CPU a request is measured on the first deploy. **Its cost is watched**: whatever a test makes
  on the account is removed when the test ends, and a run reports what it left.
- **Everything the driver makes is named by an id, on any account**, decided by the author on
  2026-10-24. Listing, clearing and sweeping treat any resource whose name is not in the driver's id
  form as absent, never read, changed or removed: the bound account may already hold the
  organization's own Workers, D1 databases and buckets, and a Cloudflare token cannot be scoped to
  names, so the driver's own discipline is the guard. A binding stays an account of its own; the id
  form only makes a shared account safe to bind.
- **Bare ids, ownership by record**, decided by the author on 2026-10-24, RFC b8f35's rule and no
  new one, replacing the install id's names. A resource the driver holds for the platform is named
  by that resource's id, the scope's 8 hex digits, bare, with no prefix: a deployment's Worker by
  its deployment's resource id, and an item by its id where it is held. What the driver holds for
  itself, its own Worker, its state D1, its adapter Workers, and the bucket and user D1 it makes at
  install, gets 8 hex digits it draws and checks against the account's existing names, likewise
  bare. Before every call to Cloudflare the target name must be in the driver's own records, its
  state D1, with its role; a name the records do not hold is never touched, whatever it looks like.
  The one exception is the state D1 itself, found on reinstall by its marker table, since the
  records cannot be read before it is found; the install id becomes that database's own drawn id,
  and the marker rule stands. The exception list is unchanged, its exact names adopted by record
  too. Recognising "ours" by a name's shape needed the marker patch after a foreign `driver-<8 hex>`
  database could be taken; recognising it by record removes that class of mistake, and a public
  app's address carries no role and number.
- **An exception list, decided in principle by the author on 2026-10-24**: an organization's admin
  may register named resources the driver also manages, each mapped to an item id, so what is
  managed is the id-form resources and that list, and everything else is ignored. Its two details,
  decided by the author on 2026-10-24:
  - **Exact names only**, never patterns, since a pattern would silently take over a resource the
    organization makes later.
  - **A listed resource is only ever updated, never deleted.** When its item is unasked, swept, or
    would be removed, the driver lets it go untouched and tells the admin to delete it by hand in
    the vendor's own dashboard, naming the resource. Only id-form resources are managed fully
    automatically, deletion included: a listed resource was the organization's before the platform
    came, so the worst a bug can do to it is overwrite it, never make it vanish.
- **The order of testing**, decided by the author on 2026-10-24: first an empty test account made
  for the test; an organization's own free account is bound only after conform passes and clearing
  is proven on the empty one. What a test makes is still removed when it ends.
- **Workers, R2 and D1 alone, no Durable Object yet**: the driver's own state, its tokens' hashes,
  its lists and when each item went unasked, is kept in D1, and the grace is swept by a Cron
  Trigger, where the Options had a Durable Object and its alarm; the instance kind waits. **The
  Cron Trigger is struck by monoflake/cloud's RFC rxmd9**, which puts every timer on a machine: the
  grace is swept as each request to the management arrives, never one to a kind. **Which machine
  calls the sweep on time was decided by the author on 2026-10-24**: the grace is event-driven. When
  an applied list leaves an item on a Cloudflare binding unasked, its grace end is known, and that
  event sets one tick at that time; at the tick the binding's management is called once, and that
  request's arrival sweeps what is past grace. The sweep on every management request stays as the
  fallback, ticks being at least once and the sweep idempotent. The tick is the clock of
  monoflake/platform's RFC p6fg3, which the platform above takes from the compute product of the
  platform beneath.
- **A database is D1**, where `database` is offered.
- **Each `database` item gets a D1 of its own**, decided by the author on 2026-10-24, made for it
  and removed with it, never handed to another item; this supersedes "a binding holds one
  database" below. With no hand-over there is nothing for a late write to land in, so the gap the
  clearing lease leaves is closed by design. Rejected: a guard statement before every batch, which
  patches the hand-over, and leaving the gap. It is built when `database` is first offered on a
  Cloudflare binding, since an organization's free account is not offered it, so nothing uses it
  today; until then the one database, its clearing lease and its change of owner below stand, and
  they are replaced once it is built. Its cost: the free plan allows 10 D1 databases an account,
  the paid plan many more.
- **The first slice is management and function**, hello deployed through the platform to an empty
  test account; then object on R2; then database on D1.
- **Settled as it is built, provisionally, and written here then**: how a deployment's `network` is
  answered where it cannot be enforced; whether the binding's token or its hash is the Worker's
  secret; the account's Workers subdomain or a Custom Domain for a deployment's name; a bucket per object item or a
  prefix in one; how D1's size is held to an item's capacity. The first slice's, each provisional,
  chosen by the advisor on 2026-10-24, each name of a resource since a bare id, as the Decision has
  it:
  - **Names.** The driver's Worker is `driver` and its D1 database `driver`, its tables `held`, one
    row of the generation, the policy and the grace, `items`, `tokens` and `deployments`. Its
    account's token is the secret `API_TOKEN`, an account-owned token holding Workers Scripts Edit
    alone, and the account's id the variable `ACCOUNT_ID`.
  - **The binding's token** is kept as its BLAKE3 in hex, the secret `BINDING`, as RFC 3d3nt keeps
    only a hash; once an `apply` carries `tokens`, the list in D1 stands in its place.
  - **A deployment's Worker** is named by its deployment's resource id, bare, an app's or a
    component's. Its version is the tag `version-<hash in hex>`, cut
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
    comes. The item is taken over by one conditional update of `database_held`, which records it
    not yet cleared under a lease of 30 seconds; the call that changed it clears, every DROP
    carrying IF EXISTS so a clear runs again, and records `since` once the clear is done. A call of
    the item while the lease is fresh is answered `overloaded`, and one finding it passed takes it
    by a conditional update and clears again. One gap is left: a call of the old item that found it held before the
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
    numbers, so a whole real reads as an integer; a value of no known type, a number not finite
    and an integer past 2^53 are found once the batch ran and answered as errors, so a write
    returning one has already happened; and a batch's rows come back as objects,
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
  - **`mise run install`**, `scripts/install/install.res` beside `archive` and `dev`, makes what is
    absent and passes over what is there, as monoflake/cloud's `install` does: the D1 database
    `driver` and its migrations, the bucket `objects`, the Workers `driver` and `object` with the
    database's id and the account's in a configuration of the moment, a deploy passed over where
    nothing changed, and each secret put only where its name is missing; `--dry-run` prints each
    wrangler command, a secret by its name alone.
  - **What it is given comes from the environment**, this repository being public: since
    2026-10-24 `DRIVER_ACCOUNT_ID` and `DRIVER_INSTALL_TOKEN` for itself, never the ambient
    `CLOUDFLARE_*` names, as the Ledger has it, and the Worker `driver`'s `API_TOKEN` as
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

### Ledger

Choices made provisionally while the thread runs, read by the author at its end.

- **The install id's names, `<role>-<install id>`, and ownership by a name's ending** were the
  advisor's provisional choices of 2026-10-24, replaced the same day by the author's bare ids,
  ownership by record, in the Decision.
- **Which kinds the driver offers is chosen at install by the input `DRIVER_KINDS`**, defaulting to
  `function`, provisional, chosen by the advisor on 2026-10-24. Management describe reports the
  kinds offered.
- **`DRIVER_KINDS` is comma-separated values from `function`, `object` and `database`**, the default
  `function`, recorded as the Worker `driver`'s var `KINDS`, provisional, chosen by the advisor on
  2026-10-24.
  - The Worker `driver-…` and the D1 `driver-…` are made whatever the kinds are, since they are
    management and the driver's state, not `function`'s.
  - `function` adds no resource. `object` adds its bucket and Worker; `database` adds its D1 and
    Worker.
  - On a rerun, install adds what a kind newly listed needs. It never removes what a kind dropped
    from the list holds; it reports those resources by name instead.
- **A list naming a kind not offered is refused whole as `beyond_host`**, provisional, chosen by the
  advisor on 2026-10-24, as `container` and `volume` are refused today.
- **How install recovers its install id**, provisional, chosen by the advisor on 2026-10-24, the
  first rule replaced since it took any name of the form for an install:
  - A D1 is the driver's only when its name is 8 hex digits and it holds the driver's marker, its
    `install` table naming that same id, read by a read-only query.
  - A name of that form without the marker is foreign. It is never migrated or written, and the
    dry run names it as passed over.
  - Recovery counts marked databases alone: none, draw; one, reuse; more, refuse and list them.
  - A drawn id is drawn again while any existing D1 or Worker name ends in it.
  - install writes the marker first, in the same step that makes the database, before any other
    migration.
  - Every Worker gets the var `INSTALL_ID`, and the driver forms every name and address from it.
- **`DATABASE_API_TOKEN` is asked for only where `database` is offered**, provisional, chosen by the
  advisor on 2026-10-24.
- **Install never reads the ambient `CLOUDFLARE_*` names**, provisional, chosen by the advisor on
  2026-10-24, since a repository's environment may hold the platform's own account, which is never
  bound, RFC v7v3w.
  - It reads `DRIVER_ACCOUNT_ID` and `DRIVER_INSTALL_TOKEN` for itself and `DRIVER_API_TOKEN` for
    the Worker.
  - It hands wrangler `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` only in the environment of
    its own child processes, set from those, so an ambient value never reaches wrangler.
  - It refuses to run when `DRIVER_ACCOUNT_ID` is unset, rather than falling back.
  - Every `CF_*` name is stripped from a child's environment as well, and wrangler is kept from
    reading `.env` files, since wrangler 4 still reads the older names and loads `.env` and
    `.env.local` before every command, after review on 2026-10-24.
- **The exception list reaches the driver through management**, provisional, chosen by the advisor
  on 2026-10-24: `apply` carries it, the driver keeps it in its state, and management describe
  reports every listed name and its item.
- **The "delete it by hand" message is a warning on describe**, provisional, chosen by the advisor
  on 2026-10-24, naming each released resource, kept until that resource no longer exists.
- **A field carrying the list in a kind's management contract is monoflake/platform's**,
  provisional, chosen by the advisor on 2026-10-24: it is reported as a fact before building, and
  recorded in platform's RFCs, citing nrs5v.
- **A listed Worker stands for a deployment**, provisional, chosen by the advisor on 2026-10-24: an
  app's id or a component's name, as the deployments interface identifies it. The driver then
  deploys that deployment to the listed name instead of its own id. It is that
  deployment's Worker, never a management item. A listed bucket or D1 stands for a management
  item's id.
- **With `KINDS` lacking `function`, every deployments call is refused as `beyond_host`**,
  provisional, chosen by the advisor on 2026-10-24, as a list naming a kind not offered is refused.
- **The dry run says which, by a read-only `d1 list`**, provisional, chosen by the advisor on
  2026-10-24, a dry run writing nothing rather than reading nothing. Where the account cannot be
  read, for want of credentials or a failed list, it prints the rule and says why it could not say
  which.
- **A misinstall fails closed, answered `fault`, never `denied`**, provisional, chosen by the
  advisor on 2026-10-24: `denied` is a caller's credential missing or wrong, RFC fhg6w, and a bad
  install the implementation's own fault, RFC ge55b. `INSTALL_ID` unset or malformed, and `KINDS`
  unset, empty or holding an unknown kind, all answer `fault`, naming the variable in the message.
  install always writes `KINDS`, validated before anything deploys, `function` its default, so
  `KINDS` unset at run time is a broken install, not a default.
- **To try on the empty test account**, provisional, chosen by the advisor on 2026-10-24: install
  finding what a dropped kind left by `wrangler versions list --json --name <Worker>`.
- **Reasons the deployments contract already declares**, provisional, chosen by the advisor on
  2026-10-24, monoflake/platform's contract unchanged. With `KINDS` lacking `function`, `deploy`
  answers `beyond_host`, since the host cannot hold it, and `stop`, `resume` and `describe` answer
  `not_found`, since no deployment can exist on a binding that offers no `function`; `delete` as
  the entry below has it. A name check
  refusing a name the driver formed itself is the implementation's own inconsistency, so it answers
  `fault` on every operation. A name entering through the exception list is checked against the
  list, once the list is built.
- **A dry run lists the missing inputs**, provisional, chosen by the advisor on 2026-10-24, runs
  nothing that needs them, and exits 0 once it has reported; a real run refuses when any input is
  missing.
- **Every read-only check install makes runs before its first write**, provisional, chosen by the
  advisor on 2026-10-24: the D1 list and the marker reads, the dropped kinds' queries, and the
  inputs and kinds validation. A failed check stops install with nothing changed.
- **`through` carries `installId: string`**, provisional, chosen by the advisor on 2026-10-24, the
  same decision as keeping the install id in the model with no casts.
- **The marker goes first, in a table of its own**, provisional, chosen by the advisor on
  2026-10-24, replacing the order first built.
  - Right after the D1 is made, before any migration, one `d1 execute` creates a table `install`
    holding the install id and inserts it.
  - The migrations never touch that table, and the recovery rule reads it.
  - The marker column 0005 adds to `held` is dropped, which is safe since 0005 has never run on any
    account.
  - That shrinks the orphan window to the gap between making the database and its first statement,
    a gap two API calls cannot close.
  - For what is left: a database named by 8 hex digits with no tables at all is reported by the dry
    run and the run as "possibly an interrupted install of this driver; delete it by hand if it is
    yours". It is still never touched, and a non-conflicting id is drawn.
- **curl for List Workers, the token on stdin as a header**, provisional, chosen by the advisor on
  2026-10-24, wrangler listing no Workers. If paging exists, install reads every page before
  deciding anything; a list it could not read whole counts as a failed read-only check, so install
  stops with nothing changed.
- **`delete` answers Success with no Cloudflare call when `KINDS` lacks `function`**, provisional,
  chosen by the advisor on 2026-10-24, replacing `not_found` for `delete` alone: it keeps the
  contract's own delete, where deleting what does not exist succeeds, and keeps "install never
  removes what a dropped kind holds". `stop`, `resume` and `describe` keep `not_found`.
- **Also to try on the empty test account**: whether `d1 execute <name> --remote` resolves a name
  with no configuration and its `--json` form, the text of a missing table, whether one `d1 execute
  --command` runs two statements apart by `;`, whether D1 answers a query of `sqlite_master`, and
  whether List Workers, read by curl since wrangler lists no Workers, pages its answer; its
  documentation shows no paging, so install reads one answer and refuses one that says it is part.
- **The component that sets the tick is the control of the platform above**, provisional, chosen by
  the advisor on 2026-10-24, the one that applied the list. It reads each unasked item's grace end
  from the binding's answer.
- **A tick carries only its row's id**, provisional, chosen by the advisor on 2026-10-24, as
  `?clock`'s contract says.
- **Settled by the first install on an empty test account, 2026-10-24**: `d1 execute --remote`
  finds a database by its name with no configuration, and the marker's two statements, apart by
  `;`, run in one `--command`; the migrations apply; the free plan deploys the Worker `driver-…`,
  the account's Workers subdomain enabled first by hand. Still to try: List Workers paging, the
  not-found code, a query of `sqlite_master` on an account holding a foreign database, and the free
  plan's 10 ms of CPU under a deploy.
- **A component deployed into a scope is that scope's resource**, provisional, chosen by the advisor
  on 2026-10-24, so it gets a b8f35 resource id, 8 hex digits. The deployer draws it, the control
  above the binding, as it draws every id in the scope; the driver never does. So
  `deployment-runs`' `component` case gains an `id` beside its name, and the component's Worker is
  named by that id like an app's. Every resource in an organization carries the organization-unique
  id, whatever its kind; a driver is beneath the scope and mints only ids for its own parts, never
  the scope's. Until the control draws ids per b8f35, numbering apps 1, 2, `00000001`-style names
  are the scaffold's form.
- **The matcher passes over fields a sample does not write, with `$absent` for a field that must be
  missing**, provisional, chosen by the advisor on 2026-10-24: RFC p8e8k's landed rule, "what a
  sample names is checked, and nothing else", so the old whole-set match was the deviation.
- **describe never writes**, provisional, chosen by the advisor on 2026-10-24. It leaves a warning
  out of its answer once the resource is gone, and the row is removed by the next apply or by the
  sweep, which already writes only when something changed. A read that writes is how the overwrite
  risk between the sweep and the control's update arose, so describe stays a read.
- **"Gone" is not taken from `running`**, provisional, chosen by the advisor on 2026-10-24, but from
  whether the script exists at all, a read of that script by name or List Workers, so "exists but
  never deployed" is never read as gone.
- **Three edges of the exception list**, provisional, chosen by the advisor on 2026-10-24, the name
  check being "in the driver's records, or on the exception list":
  - A listed name the driver's own records already hold, a resource it made itself, refuses the
    apply with a reason apply already declares: adopting what is already owned is a contradiction,
    not an update.
  - Pointing a listed name at another deployment in one apply is refused. Moving a name takes two
    applies, one dropping it, released with the `delete_by_hand` warning, and one adding it for the
    new deployment, so no running deployment loses its Worker silently.
  - A name dropped from the list releases its deployment's row in the same apply: the resource is
    left untouched, the `delete_by_hand` warning is raised, and the row stays only as long as that
    warning does.
- **Tried on the empty test account, 2026-10-24**: Workers, D1 and R2 accept names of 8 hex digits
  that begin with a digit; a missing script reads as code 10007; `wrangler delete` removed the
  script but answered `Authentication error [code: 10000]` on its next call, a list of the account's
  KV namespaces, which the install token may not read and the driver never needs; the test account
  has R2 enabled and the install token holds R2 rights, so `object` can be tried there by installing
  with `DRIVER_KINDS=function,object` once the bare names land.
- **A listed name that does not exist on the account is not created**, provisional, chosen by the
  advisor on 2026-10-24. Adoption takes only what is there. The entry is refused when listed, or
  reported as missing on describe if it vanishes later, never uploaded into being.
- **The bucket and the user D1 are the driver's own containers**, provisional, chosen by the advisor
  on 2026-10-24, correcting the advisor's own relay, not the author's rule. In today's structure,
  one bucket and one user D1 per binding made at install before any item exists, they are named by
  ids the driver draws and checks, like its own Workers and state D1; the organization's resource is
  the item, an object item named by its id where it is held, its prefix `<item id>/`, as today.
