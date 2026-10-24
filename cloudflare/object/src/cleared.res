/***
 * What belongs to no item holding the bucket, deleted at most a batch of keys and their rows on
 * each request, so clearing goes on over requests and never runs past one, RFC nrs5v.
 */

/** The most keys one request deletes, as many as R2 deletes in one call. */
let batch = 1000

/**
 * One batch cleared, the keys under the first prefix no item holds, or once none is left the rows
 * of other items; what fails is taken up again by the next request.
 */
let clear = async (db, bucket, ~holding: option<Held.item>) => {
  let held = holding->Option.map(item => Held.prefixOf(item.id))
  switch await Stores.prefixes(bucket, ~limit=batch) {
  | Ok(prefixes) =>
    switch prefixes->Array.find(prefix => Some(prefix) != held) {
    | Some(stale) =>
      switch await Stores.list(bucket, ~prefix=stale, ~limit=batch) {
      | Ok({objects: []}) | Error(_) => ()
      | Ok({objects}) =>
        let keys = objects->Array.map(Stores.key)
        switch await Stores.deleteAll(bucket, keys) {
        | Ok() =>
          let names = keys->Array.map(key => key->String.slice(~start=String.length(stale)))
          switch stale->String.slice(~start=0, ~end=-1)->Float.fromString {
          | Some(item) => await Held.forgetAll(db, ~item, names)
          | None => ()
          }
        | Error(_) => ()
        }
      }
    | None =>
      let holding = holding->Option.map(item => item.id)
      ignore(await Held.forgetStale(db, ~holding, ~limit=batch))
    }
  | Error(_) => ()
  }
}
