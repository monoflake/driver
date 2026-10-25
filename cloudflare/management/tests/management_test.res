/*** `Management` on a store in memory, each write counted, as the driver's D1 would hold it. */
open Node

let initial: Management.kept = {
  generation: 0.,
  policy: 0.,
  grace: 604800,
  items: [],
  tokens: None,
  adopted: [],
  warnings: [],
}

type memory = {store: Management.store, kept: ref<Management.kept>, writes: ref<int>}

let memory = (~kept=initial) => {
  let kept = ref(kept)
  let writes = ref(0)
  let store: Management.store = {
    read: async () => kept.contents,
    write: async k => {
      writes := writes.contents + 1
      kept := k
    },
  }
  {store, kept, writes}
}

let hash = "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
let other = "0000000000000000000000000000000000000000000000000000000000000000"

let object = (id, ~credentials=[hash]): Management.item => {
  id,
  capacity: Object({size: 1024.}),
  credentials,
}

/** A database item of a size, by its id. */
let database = (~size=1024., id): Management.item => {
  id,
  capacity: Database({size: size}),
  credentials: [hash],
}

/** The Worker `object`'s address. */
let address = "object.my-subdomain.workers.dev"

let made = Management.Made({address: address})

/** The Worker `database`'s address. */
let databaseAddress = "database.my-subdomain.workers.dev"

let databaseMade = Management.Made({address: databaseAddress})

/** The Worker `object`'s address as `apply` asks it, each asking counted. */
let objects = (~answer=Ok(address), asked) =>
  async () => {
    asked := asked.contents + 1
    answer
  }

