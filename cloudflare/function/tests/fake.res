/***
 * A fake of Cloudflare's API, which records what it is asked and keeps what each Worker runs, and
 * a store in memory, as the driver's D1 would keep deployments.
 */

/** A call the fake refuses, before a Worker is made or once it is. */
type step = Upload | Deploy

/** The fake account, each Worker by its versions, the one it runs, and every call asked of it. */
type account = {
  versions: Map.t<string, Function.upload>,
  runs: Map.t<string, string>,
  asked: array<string>,
  refusing: ref<option<(step, Function.refused)>>,
  /** How many more times asking what a Worker runs is answered before it fails, if it ever does. */
  seeing: ref<option<int>>,
}

/** The version a Worker made runs first, the stub, which holds no tag. */
let made = "made"

let fake = () => {
  let account = {
    versions: Map.make(),
    runs: Map.make(),
    asked: [],
    refusing: ref(None),
    seeing: ref(None),
  }
  let refused = step =>
    switch account.refusing.contents {
    | Some((refusing, r)) if refusing == step => Some(Error(r))
    | Some(_) | None => None
    }
  let api: Function.api = {
    upload: async (name, upload) => {
      account.asked->Array.push(`upload ${name} ${upload.tag}`)
      switch refused(Upload) {
      | Some(refused) => refused
      | None =>
        if !(account.runs->Map.has(name)) {
          account.runs->Map.set(name, made)
        }
        let id = `v${Int.toString(account.versions->Map.size + 1)}`
        account.versions->Map.set(id, upload)
        Ok(id)
      }
    },
    deploy: async (name, id) => {
      account.asked->Array.push(`deploy ${name} ${id}`)
      switch refused(Deploy) {
      | Some(refused) => refused
      | None =>
        account.runs->Map.set(name, id)
        Ok()
      }
    },
    running: async name =>
      switch account.seeing.contents {
      | Some(0) => Error({Function.reason: "fault", message: "Cloudflare's API answered 500"})
      | Some(n) =>
        account.seeing := Some(n - 1)
        Ok(None)
      | None =>
        Ok(
          account.runs
          ->Map.get(name)
          ->Option.map(id => {
            Function.id,
            tag: account.versions->Map.get(id)->Option.map(u => u.tag),
          }),
        )
      },
    delete: async name => {
      account.asked->Array.push(`delete ${name}`)
      account.runs->Map.delete(name)->ignore
      Ok()
    },
    address: async name => Ok(`${name}.example`),
  }
  (account, api)
}

let memory = () => {
  let kept = Map.make()
  let store: Function.store = {
    read: async name => kept->Map.get(name),
    write: async (name, k) => kept->Map.set(name, k),
    forget: async name => kept->Map.delete(name)->ignore,
  }
  (kept, store)
}

let artifact = Tar.bundled([Tar.file("main.js", "export default {}")])

/** Each address served and its bytes, every other one unfetchable. */
let served = (addresses: dict<Uint8Array.t>, fetched) =>
  async address => {
    fetched->Array.push(address)
    switch addresses->Dict.get(address) {
    | Some(bytes) => Ok(bytes)
    | None => Error({Function.reason: "unfetchable", message: "nothing serves it"})
    }
  }

let setUp = (~addresses=dict{"hello": artifact}) => {
  let (account, api) = fake()
  let (kept, store) = memory()
  let fetched = []
  let through: Function.through = {api, store, fetch: served(addresses, fetched)}
  (through, account, kept, fetched)
}
