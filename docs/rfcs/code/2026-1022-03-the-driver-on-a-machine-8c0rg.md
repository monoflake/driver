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
  0.8. It listens on port 37483, DRIVE on a keypad, and a machine's firewall opens that port on no
  interface, decided by the author on 2026-10-26. The control reaches it through the Cloudflare
  tunnel to the machine itself, and the author through SSH then `localhost`. It runs as root,
  since containerd and btrfs quota groups ask it, with every systemd hardening that leaves those
  two working.
- **It is built static against musl, for `linux-x86_64` and `linux-aarch64`**: a machine runs
  NixOS, which has no `/lib64` loader a glibc binary built elsewhere looks for. Each architecture is
  one archive, `driver-machine-<version>-linux-<machine>.tar.gz`, the workspace's
  `docs/naming.md`, holding the binary and the two licenses.
- **Its version is `MAJOR.MINOR.PATCH`, and only the program's**: every other crate stays `0.0.0`,
  as `monoflake/platform`'s `docs/code.md` has it. The major is raised by the author alone and says
  how stable the driver is. The minor follows the integer versions of the interfaces it serves, the
  kinds' contracts in `monoflake/platform`: it is raised when any of them is, so one minor reads and
  writes one set of formats. Any other change, a feature or a fix, raises the patch. Until the
  author opens its releases, as everything of the author's own that is unpublished, it is `0.0.0`
  and the release refuses it, decided by the author on 2026-10-22; the first release is `0.1.0`.
- **It is released from this repository**, a UTC day as `monoflake/runtime`'s, RFC m7rkq, by the
  workspace's release script a repository's `[release]` declares: a table of what each day released
  with the downloads below it, and one `manifest.json` appended to by each release, recording every
  interface the release serves and its version, so a build reads the minor and patch to take from
  the last release. Once opened, a build is released only by hand, the workflow run from GitHub,
  on the platform at the commit its checkout pins, RFC x6hf9, until the author turns on a release
  on a push to main that changes what the driver is built from. Until the first, the driver is
  built on the author's machine and copied to a test machine to be tried, run there as a transient
  systemd unit, which an upgrade's switch leaves running.
- **One shape of `manifest.json` for every release**, `{release, artifacts}`, each artifact its
  `name`, `version`, `commit` and `assets`, each asset its `target`, `kind`, `file`, `size` and
  `sha256`, and an image's `digest`, the driver's `kind` being `binary` and an image's `oci`, so
  the workspace's `releases.res` reads one form; `monoflake/runtime`'s published manifest is moved
  to it when the driver's release is first pushed.
- **A machine takes a released driver as it takes the runtimes' images**, locked in
  `monoflake/machine`'s manifest beside them and run there as a service.

### Source versions and open releases

Decided by the author on 2026-10-27, refining the accepted decision above.

- Releases open at `0.1.0`, only for the Rust program `driver-machine` and only on GitHub
  Releases. Every other crate and package stays `0.0.0`; nothing is published to the Rust or npm registries.
- The version lives in `machine/Cargo.toml` and is raised in the commit that changes what the
  driver is built from. `mise run bump` writes it and synchronizes `Cargo.lock`, reusing
  `.github/release/versioned.res`. Release time takes that version unchanged. The major remains
  the author's alone. A served interface's integer version raised since the last release, or a
  Conventional Commit affecting the program's inputs marked with `!` or a `BREAKING CHANGE:`
  footer, raises the minor and resets the patch. Otherwise the patch rises.
- A release runs on a push to main, by manual dispatch, and daily as a fallback for a failed push
  run. Before building, each run reads the source version and every published release's manifest.
  A version any manifest lists is neither rebuilt nor released again. A source change without a
  raised version releases nothing.
- Runtime's UTC date naming applies, RFC m7rkq. The tag and name are the dotted date alone, and
  the body is a table with Driver, Version, Commit and Architecture columns. The Driver cell is
  `machine`, and each architecture's short name links to its full archive name, separated by one
  plain space. Another version on the same day appends a row, assets and a manifest entry through
  the workspace's existing `scripts/release`.
- A machine locks the driver beside the runtimes' images and takes the released package by
  default, through the same intake: one GitHub Releases URL and one SHA-256 per architecture,
  fetched by whichever builder builds the system, by its fixed output, like any other source. The
  package travels by the cache's own rules, monoflake/machine's RFC mgzfp, so a release needs no
  bucket of its own. Its test override remains available.

### Provisional choices

Chosen on 2026-10-27, provisional.

- Verify compares the program's crate, shared crates and `Cargo.lock` with the last released
  commit and refuses changed inputs without a source version above the released one. The
  workspace's dependency update calls the bump task when `cargo update` changes the driver's lock;
  runtime's update path is unchanged. Chosen by the advisor.
- The platform commit a release builds from is the one the working copy's `release.yml` pins.
  Verify and bump compare the platform's shared Rust crates, generator and contracts, and read the
  platform's commit messages, from the commit the last release pinned to that one, never the local
  checkout's own; the local monoflake/platform supplies that history. The workspace's update runs
  the bump after its actions mover moves a workflow, as it does after a `Cargo.lock` change. Chosen
  by the advisor on 2026-10-27.
- The bump never lowers a version. It writes the higher of the manifest's version and the one
  incremented from the last release, never moves the major, and leaves the version as it is where
  no input changed since the last release. Chosen by the advisor on 2026-10-27.
- A platform commit a release or the working copy pins that the local monoflake/platform lacks is
  fetched there once, by `jj git fetch`, and the comparison is tried again. Where it is still
  missing, the bump raises the patch anyway and warns that a minor raise could not be inferred,
  since an unneeded patch release is harmless and a missed one strands a platform change, and
  verify warns that the platform was not checked and passes; a change of the driver's own inputs
  without a raise is still refused. Any other comparison or release lookup that fails, offline or
  rate limited, warns and passes, the bump writing nothing. Nothing runs verify in CI, so no rule
  depends on CI. Chosen by the advisor on 2026-10-27, replacing a refusal everywhere and then a
  refusal in CI.
- The skip a release made where both archives equal the last release's is removed. The source
  version is the release's authority, so equal archives must not suppress a version the source
  raised, and a version a release's manifest lists is never built again. Chosen by the
  implementer, to whom the author's brief left it.
