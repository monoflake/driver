/***
 * driver(cloudflare)'s function, each deployment a Worker of the bound account made through
 * Cloudflare's API, RFC nrs5v. This file is its interface, the model's, `docs/code.md`.
 */
module Contracts = Envelope.Contracts

/** Why a step answered nothing, a reason the deployments contract names and its message. */
type refused = {reason: string, message: string}

/** A module's type, read from its name's extension as driver(machine) reads it. */
type kind = Es | CommonJs | Wasm | Text | Data | Json

/** A module of a bundle, by the name its imports give it. */
type module_ = {name: string, kind: kind, bytes: Uint8Array.t}

/** A bundle as its artifact holds it, its main module first, RFC dg903. */
type bundle = {
  modules: array<module_>,
  compatibilityDate: string,
  compatibilityFlags: array<string>,
}

/** The most an artifact may be in bytes, a Worker's 64 MiB on every plan, RFC nrs5v. */
let largest: int

/** The bundle of a tar archive's bytes and its `metadata.json`, or `malformed` where it is none. */
let unpack: Uint8Array.t => result<bundle, refused>

/** The stub a stopped deployment's Worker runs, answering every request 503 `stopped`. */
let stub: bundle

/** A binding a Worker is given, by its name. */
type bound = PlainText({name: string, text: string}) | SecretText({name: string, text: string})

/** A version of a Worker as it is uploaded, its modules, its bindings and its version's tag. */
type upload = {bundle: bundle, bindings: array<bound>, tag: string}

/** The version a Worker runs now, by Cloudflare's id, and the tag it was uploaded with. */
type running = {id: string, tag: option<string>}

/** What this kind asks of Cloudflare's API for one account, each by the Worker's name. */
type api = {
  /** A version uploaded, the Worker made where it is absent, and its id; none is deployed. */
  upload: (string, upload) => promise<result<string, refused>>,
  /** The version by its id deployed to every request. */
  deploy: (string, string) => promise<result<unit, refused>>,
  /** The version deployed now, none where no Worker is so named. */
  running: string => promise<result<option<running>, refused>>,
  /** The Worker deleted, succeeding where there is none. */
  delete: string => promise<result<unit, refused>>,
  /** The address a Worker answers at, by its name, on the account's subdomain of `workers.dev`. */
  address: string => promise<result<string, refused>>,
}

/** The API of the account `accountId`, reached with `token` by the runtime's `fetch`. */
let ofAccount: (~accountId: string, ~token: string) => api

/** A deployment as this kind keeps it, the version it runs and the one a stop replaced. */
type kept = {
  version: string,
  state: [#running | #stopped | #failed],
  reason?: string,
  replaced?: string,
}

/** Where deployments are kept, by their Worker's name, D1's `deployments` table in the driver. */
type store = {
  read: string => promise<option<kept>>,
  write: (string, kept) => promise<unit>,
  forget: string => promise<unit>,
}

/** What each operation works through, the API, the store and an artifact fetched by address. */
type through = {api: api, store: store, fetch: string => promise<result<Uint8Array.t, refused>>}

/** The Worker a deployment runs as, `app-<id>` or `component-<name>`. */
let workerOf: Contracts.DeploymentRuns.t => string

/** The tag a version is kept as, `version-<hash in hex>`, cut short where a tag holds less. */
let tagOf: Uint8Array.t => string

let deploy: (
  through,
  Contracts.DeploymentDeploy.t,
) => promise<Contracts.Answer.t<Contracts.DeploymentDescribed.t>>

let stop: (
  through,
  Contracts.DeploymentOf.t,
) => promise<Contracts.Answer.t<Contracts.DeploymentDescribed.t>>

let resume: (
  through,
  Contracts.DeploymentOf.t,
) => promise<Contracts.Answer.t<Contracts.DeploymentDescribed.t>>

let describe: (
  through,
  Contracts.DeploymentOf.t,
) => promise<Contracts.Answer.t<Contracts.DeploymentDescribed.t>>

let delete: (
  through,
  Contracts.DeploymentOf.t,
) => promise<Contracts.Answer.t<Contracts.DeploymentDeleted.t>>
