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
  Base.readdirSync(rfcs)->Array.flatMap(area => {
    let dir = Base.urlIn(`${area}/`, rfcs)
    Base.readdirSync(dir)->Array.filterMap(file =>
      file->String.endsWith(".md") &&
        Base.readFileSync(Base.urlIn(file, dir))->String.includes("\nstatus: draft\n")
        ? file->String.split("-")->Array.at(-1)->Option.map(s => s->String.replace(".md", ""))
        : None
    )
  })
}

/** This repository's blocks, held by monoflake/platform's `tree.res`. */
let tree = (): Blocks.tree => {
  root: Base.url("../", importMetaUrl),
  blocks: drivers->Array.flatMap(((role, d)) => Made.blocks(role, d))->Map.fromArray,
  work: Progress.blocks,
  rows: Array.concat(Blocks.openRows(), drafts()),
}
