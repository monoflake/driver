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

/**
 * Each draft of this repository's `docs/rfcs/` by its id, which code waiting on it names as it
 * would an open row of the checklist.
 */
let drafts = () => {
  let rfcs = Base.url("../docs/rfcs/", importMetaUrl)
  let draftIn = (dir, file) =>
    file->String.endsWith(".md") &&
      Base.readFileSync(Base.urlIn(file, dir))->String.includes("\nstatus: draft\n")
      ? file->String.split("-")->Array.at(-1)->Option.map(s => s->String.replace(".md", ""))
      : None
  // The RFCs sit flat while they number few, and in a directory of an area past that.
  Base.readdirSync(rfcs)->Array.flatMap(entry =>
    entry->String.endsWith(".md")
      ? draftIn(rfcs, entry)->Option.mapOr([], id => [id])
      : {
          let dir = Base.urlIn(`${entry}/`, rfcs)
          Base.readdirSync(dir)->Array.filterMap(file => draftIn(dir, file))
        }
  )
}

/** This repository's blocks, held by monoflake/platform's `tree.res`. */
let tree = (): Blocks.tree => {
  root: Base.url("../", importMetaUrl),
  blocks: drivers->Array.flatMap(((role, d)) => Made.blocks(role, d))->Map.fromArray,
  work: Written.blocks,
  rows: Array.concat(Blocks.openRows(), drafts()),
}
