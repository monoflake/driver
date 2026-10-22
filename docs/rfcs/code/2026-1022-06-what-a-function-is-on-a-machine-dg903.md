---
name: 'What a Function Is on a Machine'
title: "What the deployments contract leaves the machine's function kind to decide: a bundle's archive, the container a function runs in, what workerd gives a worker, and an instance"
status: draft
supersedes: []
blocked-by: []
commits: []
references:
  - url: https://github.com/cloudflare/workerd/blob/main/src/workerd/server/workerd.capnp
    took: "workerd's configuration, its services, sockets, modules, bindings and global outbound"
  - url: https://developers.cloudflare.com/workers/configuration/multipart-upload-metadata/
    took: "a Worker's metadata, main_module, compatibility_date and compatibility_flags"
---

## Question

Left open where `driver-machine-function` runs a deployment of the `modules` form, RFC vr5lw and
`model/contracts/kinds/deployments.res` with its samples. Decided by the author on 2026-10-22: one
workerd process for each deployment, inside its binding's container, from the image
monoflake/runtime releases, built on the container kind, which fetches the artifact as RFC ge55b
says, attaches the network, assigns the qgroup and binds the secrets. Every sample deploying
modules holds against a fake of the container kind; what they send needs workerd running. What
the contract does not say, each answered by the code as the option below proposes:

1. **What a modules artifact is.** ge55b decides an image's, an OCI layout archive; a bundle's
   bytes are fetched and held to their hash alike, and nothing says what they hold, nor which
   module is the main one, nor the compatibility date workerd needs.
2. **Which container a function runs in.** `into` is optional, and the samples deploy modules
   without it and expect them running; an image is refused `malformed` without it.
3. **What workerd gives a worker.** The contract carries the footing's address, the secrets and
   the networks it may reach, and names no binding to the platform's interfaces, `object`,
   `database` or another app's exports, RFC 49qyg, so a worker is given none of them.
4. **How a secret reaches a worker.** vr5lw has secrets files on a tmpfs bound into the container,
   its configuration naming their paths alone.
5. **What the networks allow.** workerd reaches out through one service, by `fetch` and by
   `connect`, and has no UDP or ICMP.
6. **An instance.** `counter-modules` is an instance, every call for one key reaching one, and a
   deploy says nothing of it, since the rest is read from the bundle, vr5lw.
7. **An artifact naming an architecture.** Modules run on any; ge55b refuses an image of another.

## Options

The agent's proposal, for the author to take, change or refuse.

- **A bundle is a tar archive** of its modules by their paths, beside `metadata.json` naming its
  `main_module`, its `compatibility_date` as `YYYY-MM-DD`, and its `compatibility_flags` if any,
  as Cloudflare's upload metadata names them, so one build serves a Worker and a machine. A
  module's type is its extension's: `.js` and `.mjs` an ES module, `.cjs` CommonJS, `.wasm`,
  `.txt` text, `.bin` data, `.json`. Any other entry, a link, a name outside the bundle or one
  twice, or metadata missing is `malformed`; a key the metadata holds beyond these is passed over.
- **A function runs in the container it names, or else the binding's of the lowest id**, and a
  binding holding none answers `beyond_host`, as one without its list's making does now.
- **A worker is given the footing's address as the text `MONOFLAKE_FOOTING`**, the name the
  container kind gives an image, and each secret as a text by its name; a binding to the
  platform's interfaces waits on the contract naming one.
- **A secret is embedded by its path**, `text = embed "/<name>"`, workerd given `--import-path
  /run/secrets`, so the configuration names its file and never its value.
- **`http` or `tcp` lets a worker reach the public internet**, through a network service as
  workerd's own `internet` is; neither, it reaches nothing. `udp` and `icmp` give it nothing more.
- **An instance waits on its bundle declaring one**: a Durable Object's class in the metadata,
  workerd given its namespace in memory, its key the path's first part. Until then a counter's
  calls share the one isolate's memory.
- **An architecture named on modules is passed over.**
- workerd listens at `*:8080` in its container, its configuration and modules bound read-only at
  `/worker`, `driver-machine-function`'s constants.
