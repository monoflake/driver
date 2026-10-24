/***
 * driver(cloudflare)'s database, the Worker `database` over the binding's one D1 database, its
 * item kept in the driver's D1, RFC nrs5v. This file is its interface, the model's.
 */

/** A D1 database binding, as the Worker is given it. */
type database

/** What the Worker is given, the D1 `driver` and `database`, its token and the binding's hash. */
type env = {
  @as("DB") db: database,
  @as("DATABASE") database: database,
  @as("BINDING") binding: string,
  @as("API_TOKEN") apiToken: string,
  @as("ACCOUNT_ID") accountId: string,
  @as("DATABASE_ID") databaseId: string,
}

/**
 * A request answered at `POST /database/{operation}`, its bearer's secret held as the Worker
 * `driver` holds it, against the one `database` item the list holds.
 */
let fetch: (Web.request, env) => promise<Web.response>
