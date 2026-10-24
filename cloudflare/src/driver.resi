/***
 * driver(cloudflare), the Worker `driver` on the bound account serving its management and each
 * kind it holds, RFC nrs5v. This file is its interface, the model's, `docs/code.md`.
 */

/** A D1 database binding, as the Worker is given it. */
type database

/** What the Worker is given, its D1 `driver`, its token, its account and the binding's hash. */
type env = {
  @as("DB") db: database,
  @as("API_TOKEN") apiToken: string,
  @as("ACCOUNT_ID") accountId: string,
  @as("BINDING") binding: string,
  @as("DRIVER_REVISION") revision?: string,
}

/**
 * A request answered at `POST /management/{operation}` or `POST /deployments/{operation}`, its
 * bearer's secret held, a management request's grace swept first. Nothing runs on a timer, rxmd9.
 */
let fetch: (Web.request, env) => promise<Web.response>
