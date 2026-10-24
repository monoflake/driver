/***
 * What belongs to no item holding the bucket, deleted at most a batch of keys and their rows on
 * each request, so clearing goes on over requests and never runs past one, RFC nrs5v.
 */

/** The most keys one request deletes, as many as R2 deletes in one call. */
let batch = 1000

/**
 * One batch cleared, the keys under the first prefix whose item `items` lacks, or once none is left
 * the rows of such items; what fails is taken up again by the next request.
 */
let clear = async (db, bucket) =>
  switch await Stores.prefixes(bucket, ~limit=batch) {
  | Ok(prefixes) =>
    // Items are read after the prefixes, as a key stands under an id only once `items` holds it.
    let ids = await Held.ids(db)
    let absent = prefix => !(ids->Array.some(id => Held.prefixOf(id) == prefix))
    switch prefixes->Array.find(absent) {
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
    | None => ignore(await Held.forgetStale(db, ~limit=batch))
    }
  | Error(_) => ()
  }
