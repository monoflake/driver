/*** `Management` on a store in memory, each write counted, as the driver's D1 would hold it. */
open Node

let initial: Management.kept = {
  generation: 0.,
  policy: 0.,
  grace: 604800,
  items: [],
  tokens: None,
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

let waiting = Management.Failed({
  reason: "beyond_host",
  message: "it waits on RFC nrs5v's next slice",
})

let apply = (m, ~now=0., ~tokens=?, generation, items) =>
  Management.apply(m.store, ~now, ~generation, ~items, ~tokens)

let reasonOf = result =>
  switch result {
  | Ok(_) => None
  | Error({Management.reason: reason}) => Some(reason)
  }

test("a list naming an item twice, or one with no credential or three, is invalid", async () => {
  let m = memory()
  deepEqual(reasonOf(await m->apply(1., [object(1.), object(1.)])), Some("invalid"))
  deepEqual(reasonOf(await m->apply(1., [object(1., ~credentials=[])])), Some("invalid"))
  let three = [hash, hash, hash]
  deepEqual(reasonOf(await m->apply(1., [object(1., ~credentials=three)])), Some("invalid"))
  deepEqual(m.writes.contents, 0)
})

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

test("an object or a database is held failed, waiting on the next slice", async () => {
  let m = memory()
  let database: Management.item = {id: 2., capacity: Database({size: 1.}), credentials: [hash]}
  deepEqual(await m->apply(1., [database, object(1.)]), Ok(1.))
  deepEqual(
    m.kept.contents.items,
    [{item: object(1.), state: waiting}, {item: database, state: waiting}],
  )
})

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