let apply = (
  m,
  ~now=0.,
  ~tokens=?,
  ~adopted=?,
  ~asked=ref(0),
  ~answer=?,
  ~databasesAsked=ref(0),
  ~databaseAnswer=Ok(databaseAddress),
  ~offered: array<Management.kind>=[#function, #object, #database],
  generation,
  items,
) =>
  Management.apply(
    m.store,
    ~offered,
    ~now,
    ~generation,
    ~items,
    ~tokens,
    ~adopted,
    ~objects=objects(~answer?, asked),
    ~databases=objects(~answer=databaseAnswer, databasesAsked),
  )

let reasonOf = result =>
  switch result {
  | Ok(_) => None
  | Error({reason}: Management.refused) => Some(reason)
  }

test("a list naming an item twice, or one with no credential or three, is invalid", async () => {
  let m = memory()
  deepEqual(reasonOf(await m->apply(1., [object(1.), object(1.)])), Some("invalid"))
  deepEqual(reasonOf(await m->apply(1., [object(1., ~credentials=[])])), Some("invalid"))
  let three = [hash, hash, hash]
  deepEqual(reasonOf(await m->apply(1., [object(1., ~credentials=three)])), Some("invalid"))
  deepEqual(m.writes.contents, 0)
})

test(
  "a list naming a kind not offered is refused whole, after its form and generation",
  async () => {
    let m = memory()
    let asked = ref(0)
    let offered: array<Management.kind> = [#function]
    let refusedOf = result =>
      switch result {
      | Ok(_) => None
      | Error({reason, message}: Management.refused) => Some((reason, message))
      }
    deepEqual(
      refusedOf(await m->apply(1., [object(1.)], ~asked, ~offered)),
      Some(("beyond_host", "item 1: object is not offered, only function")),
    )
    deepEqual(
      refusedOf(await m->apply(1., [database(2.)], ~offered=[#function, #object])),
      Some(("beyond_host", "item 2: database is not offered, only function, object")),
    )
    deepEqual((asked.contents, m.writes.contents), (0, 0))
    deepEqual(reasonOf(await m->apply(1., [object(1.), object(1.)], ~offered)), Some("invalid"))
    deepEqual(await m->apply(2., [], ~offered), Ok(2.))
    // A list behind is answered by the generation held, as any list behind is.
    deepEqual(await m->apply(1., [object(1.)], ~offered), Ok(2.))
    deepEqual(await m->apply(3., [object(1.)], ~asked, ~offered=[#object]), Ok(3.))
    deepEqual(asked.contents, 1)
  },
)

test("a container or a volume is beyond the host, and nothing of the list is held", async () => {
  let m = memory()
  let volume: Management.item = {id: 2., capacity: Volume({size: 1.}), credentials: [hash]}
  let container: Management.item = {
    id: 3.,
    capacity: Container({millicores: 100, memory: 1.}),
    credentials: [hash],
  }
  deepEqual(reasonOf(await m->apply(1., [object(1.), volume])), Some("beyond_host"))
  deepEqual(reasonOf(await m->apply(1., [container])), Some("beyond_host"))
  deepEqual(m.kept.contents, initial)
})

test("an object and a database are made each at its Worker's address, asked once", async () => {
  let m = memory()
  let asked = ref(0)
  let databasesAsked = ref(0)
  deepEqual(await m->apply(1., [database(2.), object(1.)], ~asked, ~databasesAsked), Ok(1.))
  deepEqual(
    m.kept.contents.items,
    [{item: object(1.), state: made}, {item: database(2.), state: databaseMade}],
  )
  // Made already, neither is asked for again, nor where the list holds none.
  deepEqual(await m->apply(2., [database(2.), object(1.)], ~asked, ~databasesAsked), Ok(2.))
  deepEqual(await m->apply(3., [database(2.)], ~asked, ~databasesAsked), Ok(3.))
  deepEqual(await m->apply(4., [object(1.)], ~asked, ~databasesAsked), Ok(4.))
  deepEqual((asked.contents, databasesAsked.contents), (1, 1))
})

test("a database the address of which was refused is failed so, and made again after", async () => {
  let m = memory()
  let refused: Management.refused = {reason: "fault", message: "no subdomain"}
  deepEqual(await m->apply(1., [database(1.)], ~databaseAnswer=Error(refused)), Ok(1.))
  deepEqual(
    m.kept.contents.items,
    [{item: database(1.), state: Failed({reason: "fault", message: "no subdomain"})}],
  )
  deepEqual(await m->apply(2., [database(1.)]), Ok(2.))
  deepEqual(m.kept.contents.items, [{item: database(1.), state: databaseMade}])
})

test("an object the address of which was refused is failed so, and made again after", async () => {
  let m = memory()
  let refused: Management.refused = {reason: "fault", message: "no subdomain"}
  deepEqual(await m->apply(1., [object(1.)], ~answer=Error(refused)), Ok(1.))
  deepEqual(
    m.kept.contents.items,
    [{item: object(1.), state: Failed({reason: "fault", message: "no subdomain"})}],
  )
  deepEqual(await m->apply(2., [object(1.)]), Ok(2.))
  deepEqual(m.kept.contents.items, [{item: object(1.), state: made}])
})

test("two object items, or an object past 1 TiB, are beyond the host, nothing held", async () => {
  let m = memory()
  let asked = ref(0)
  let past = 1_099_511_627_777.
  let large: Management.item = {id: 4., capacity: Object({size: past}), credentials: [hash]}
  let full: Management.item = {...large, capacity: Object({size: past -. 1.})}
  deepEqual(reasonOf(await m->apply(1., [object(1.), object(2.)], ~asked)), Some("beyond_host"))
  deepEqual(reasonOf(await m->apply(1., [large], ~asked)), Some("beyond_host"))
  deepEqual((m.kept.contents, asked.contents), (initial, 0))
  deepEqual(await m->apply(1., [full], ~asked), Ok(1.))
  deepEqual(m.kept.contents.items, [{item: full, state: made}])
})

test(
  "two database items, or a database past 10 GB, are beyond the host, nothing held",
  async () => {
    let m = memory()
    let databasesAsked = ref(0)
    let two = [database(1.), database(2.)]
    deepEqual(reasonOf(await m->apply(1., two, ~databasesAsked)), Some("beyond_host"))
    let large = database(~size=10_000_000_001., 3.)
    deepEqual(reasonOf(await m->apply(1., [large], ~databasesAsked)), Some("beyond_host"))
    deepEqual((m.kept.contents, databasesAsked.contents), (initial, 0))
    let full = database(~size=10_000_000_000., 3.)
    deepEqual(await m->apply(1., [full, object(1.)], ~databasesAsked), Ok(1.))
    deepEqual(
      m.kept.contents.items,
      [{item: object(1.), state: made}, {item: full, state: databaseMade}],
    )
  },
)

test("a second object item waits for the bucket until the one holding it is ended", async () => {
  let m = memory()
  deepEqual(await m->apply(1., [object(1.)]), Ok(1.))
  deepEqual(await m->apply(2., [object(2.)], ~now=5.), Ok(2.))
  deepEqual(
    m.kept.contents.items,
    [
      {item: object(1.), state: Unasked({since: 5., address})},
      {
        item: object(2.),
        state: Failed({
          reason: "beyond_host",
          message: "the binding holds one bucket, item 1's, until it is ended or swept",
        }),
      },
    ],
  )
  deepEqual(await Management.end_(m.store, ~id=1.), Ok())
  deepEqual(await m->apply(3., [object(2.)]), Ok(3.))
  deepEqual(m.kept.contents.items, [{item: object(2.), state: made}])
})

test(
  "a second database item waits for the database until the one holding it is ended",
  async () => {
    let m = memory()
    deepEqual(await m->apply(1., [database(1.), object(3.)]), Ok(1.))
    deepEqual(await m->apply(2., [database(2.), object(3.)], ~now=5.), Ok(2.))
    deepEqual(
      m.kept.contents.items,
      [
        {item: database(1.), state: Unasked({since: 5., address: databaseAddress})},
        {
          item: database(2.),
          state: Failed({
            reason: "beyond_host",
            message: "the binding holds one database, item 1's, until it is ended or swept",
          }),
        },
        {item: object(3.), state: made},
      ],
    )
    deepEqual(await Management.end_(m.store, ~id=1.), Ok())
    deepEqual(await m->apply(3., [database(2.)]), Ok(3.))
    deepEqual(
      m.kept.contents.items,
      [
        {item: database(2.), state: databaseMade},
        {item: object(3.), state: Unasked({since: 0., address})},
      ],
    )
  },
)

test("a list behind the one held is answered with the generation held, unwritten", async () => {
  let m = memory()
  deepEqual(await m->apply(2., [object(1.)]), Ok(2.))
  deepEqual(await m->apply(1., [], ~tokens=[other]), Ok(2.))
  deepEqual(m.writes.contents, 1)
  deepEqual(m.kept.contents.tokens, None)
})

test("an item unasked keeps when it was first found so, and its address", async () => {
  let made: Management.keptItem = {item: object(1.), state: Made({address: "bucket"})}
  let m = memory(~kept={...initial, generation: 1., items: [made]})
  deepEqual(await m->apply(2., [], ~now=5.), Ok(2.))
  deepEqual(m.kept.contents.items, [{...made, state: Unasked({since: 5., address: "bucket"})}])
  deepEqual(await m->apply(3., [], ~now=9.), Ok(3.))
  deepEqual(m.kept.contents.items, [{...made, state: Unasked({since: 5., address: "bucket"})}])
  // Asked again, it is the item made, at its address.
  deepEqual(await m->apply(4., [object(1.)], ~now=12.), Ok(4.))
  deepEqual(m.kept.contents.items, [made])
})

test(
  "tokens named stand in place of the binding's, and a list naming none keeps them",
  async () => {
    let m = memory()
    deepEqual(await m->apply(1., [], ~tokens=[other]), Ok(1.))
    deepEqual(m.kept.contents.tokens, Some([other]))
    deepEqual(await m->apply(2., []), Ok(2.))
    deepEqual(m.kept.contents.tokens, Some([other]))
  },
)

test("a grace past a year is invalid, and a policy behind the one held is dropped", async () => {
  let m = memory()
  let policy = (generation, grace) => Management.setPolicy(m.store, ~now=0., ~generation, ~grace)
  deepEqual(reasonOf(await policy(1., 31536001)), Some("invalid"))
  deepEqual(reasonOf(await policy(1., -1)), Some("invalid"))
  deepEqual(await policy(2., 60), Ok(2.))
  deepEqual(await policy(1., 0), Ok(2.))
  deepEqual((m.kept.contents.policy, m.kept.contents.grace), (2., 60))
  deepEqual(await policy(2., 60), Ok(2.))
  deepEqual(m.writes.contents, 1)
  deepEqual(await policy(2., 30), Ok(2.))
  deepEqual(m.kept.contents.grace, 30)
})

test("an item asked is never ended, one unasked is at once, and one absent succeeds", async () => {
  let m = memory()
  ignore(await m->apply(1., [object(1.)]))
  deepEqual(reasonOf(await Management.end_(m.store, ~id=1.)), Some("still_asked"))
  ignore(await m->apply(2., []))
  deepEqual(await Management.end_(m.store, ~id=1.), Ok())
  deepEqual(m.kept.contents.items, [])
  deepEqual(await Management.end_(m.store, ~id=9.), Ok())
})

test("the sweep forgets what its grace passed, and writes nothing where none did", async () => {
  let unasked = (id, since): Management.keptItem => {
    item: object(id),
    state: Unasked({since: since}),
  }
  let m = memory(~kept={...initial, grace: 10, items: [unasked(1., 0.), unasked(2., 5000.)]})
  deepEqual(await Management.sweep(m.store, ~now=9999.), [])
  deepEqual(m.writes.contents, 0)
  deepEqual(await Management.sweep(m.store, ~now=10000.), [object(1.)])
  deepEqual(m.kept.contents.items, [unasked(2., 5000.)])
  let none = memory(~kept={...initial, grace: 0, items: [unasked(3., 7.)]})
  deepEqual(await Management.sweep(none.store, ~now=7.), [object(3.)])
})

test("a token is held by the binding's secret until a list names the tokens", async () => {
  let m = memory()
  let holds = given => Management.holds(m.store, ~given, hash)
  deepEqual(await holds(hash), true)
  deepEqual(await holds(other), false)
  deepEqual(await holds(""), false)
  deepEqual(await holds(hash ++ "0"), false)
  ignore(await m->apply(1., [], ~tokens=[other, hash]))
  deepEqual(await holds(other), true)
  ignore(await m->apply(2., [], ~tokens=[other]))
  deepEqual(await holds(hash), false)
})

/** A Worker of the organization's own adopted for app 1, by a made-up name. */
let front: Management.adopted = {kind: #function, name: "shop-front", for_: App(1.)}

let pages: Management.adopted = {
  kind: #function,
  name: "docs-pages",
  for_: Component({component: "pages", id: 2.}),
}

test("an adopted list is kept as given, an absent one leaving what is held", async () => {
  let m = memory()
  deepEqual(await m->apply(1., [], ~adopted=[front, pages]), Ok(1.))
  deepEqual(m.kept.contents.adopted, [front, pages])
  deepEqual(await m->apply(2., []), Ok(2.))
  deepEqual(m.kept.contents.adopted, [front, pages])
  deepEqual(m.kept.contents.warnings, [])
})

test(
  "an adopted name not exact, standing for what its kind cannot, or twice is invalid",
  async () => {
    let m = memory()
    let invalid = async adopted => reasonOf(await m->apply(1., [], ~adopted))
    deepEqual(await invalid([{...front, name: ""}]), Some("invalid"))
    deepEqual(await invalid([{...front, name: "shop-*"}]), Some("invalid"))
    deepEqual(await invalid([{...front, name: "shop?"}]), Some("invalid"))
    deepEqual(await invalid([{...front, for_: Item(1.)}]), Some("invalid"))
    deepEqual(await invalid([{kind: #object, name: "photos", for_: App(1.)}]), Some("invalid"))
    deepEqual(await invalid([front, {...pages, name: "shop-front"}]), Some("invalid"))
    deepEqual(await invalid([front, {...pages, for_: App(1.)}]), Some("invalid"))
    deepEqual(m.writes.contents, 0)
  },
)

test("an adopted kind not offered, an object or a database, is beyond the host", async () => {
  let m = memory()
  let beyond = async (~offered=[#function, #object, #database], adopted) =>
    reasonOf(await m->apply(1., [], ~adopted, ~offered))
  deepEqual(await beyond([front], ~offered=[#object]), Some("beyond_host"))
  deepEqual(await beyond([{kind: #object, name: "photos", for_: Item(2.)}]), Some("beyond_host"))
  deepEqual(await beyond([{kind: #database, name: "ledger", for_: Item(3.)}]), Some("beyond_host"))
  deepEqual(m.writes.contents, 0)
  deepEqual(await beyond([front], ~offered=[#function]), None)
})

/** A warning the driver raised for a Worker it let go, as it words one. */
let warning = (name): Management.warning => {
  reason: "delete_by_hand",
  name,
  message: `${name} is no longer managed`,
}

test(
  "a warning is cleared only for a name the list newly adds, never by a list sent again",
  async () => {
    let m = memory(~kept={...initial, adopted: [front], warnings: [warning("shop-front")]})
    ignore(await m->apply(1., [], ~adopted=[front]))
    deepEqual(m.kept.contents.warnings, [warning("shop-front")])
    ignore(await m->apply(2., [], ~adopted=[]))
    // A list dropping a name raises nothing here, the driver alone knowing whether it took it over.
    deepEqual(m.kept.contents.warnings, [warning("shop-front")])
    ignore(await m->apply(3., [], ~adopted=[front, pages]))
    deepEqual(m.kept.contents.warnings, [])
  },
)

test(
  "a Worker's name of no Worker's grammar is invalid, an item's held to exactness alone",
  async () => {
    let m = memory()
    let invalid = async adopted => reasonOf(await m->apply(1., [], ~adopted))
    deepEqual(await invalid([{...front, name: "Shop-front"}]), Some("invalid"))
    deepEqual(await invalid([{...front, name: "-shop"}]), Some("invalid"))
    deepEqual(await invalid([{...front, name: "shop.front"}]), Some("invalid"))
    deepEqual(await invalid([{...front, name: String.repeat("a", 64)}]), Some("invalid"))
    deepEqual(await invalid([{...front, name: "0a_shop-front"}]), None)
    deepEqual(await invalid([{...front, name: "1" ++ String.repeat("a", 62)}]), None)
  },
)

test(
  "a name pointed at another deployment in one apply is refused, two applies moving it",
  async () => {
    let m = memory()
    ignore(await m->apply(1., [], ~adopted=[front]))
    let elsewhere = {...front, for_: App(2.)}
    deepEqual(
      await m->apply(2., [], ~adopted=[elsewhere]),
      Error({
        reason: "invalid",
        message: [
          "shop-front stands for app 1; moving it to app 2 takes two applies,",
          "one dropping it and one adding it",
        ]->Array.join(" "),
      }),
    )
    deepEqual(m.kept.contents.adopted, [front])
    deepEqual(await m->apply(2., [], ~adopted=[]), Ok(2.))
    deepEqual(await m->apply(3., [], ~adopted=[elsewhere]), Ok(3.))
    deepEqual(m.kept.contents.adopted, [elsewhere])
  },
)

test("two entries for one component's id are invalid, whatever its name", async () => {
  let m = memory()
  let one: Management.adopted = {
    kind: #function,
    name: "docs-pages",
    for_: Component({component: "pages", id: 3.}),
  }
  let other = {...one, name: "docs-site", for_: Component({component: "site", id: 3.})}
  deepEqual(reasonOf(await m->apply(1., [], ~adopted=[one, other])), Some("invalid"))
  deepEqual(
    reasonOf(
      await m->apply(
        1.,
        [],
        ~adopted=[one, {...other, for_: Component({component: "site", id: 4.})}],
      ),
    ),
    None,
  )
})
