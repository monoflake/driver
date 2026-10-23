/**
 * driver(machine), what a machine of a provider's or at home gives, RFC vr5lw. A machine's NixOS
 * is monoflake/machine's and its isolate runtimes' images monoflake/runtime's, RFC m7rkq.
 */
let rust = (name, major): Libraries.taken => {language: #rust, name, major}

let driver: Made.driver = {
  grounds: [#provider, #home],
  management: #rust,
  managementTakes: [rust("rustix", "1"), rust("blake3", "1")],
  implements: [
    // workerd in a container of the binding's for each deployment, from monoflake/runtime's image.
    {
      kind: #function,
      contract: "deployments",
      language: #rust,
      as_: "workerd, run for each deployment",
      uses: ["envelope*"],
      blocks: ["driver-machine-container"],
      takes: [
        rust("tar", "0.4"),
        rust("serde_json", "1"),
        rust("tokio", "1"),
        rust("sha2", "0.11"),
      ],
      samples: [
        "../platform/tests/kinds/deployments/deploys.json",
        "../platform/tests/kinds/deployments/instances.json",
        "../platform/tests/kinds/deployments/lifecycle.json",
      ],
    },
    {kind: #instance, contract: "deployments", language: #rust, as_: "a process"},
    // A container's layer joins its binding's qgroup through the volume, which owns btrfs.
    {
      kind: #container,
      contract: "deployments",
      language: #rust,
      as_: "a container, by containerd",
      uses: ["envelope*"],
      blocks: ["driver-machine-volume"],
      takes: [
        rust("containerd-client", "0.9"),
        rust("tokio", "1"),
        rust("serde_json", "1"),
        rust("sha2", "0.11"),
        rust("prost-types", "0.14"),
        rust("tonic", "0.14"),
        rust("reqwest", "0.13"),
        rust("chacha20poly1305", "0.11"),
      ],
    },
    // A bucket is a subvolume, its names indexed by SQLite and its contents files by their hash.
    {
      kind: #object,
      contract: "object",
      language: #rust,
      as_: "objects on the machine's file system",
      uses: ["envelope*"],
      takes: [rust("rusqlite", "0.40"), rust("blake3", "1"), rust("serde_json", "1")],
      samples: [
        "../platform/tests/kinds/objects/listing.json",
        "../platform/tests/kinds/objects/ranges.json",
        "../platform/tests/kinds/objects/writes.json",
      ],
    },
    // A binding's item as a subvolume under a qgroup's limit, which a bucket stands on, RFC 54q45.
    {kind: #volume, language: #rust, as_: "a btrfs subvolume", takes: [rust("rustix", "1")]},
    {kind: #database, contract: "database", language: #rust, as_: "SQLite on a volume"},
  ],
  // An isolate runs inside its organization's container, which keeps bindings apart, v7v3w.
  runtimes: [
    {name: "workerd", takes: "modules", stands: ["isolate", "kernel"]},
    {name: "wasmtime", takes: "component", stands: ["isolate", "kernel"]},
    {name: "runc", takes: "image", stands: ["kernel"]},
    {name: "crun", takes: "image", stands: ["kernel"]},
    {name: "youki", takes: "image", stands: ["kernel"]},
  ],
  // driver-machine, a binary serving plain HTTP by axum, its arguments parsed by clap, RFC 8c0rg,
  // its entry served by hyper on a listener taken from systemd by listenfd, RFC ehm48, and its
  // bind calling the control once by reqwest, RFC rxmd9.
  program: {
    language: #rust,
    uses: ["envelope*", "codec*"],
    takes: [
      rust("axum", "0.8"),
      rust("tokio", "1"),
      rust("clap", "4"),
      rust("serde_json", "1"),
      rust("hyper", "1"),
      rust("hyper-util", "0.1"),
      rust("listenfd", "1"),
      rust("reqwest", "0.13"),
    ],
    serves: [
      "driver-machine-container",
      "driver-machine-function",
      "driver-machine-management",
      "driver-machine-object",
      "driver-machine-volume",
    ],
    samples: [
      "../platform/tests/kinds/management/lists.json",
      "../platform/tests/kinds/management/graces.json",
      "../platform/tests/kinds/management/ends.json",
      "../platform/tests/kinds/deployments/lifecycle.json",
      "../platform/tests/kinds/objects/listing.json",
      "../platform/tests/kinds/objects/ranges.json",
      "../platform/tests/kinds/objects/writes.json",
    ],
    released: false,
  },
}
