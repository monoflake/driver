/***
 * driver(cloudflare)'s object, a Worker over the binding's one bucket counted in the driver's D1,
 * each named as the driver's records hold it, RFC nrs5v. This file is its interface.
 */

/** A D1 database binding, as the Worker is given it. */
type database

/** An R2 bucket binding, as the Worker is given it. */
type bucket

/** What the Worker is given, the driver's D1, its bucket, the binding's hash and its install id. */
type env = {
  @as("DB") db: database,
  @as("OBJECTS") objects: bucket,
  @as("BINDING") binding: string,
  @as("INSTALL_ID") installId?: string,
}

/**
 * A request answered at `POST /object/{operation}`, its bearer's secret held as the Worker `driver`
 * holds it, against the one `object` item the list holds.
 */
let fetch: (Web.request, env) => promise<Web.response>
