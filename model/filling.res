/**
 * Every driver by the role it fills, its blocks as monoflake/platform's code holds them and the
 * `drivers` part of the fill, RFC 7ykg6.
 */
@val external importMetaUrl: string = "import.meta.url"

let drivers: array<(string, Made.driver)> = [
  ("driver(cloudflare)", Cloudflare.driver),
  ("driver(machine)", Machine.driver),
]

/** The `drivers` part of the fill, each role by name, as monoflake/platform's `Fill.drivers`. */
let given: dict<Drivers.driver> =
  drivers->Array.map(((role, d)) => (role, Made.fill(d)))->Dict.fromArray

/** This repository's blocks, held by monoflake/platform's `tree.res`. */
let tree = (): Blocks.tree => {
  root: Base.url("../", importMetaUrl),
  blocks: drivers->Array.flatMap(((role, d)) => Made.blocks(role, d))->Map.fromArray,
  work: Progress.blocks,
  rows: Blocks.openRows(),
}
