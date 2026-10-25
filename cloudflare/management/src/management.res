/***
 * The list held by generation, its grace and the binding's tokens, as driver(machine)'s `listed.rs`
 * and `tokens.rs` hold them, read and written whole through the store, RFC nrs5v.
 */

type warning = {reason: string, message: string, name: string}

type refused = {reason: string, message: string}

type capacity =
  | Container({millicores: int, memory: float})
  | Volume({size: float})
  | Object({size: float})
  | Database({size: float})

type kind = [#function | #object | #database]

type item = {id: float, capacity: capacity, credentials: array<string>}

type state =
  | Making
  | Made({address: string})
  | Failed({reason: string, message?: string})
  | Unasked({since: float, address?: string})

type keptItem = {item: item, state: state}

type adoptedFor = App(float) | Component({component: string, id: float}) | Item(float)

type adopted = {kind: [#function | #object | #database], name: string, for_: adoptedFor}

type kept = {
  generation: float,
  policy: float,
  grace: int,
  items: array<keptItem>,
  tokens: option<array<string>>,
  adopted: array<adopted>,
  warnings: array<warning>,
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

let kindName = (kind: kind) =>
  switch kind {
  | #function => "function"
  | #object => "object"
  | #database => "database"
  }

/** What makes a name a pattern rather than one exact name, or no name at all, RFC nrs5v. */
let pattern = /[*?\[\]{}\s]/

/** A Worker's name as Cloudflare takes one, which a listed Worker's name is held to. */
let workerName = /^[a-z0-9][a-z0-9_-]{0,62}$/

/** What an entry stands for as matching keys it, a component by its id alone, RFC y2xd3. */
let forKey = (for_: adoptedFor) =>
  switch for_ {
  | App(id) => `app ${Float.toString(id)}`
  | Component({id}) => `component ${Float.toString(id)}`
  | Item(id) => `item ${Float.toString(id)}`
  }

let forName = (for_: adoptedFor) =>
  switch for_ {
  | App(id) => `app ${Float.toString(id)}`
  | Component({component, id}) => `component ${component} ${Float.toString(id)}`
  | Item(id) => `item ${Float.toString(id)}`
  }

/** Whether an entry stands for what its kind may, a deployment for a function, else an item. */
let fits = (entry: adopted) =>
  switch (entry.kind, entry.for_) {
  | (#function, App(_) | Component(_)) | (#object | #database, Item(_)) => true
  | (#function, Item(_)) | (#object | #database, App(_) | Component(_)) => false
  }

/**
 * An exception list naming each resource once by its exact name, each standing for what its kind
 * may, and no deployment or item twice.
 */
let validAdopted = (adopted: array<adopted>) => {
  let names = Set.make()
  let fors = Set.make()
  adopted->Array.reduce(Ok(), (result, entry) =>
    switch result {
    | Error(_) => result
    | Ok() if entry.name == "" => invalid("an adopted name is one exact name, never empty")
    | Ok() if pattern->RegExp.test(entry.name) =>
      invalid(`the adopted name "${entry.name}" is one exact name, never a pattern`)
    | Ok() if entry.kind == #function && !(workerName->RegExp.test(entry.name)) =>
      invalid(`the adopted name "${entry.name}" is no Worker's name, ^[a-z0-9][a-z0-9_-]{0,62}$`)
    | Ok() if !fits(entry) =>
      invalid(`${entry.name} is adopted as ${kindName(entry.kind)} for ${forName(entry.for_)}`)
    | Ok() if names->Set.has(entry.name) => invalid(`the list adopts ${entry.name} twice`)
    | Ok() if fors->Set.has(forKey(entry.for_)) =>
      invalid(`the list adopts two resources for ${forKey(entry.for_)}`)
    | Ok() =>
      names->Set.add(entry.name)
      fors->Set.add(forKey(entry.for_))
      Ok()
    }
  )
}

/**
 * An entry the host cannot hold, of a kind not offered, or an object or a database, whose wiring
 * waits on the one D1 an item, RFC nrs5v's Ledger.
 */
let beyondAdopted = (adopted: array<adopted>, ~offered: array<kind>) =>
  adopted->Array.findMap(entry =>
    if !(offered->Array.includes(entry.kind)) {
      let only = offered->Array.map(kindName)->Array.join(", ")
      Some({
        reason: "beyond_host",
        message: `${entry.name}: ${kindName(entry.kind)} is not offered, only ${only}`,
      })
    } else {
      switch entry.kind {
      | #function => None
      | #object | #database =>
        Some({
          reason: "beyond_host",
          message: `${entry.name}: an adopted ${kindName(entry.kind)} cannot be held here yet`,
        })
      }
    }
  )

/**
 * The warnings standing once the list is `adopted`, each cleared only for a name it newly adds;
 * a Worker let go is warned of by the driver, which alone knows whether it took it over.
 */
let warnedOf = (kept: kept, adopted: array<adopted>) => {
  let added = name =>
    adopted->Array.some(entry => entry.name == name) &&
      !(kept.adopted->Array.some(entry => entry.name == name))
  kept.warnings->Array.filter(warning => !added(warning.name))
}

/** An entry pointing a name kept at another deployment or item, which takes two applies, nrs5v. */
let moved = (kept: kept, adopted: array<adopted>) =>
  adopted->Array.findMap(entry =>
    kept.adopted
    ->Array.find(held => held.name == entry.name && held.for_ != entry.for_)
    ->Option.map(held => {
      reason: "invalid",
      message: `${entry.name} stands for ${forName(held.for_)}; moving it to ${forName(
          entry.for_,
        )} takes two applies, one dropping it and one adding it`,
    })
  )

/** The most an `object` item holds in bytes, 1 TiB, while this driver's cost is watched, nrs5v. */
let most = 1_099_511_627_776.

/** The most a `database` item holds in bytes, D1's 10 GB a database, nrs5v. */
let mostDatabase = 10_000_000_000.

let isObject = (item: item) =>
  switch item.capacity {
  | Object(_) => true
  | Container(_) | Volume(_) | Database(_) => false
  }

let isDatabase = (item: item) =>
  switch item.capacity {
  | Database(_) => true
  | Container(_) | Volume(_) | Object(_) => false
  }

/**
 * What this driver cannot hold, refused before anything of the list is held, a container, a volume,
 * a second `object` or `database` item past the binding's one of each, or an item past its most.
 */
let beyond = (items: array<item>) => {
  let refused = (item: item, message) => {
    reason: "beyond_host",
    message: `item ${Float.toString(item.id)}: ${message}`,
  }
  let past = (item: item) =>
    switch item.capacity {
    | Object({size}) => size > most ? Some(most) : None
    | Database({size}) => size > mostDatabase ? Some(mostDatabase) : None
    | Container(_) | Volume(_) => None
    }
  let unheld = items->Array.find(item =>
    switch item.capacity {
    | Container(_) | Volume(_) => true
    | Object(_) | Database(_) => false
    }
  )
  let second = items->Array.filter(isObject)->Array.get(1)
  let secondDatabase = items->Array.filter(isDatabase)->Array.get(1)
  let large = items->Array.findMap(item => past(item)->Option.map(most => (item, most)))
  switch (unheld, second, secondDatabase, large) {
  | (Some(item), _, _, _) => Some(refused(item, "a Worker's account holds no container or volume"))
  | (None, Some(second), _, _) =>
    Some(refused(second, "the binding holds one bucket, so a list holds one object item"))
  | (None, None, Some(second), _) =>
    Some(refused(second, "the binding holds one database, so a list holds one database item"))
  | (None, None, None, Some((item, most))) =>
    Some(refused(item, `past ${Float.toString(most)} bytes, the most this driver takes`))
  | (None, None, None, None) => None
  }
}

/** What an item is made of here, an object or a database at its Worker's address. */
let made = async (capacity: capacity, ~bucket, ~database) => {
  let at = async address =>
    switch await address() {
    | Ok(address) => Made({address: address})
    | Error({reason, message}) => Failed({reason, message})
    }
  switch capacity {
  | Object(_) => await at(bucket)
  | Database(_) => await at(database)
  | Container(_) | Volume(_) => Failed({reason: "beyond_host"})
  }
}

/** An item asked again as it is held, kept as it stands, one failed made again with every list. */
let asked = async (held: option<keptItem>, item: item, ~bucket, ~database) =>
  switch held {
  | Some(k) if k.item.capacity == item.capacity =>
    switch k.state {
    | Making | Made(_) => k.state
    | Unasked(u) =>
      switch u.address {
      | Some(address) => Made({address: address})
      | None => await made(item.capacity, ~bucket, ~database)
      }
    | Failed(_) => await made(item.capacity, ~bucket, ~database)
    }
  | Some(_) | None => await made(item.capacity, ~bucket, ~database)
  }

/** An item the list no longer asks, since when it was first found so. */
let unasked = (held: keptItem, ~now) =>
  switch held.state {
  | Unasked(_) => held.state
  | Made({address}) => Unasked({since: now, address})
  | Making | Failed(_) => Unasked({since: now})
  }

/** An item unasked yet holding the bucket or the database, made once and within its grace. */
let holding = (k: keptItem) =>
  switch (k.item.capacity, k.state) {
  | (Object(_) | Database(_), Unasked(u)) => u.address != None
  | (Object(_) | Database(_), Making | Made(_) | Failed(_)) | (Container(_) | Volume(_), _) => false
  }

/** The one item a kind's store is held for, failed while an older one unasked still holds it. */
let heldBy = (holder: option<keptItem>, ~what) =>
  holder->Option.map(h => {
    let id = Float.toString(h.item.id)
    Failed({
      reason: "beyond_host",
      message: `the binding holds one ${what}, item ${id}'s, until it is ended or swept`,
    })
  })

/** A call asked once at most, its answer kept for every later asking. */
let once = ask => {
  let asked = ref(None)
  () =>
    switch asked.contents {
    | Some(answer) => answer
    | None =>
      let answer = ask()
      asked := Some(answer)
      answer
    }
}

let byId = (a: keptItem, b: keptItem) => Float.compare(a.item.id, b.item.id)

/** The first item of a kind install did not offer, refused whole as a container is, nrs5v. */
let unoffered = (items: array<item>, ~offered: array<kind>) => {
  let kindOf = (item: item): option<kind> =>
    switch item.capacity {
    | Object(_) => Some(#object)
    | Database(_) => Some(#database)
    | Container(_) | Volume(_) => None
    }
  items
  ->Array.findMap(item =>
    kindOf(item)->Option.flatMap(kind => offered->Array.includes(kind) ? None : Some((item, kind)))
  )
  ->Option.map(((item, kind)) => {
    let only = offered->Array.map(kindName)->Array.join(", ")
    {
      reason: "beyond_host",
      message: `item ${Float.toString(item.id)}: ${kindName(kind)} is not offered, only ${only}`,
    }
  })
}

let apply = async (
  store,
  ~offered,
  ~now,
  ~generation,
  ~items: array<item>,
  ~tokens,
  ~adopted,
  ~objects,
  ~databases,
) =>
  switch valid(items)->Result.flatMap(() => validAdopted(adopted->Option.getOr([]))) {
  | Error(_) as refused => refused
  | Ok() =>
    let kept = await store.read()
    if generation < kept.generation {
      Ok(kept.generation)
    } else {
      let beyondList = adopted->Option.flatMap(beyondAdopted(_, ~offered))
      switch adopted
      ->Option.flatMap(moved(kept, _))
      ->Option.orElse(beyond(items))
      ->Option.orElse(unoffered(items, ~offered))
      ->Option.orElse(beyondList) {
      | Some(refused) => Error(refused)
      | None =>
        let held = id => kept.items->Array.find(k => k.item.id == id)
        let left =
          kept.items
          ->Array.filter(k => !(items->Array.some(item => item.id == k.item.id)))
          ->Array.map(k => {...k, state: unasked(k, ~now)})
        let bucket = once(objects)
        let database = once(databases)
        // Each store is its holder's until it is ended or swept, as driver(machine)'s `bucketed`.
        let bucketHeld =
          left->Array.find(k => holding(k) && isObject(k.item))->heldBy(~what="bucket")
        let databaseHeld =
          left->Array.find(k => holding(k) && isDatabase(k.item))->heldBy(~what="database")
        let listed = await Promise.all(
          items->Array.map(async item => {
            let state = switch (item.capacity, bucketHeld, databaseHeld) {
            | (Object(_), Some(failed), _) | (Database(_), _, Some(failed)) => failed
            | (Object(_), None, _) | (Database(_), _, None) | (Container(_) | Volume(_), _, _) =>
              await asked(held(item.id), item, ~bucket, ~database)
            }
            {item, state}
          }),
        )
        await store.write({
          ...kept,
          generation,
          items: Array.concat(listed, left)->Array.toSorted(byId),
          tokens: switch tokens {
          | Some(_) => tokens
          | None => kept.tokens
          },
          // An absent list leaves what is held, and one given replaces it whole, as items do.
          adopted: adopted->Option.getOr(kept.adopted),
          warnings: switch adopted {
          | Some(adopted) => warnedOf(kept, adopted)
          | None => kept.warnings
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
