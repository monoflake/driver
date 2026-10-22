/** driver(cloudflare), what an account's Workers, D1 and R2 give, made through Cloudflare's API. */
let driver: Made.driver = {
  grounds: [#cloudflare],
  management: #rescript,
  implements: [
    {
      kind: #function,
      contract: "deployments",
      language: #rescript,
      as_: "a Worker of each deployment, made through Cloudflare's API",
    },
    {kind: #instance, contract: "deployments", language: #rescript, as_: "a Durable Object"},
    {kind: #object, contract: "object", language: #rescript, as_: "a Worker over R2"},
    {
      kind: #database,
      contract: "database",
      language: #rescript,
      as_: "a Worker over D1, or a Durable Object's SQLite",
    },
  ],
  runtimes: [{name: "workers", takes: "modules", stands: ["isolate"]}],
}
