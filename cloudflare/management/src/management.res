/***
 * The list held by generation, its grace and the binding's tokens, as driver(machine)'s `listed.rs`
 * and `tokens.rs` hold them, read and written whole through the store, RFC nrs5v.
 */

type refused = {reason: string, message: string}

type capacity =
  | Container({millicores: int, memory: float})
  | Volume({size: float})
  | Object({size: float})
  | Database({size: float})

type item = {id: float, capacity: capacity, credentials: array<string>}

type state =
  | Making
  | Made({address: string})
  | Failed({reason: string, message?: string})
  | Unasked({since: float, address?: string})

type keptItem = {item: item, state: state}

type kept = {
  generation: float,
  policy: float,
  grace: int,
  items: array<keptItem>,
  tokens: option<array<string>>,
}

type store = {read: unit => promise<kept>, write: kept => promise<unit>}

/** The longest grace, a year of 365 days in seconds. */
let year = 31_536_000

let invalid = message => Error({reason: "invalid", message})

/** A list naming each item once, each holding one credential, or two while one replaces another. */
let valid = (items: array<item>) => {
  let seen = Set.make()
  items->Array.reduce(Ok(), (result, item) =>
    switch result {
    | Error(_) => result
    | Ok() if seen->Set.has(item.id) =>
      invalid(`the list names item ${Float.toString(item.id)} twice`)
    | Ok() =>
      seen->Set.add(item.id)
      let count = item.credentials->Array.length
      let id = Float.toString(item.id)
      count >= 1 && count <= 2
        ? Ok()
        : invalid(`item ${id} holds one credential, or two while one replaces the other`)
    }
  )
}

/** The kinds this driver gives no item of, refused before anything of the list is held. */
let beyond = (items: array<item>) =>
  items
  ->Array.find(item =>
    switch item.capacity {
    | Container(_) | Volume(_) => true
    | Object(_) | Database(_) => false
    }
  )
  ->Option.map(item => {
    reason: "beyond_host",
    message: `item ${Float.toString(item.id)}: a Worker's account holds no container or volume`,
  })

/** What an item is made of here, an object or a database waiting on RFC nrs5v's next slice. */
let made = (capacity: capacity) =>
  switch capacity {
  | Object(_) | Database(_) =>
    Failed({reason: "beyond_host", message: "it waits on RFC nrs5v's next slice"})
  | Container(_) | Volume(_) => Failed({reason: "beyond_host"})
  }

/** An item asked again as it is held, kept as it stands, one failed made again with every list. */
let asked = (held: option<keptItem>, item: item) =>
  switch held {
  | Some(k) if k.item.capacity == item.capacity =>
    switch k.state {
    | Making | Made(_) => k.state
    | Unasked(u) =>
      switch u.address {
      | Some(address) => Made({address: address})
      | None => made(item.capacity)
      }
    | Failed(_) => made(item.capacity)
    }
  | Some(_) | None => made(item.capacity)
  }

/** An item the list no longer asks, since when it was first found so. */
let unasked = (held: keptItem, ~now) =>
  switch held.state {
  | Unasked(_) => held.state
  | Made({address}) => Unasked({since: now, address})
  | Making | Failed(_) => Unasked({since: now})
  }

let byId = (a: keptItem, b: keptItem) => Float.compare(a.item.id, b.item.id)

let apply = async (store, ~now, ~generation, ~items: array<item>, ~tokens) =>
  switch valid(items) {
  | Error(_) as refused => refused
  | Ok() =>
    let kept = await store.read()
    if generation < kept.generation {
      Ok(kept.generation)
    } else {
      switch beyond(items) {
      | Some(refused) => Error(refused)
      | None =>
        let held = id => kept.items->Array.find(k => k.item.id == id)
        let listed = items->Array.map(item => {item, state: asked(held(item.id), item)})
        let left =
          kept.items
          ->Array.filter(k => !(items->Array.some(item => item.id == k.item.id)))
          ->Array.map(k => {...k, state: unasked(k, ~now)})
        await store.write({
          ...kept,
          generation,
          items: Array.concat(listed, left)->Array.toSorted(byId),
          tokens: switch tokens {
          | Some(_) => tokens
          | None => kept.tokens
          },
        })
        Ok(generation)
      }
    }
  }

let setPolicy = async (store, ~now as _, ~generation, ~grace) =>
  if grace < 0 || grace > year {
    invalid(`a grace is at most a year, ${Int.toString(year)} seconds`)
  } else {
    let kept = await store.read()
    if generation >= kept.policy && (generation != kept.policy || grace != kept.grace) {
      await store.write({...kept, policy: generation, grace})
      Ok(generation)
    } else {
      Ok(Math.max(generation, kept.policy))
    }
  }

let describe = (store, ~now as _) => store.read()

let end_ = async (store, ~id) => {
  let kept = await store.read()
  switch kept.items->Array.find(k => k.item.id == id) {
  | None => Ok()
  | Some({state: Unasked(_)}) =>
    await store.write({...kept, items: kept.items->Array.filter(k => k.item.id != id)})
    Ok()
  | Some({state: Making | Made(_) | Failed(_)}) =>
    Error({reason: "still_asked", message: `the list still asks item ${Float.toString(id)}`})
  }
}

let sweep = async (store, ~now) => {
  let kept = await store.read()
  let grace = Int.toFloat(kept.grace) *. 1000.
  let past = (k: keptItem) =>
    switch k.state {
    | Unasked({since}) => now >= since +. grace
    | Making | Made(_) | Failed(_) => false
    }
  let gone = kept.items->Array.filter(past)
  if gone != [] {
    await store.write({...kept, items: kept.items->Array.filter(k => !past(k))})
  }
  gone->Array.map(k => k.item)
}

/** Whether two texts are one, every character read, so the time it takes names no match. */
let same = (a, b) => {
  let code = (text, at) =>
    text->String.charCodeAt(Int.mod(at, Math.Int.max(1, String.length(text))))->Option.getOr(0)
  let differ = ref(String.length(a) == String.length(b) ? 0 : 1)
  for at in 0 to Math.Int.max(String.length(a), String.length(b)) - 1 {
    differ := differ.contents ||| code(a, at) ^^^ code(b, at)
  }
  differ.contents == 0
}

let holds = async (store, ~given, hash) => {
  let kept = await store.read()
  kept.tokens
  ->Option.getOr([given])
  ->Array.reduce(false, (found, held) => same(held, hash) || found)
}
