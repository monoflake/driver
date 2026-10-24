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
    // The Worker `object`, the binding's one bucket `objects` counted in the driver's D1, nrs5v.
    {
      kind: #object,
      contract: "object",
      language: #rescript,
      as_: "a Worker over R2",
      uses: ["envelope*", "codec*", "keys*"],
      takes: [{language: #rescript, name: "wrangler", major: "4"}],
      samples: [
        "../platform/tests/kinds/objects/listing.json",
        "../platform/tests/kinds/objects/ranges.json",
        "../platform/tests/kinds/objects/writes.json",
      ],
    },
    {kind: #database, contract: "database", language: #rescript, as_: "a Worker over D1"},
  ],
  runtimes: [{name: "workers", takes: "modules", stands: ["isolate"]}],
  // The Worker `driver`, serving the management and the function kind, bundled by wrangler, nrs5v.
  program: {
    language: #rescript,
    uses: ["envelope*", "codec*", "keys*"],
    takes: [{language: #rescript, name: "wrangler", major: "4"}],
    serves: ["driver-cloudflare-function", "driver-cloudflare-management"],
    samples: [
      "../platform/tests/kinds/management/lists.json",
      "../platform/tests/kinds/management/graces.json",
      "../platform/tests/kinds/management/ends.json",
      "../platform/tests/kinds/deployments/lifecycle.json",
    ],
    released: false,
  },
}
