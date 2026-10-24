/***
 * driver(cloudflare)'s object, the Worker `object` over the binding's one bucket `objects`, what it
 * holds counted in the driver's D1, RFC nrs5v. This file is its interface, the model's.
 */

/** A D1 database binding, as the Worker is given it. */
type database

/** An R2 bucket binding, as the Worker is given it. */
type bucket

/** What the Worker is given, the D1 `driver`, the bucket `objects` and the binding's hash. */
type env = {
  @as("DB") db: database,
  @as("OBJECTS") objects: bucket,
  @as("BINDING") binding: string,
}

/**
 * A request answered at `POST /object/{operation}`, its bearer's secret held as the Worker `driver`
 * holds it, against the one `object` item the list holds.
 */
let fetch: (Web.request, env) => promise<Web.response>
