# AGENTS.md

The drivers, what each vendor gives the platform through a kind's contract, MIT OR Apache-2.0,
RFC 7ykg6. Read it after the workspace's `AGENTS.md`; it holds only what is the drivers' own.

It builds on the sibling checkout `../platform`, the workspace placing both under
`repos/monoflake/`.

## Start here

What a driver must give is `monoflake/platform`'s model, the roles `driver(machine)` and
`driver(cloudflare)` its `model/ground/drivers.res` asks; how code is written is its
`docs/code.md`, which holds here as written. This model holds what each driver is made of and fills
the roles with it; [docs/rfcs/](docs/rfcs/) holds what is decided here alone.

## The tree

```
machine/    driver(machine): the program driver-machine, RFC 8c0rg, the entry its command `entry`
            run as a unit of its own, RFC rmll5, and beneath it each kind's crate, container/ and
            management/ now
scripts/    archive.res, the program built static for both architectures and archived; dev.res, one
            built for a test machine, copied in, restarted and checked
.github/    release.yml and release/, what CI alone runs, its version and what it releases
model/      each driver, machine.res and cloudflare.res, in made.res's types; filling.res, its blocks
            and the fill; tasks.res, the tasks; plan/progress.res, each written block's state
docs/       rfcs/, what is decided here alone
```

- **The model is monoflake/platform's code run over this repository**: `tasks.res` hands
  `filling.res`'s tree to its `tree.res`, and runs its check with the `drivers` part of the fill,
  `MONOFLAKE_FILL`, as cloud's whole model runs it with cloud's.
- **The platform's crates and samples are reached by path**, `../platform/code/libs/...` and
  `../platform/tests/...`, until releases cross repositories, RFC 7ykg6.
- `cloudflare/` is made once it has code.

## Commands

The model is ReScript and the tasks are mise's, the root's five links reaching up to the
workspace's configuration as platform's do.

| Command                  | Does                                                     |
| ------------------------ | -------------------------------------------------------- |
| `mise run check`         | the platform's check with the drivers filled, the blocks |
| `mise run fmt`           | formats the ReScript and the prose                       |
| `mise run verify`        | everything formatted, the check, the blocks, the deny    |
| `mise run brief <name>`  | one block's brief, read from the model                   |
| `mise run accept <name>` | one block held to its brief, alone                       |
| `mise run built <name>`  | one block built, formatted, linted and tested alone      |
| `mise run blocks`        | every written block built alone, as verify asks          |
| `mise run archive`       | driver-machine built for linux-x86_64 and linux-aarch64  |
| `mise run release`       | what built.json names put into the day's release         |
| `mise run dev <host>`    | built for a test machine, copied in, restarted, checked  |
