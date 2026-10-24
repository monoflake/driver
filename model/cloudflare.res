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
      uses: ["envelope*"],
      samples: [
        "../platform/tests/kinds/deployments/deploys.json",
        "../platform/tests/kinds/deployments/lifecycle.json",
      ],
    },
    {kind: #instance, contract: "deployments", language: #rescript, as_: "a Durable Object"},
    {kind: #object, contract: "object", language: #rescript, as_: "a Worker over R2"},
    {kind: #database, contract: "database", language: #rescript, as_: "a Worker over D1"},
  ],
  runtimes: [{name: "workers", takes: "modules", stands: ["isolate"]}],
  // The Worker `driver`, serving the management and each kind, bundled by wrangler, RFC nrs5v.
  program: {
    language: #rescript,
    uses: ["envelope*", "codec*", "keys*"],
    takes: [{language: #rescript, name: "wrangler", major: "4"}],
    serves: ["driver-cloudflare-function", "driver-cloudflare-management"],
    // The management's samples hold object items, so they come with nrs5v's next slice.
    samples: ["../platform/tests/kinds/deployments/lifecycle.json"],
    released: false,
  },
}
