---
name: 'The Driver on a Machine'
title: '`driver-machine`: the one program a machine runs as its driver, how it is built, versioned, released and tried'
status: accepted
supersedes: []
blocked-by: []
commits: []
references: []
---

## Question

`driver(machine)` was written as libraries, its management and its container kind, first in
`monoflake/platform` and now here, RFC 7ykg6, and nothing a machine runs: no process serves the
kinds' operations, so no call has yet reached a machine. What program is the driver, what does it
serve and where, how is it built for the two architectures a machine has, how is its version
written, and how does it reach a machine before a release does.

## Decision

Decided by the author on 2026-10-22.

- **The driver is one program, `driver-machine`**, a block of its own beside its kinds', named as
  the model names the driver and as its crates are, `driver-<vendor>-<kind>`; `machine-driver`
  would read as `monoflake/machine`'s, whose code it is not. It holds the management and every kind
  the machine gives in one process.
- **It serves plain HTTP, `POST /{interface}/{operation}`**, each call carrying a binding's token
  as `Authorization: Bearer`, RFC 3d3nt, and TLS a reverse proxy's, RFC vr5lw. Its server is axum
  0.8. It listens on port 37483, DRIVE on a keypad, and a machine's firewall opens that port on the
  tailnet's interface alone. It runs as root, since containerd and btrfs quota groups ask it, with
  every systemd hardening that leaves those two working.
- **It is built static against musl, for `linux-x86_64` and `linux-aarch64`**: a machine runs
  NixOS, which has no `/lib64` loader a glibc binary built elsewhere looks for. Each architecture is
  one archive, `driver-machine-<version>-linux-<machine>.tar.gz`, the workspace's
  `docs/naming.md`, holding the binary and the two licenses.
- **Its version is `MAJOR.MINOR.PATCH`, and only the program's**: every other crate stays `0.0.0`,
  as `monoflake/platform`'s `docs/code.md` has it. The major is raised by the author alone and says
  how stable the driver is. The minor follows the integer versions of the interfaces it serves, the
  kinds' contracts in `monoflake/platform`: it is raised when any of them is, so one minor reads and
  writes one set of formats. Any other change, a feature or a fix, raises the patch. The first is
  `0.1.0`.
- **It is released from this repository**, a UTC day as `monoflake/runtime`'s, RFC m7rkq, by the
  workspace's release script a repository's `[release]` declares: a table of what each day released
  with the downloads below it, and one `manifest.json` appended to by each release, recording every
  interface the release serves and its version, so a build reads the minor and patch to take from
  the last release. A build is released on a push to main that changes what the driver is built
  from. Until the author pushes the first, the driver is built by hand on the author's machine and
  copied to a test machine to be tried, run there as a transient systemd unit, which an upgrade's
  switch leaves running.
- **One shape of `manifest.json` for every release**, `{release, artifacts}`, each artifact its
  `name`, `version`, `commit` and `assets`, each asset its `target`, `kind`, `file`, `size` and
  `sha256`, and an image's `digest`, the driver's `kind` being `binary` and an image's `oci`, so
  the workspace's `releases.res` reads one form; `monoflake/runtime`'s published manifest is moved
  to it when the driver's release is first pushed.
- **A machine takes a released driver as it takes the runtimes' images**, locked in
  `monoflake/machine`'s manifest beside them and run there as a service.
