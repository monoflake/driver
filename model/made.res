/**
 * What a driver is made of, one implementation for each kind its vendor gives, its management and
 * its program, RFC 7ykg6. The blocks and the fill are both read from it, `filling.res`.
 */
type language = [#rust | #rescript]

/** One kind's implementation, by the contract reaching the kind, a volume by none. */
type implementation = {
  kind: Resources.kind,
  contract?: string,
  language: language,
  as_: string,
  /** monoflake/platform's libraries it may depend on, by its model's names. */
  uses?: array<string>,
  /** What of others' it may take, as monoflake/platform's `model/graph/libraries.res` has it. */
  takes?: array<Libraries.taken>,
}

/**
 * The one binary serving the management and every kind, released with a version of its own, RFC
 * 8c0rg.
 */
type program = {
  language: language,
  /** monoflake/platform's libraries it may depend on, by its model's names. */
  uses: array<string>,
  takes: array<Libraries.taken>,
  /** The blocks of this driver it serves, by their packages. */
  serves: array<string>,
  /** The samples its tests read, from this repository's root. */
  samples: array<string>,
}

/** A driver, its implementations, its management and the runtimes it gives compute by. */
type driver = {
  grounds: array<Steps.ground>,
  management: language,
  /** What of others' its management may take. */
  managementTakes?: array<Libraries.taken>,
  implements: array<implementation>,
  runtimes: array<Drivers.runtime>,
  program?: program,
}

/** A driver's directory, the vendor in its role's parentheses, `driver(machine)` at `machine`. */
let dirOf = role => role->String.replace("driver(", "")->String.replace(")", "")

let held = (
  name,
  package,
  language: language,
  ~uses=[],
  ~takes=[],
  ~blocks=?,
  ~released=?,
  ~samples=[],
): Blocks.held => {
  name,
  languages: [(language :> Blocks.lang)],
  package,
  license: Components.permissive,
  uses,
  takes,
  samples,
  ?blocks,
  ?released,
}

/**
 * Each block of a driver by its directory, an implementation under its kind's name, its management,
 * and its program at the driver's own.
 */
let blocks = (role, d: driver) => {
  let dir = dirOf(role)
  let package = Blocks.packageName(role)
  let kinds = d.implements->Array.map(i => {
    let kind = (i.kind :> string)
    (
      `${dir}/${kind}`,
      held(
        `${role} ${kind}`,
        `${package}-${kind}`,
        i.language,
        ~uses=i.uses->Option.getOr([]),
        ~takes=i.takes->Option.getOr([]),
      ),
    )
  })
  let management = (
    `${dir}/management`,
    held(
      `${role} management`,
      `${package}-management`,
      d.management,
      ~takes=d.managementTakes->Option.getOr([]),
    ),
  )
  let program =
    d.program->Option.mapOr([], p => [
      (
        dir,
        held(
          role,
          package,
          p.language,
          ~uses=p.uses,
          ~takes=p.takes,
          ~blocks=p.serves,
          ~released=true,
          ~samples=p.samples,
        ),
      ),
    ])
  Array.concatMany(kinds, [[management], program])
}

/** What a driver gives its role, each kind at its contract's version in monoflake/platform. */
let fill = (d: driver): Drivers.driver => {
  grounds: d.grounds,
  kinds: d.implements->Array.map(i => {
    Drivers.kind: i.kind,
    contract: ?i.contract,
    version: ?(i.contract->Option.flatMap(Drivers.versionOf)),
  }),
  management: Drivers.versionOf("management")->Option.getOr(0),
  runtimes: d.runtimes,
}
