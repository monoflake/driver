/***
 * A fake of Cloudflare's API, which records what it is asked and keeps what each Worker runs, and
 * a store in memory, as the driver's D1 would keep deployments.
 */
/** The fake account, each Worker by its versions, the one it runs, and every call asked of it. */
type account = {
  versions: Map.t<string, Function.upload>,
  runs: Map.t<string, string>,
  asked: array<string>,
  refusing: ref<option<Function.refused>>,
}

let fake = () => {
  let account = {versions: Map.make(), runs: Map.make(), asked: [], refusing: ref(None)}
  let refused = () => account.refusing.contents->Option.map(r => Error(r))
  let api: Function.api = {
    upload: async (name, upload) => {
      account.asked->Array.push(`upload ${name} ${upload.tag}`)
      switch refused() {
      | Some(refused) => refused
      | None =>
        let id = `v${Int.toString(account.versions->Map.size + 1)}`
        account.versions->Map.set(id, upload)
        Ok(id)
      }
    },
    deploy: async (name, id) => {
      account.asked->Array.push(`deploy ${name} ${id}`)
      account.runs->Map.set(name, id)
      Ok()
    },
    running: async name => Ok(
      account.runs
      ->Map.get(name)
      ->Option.map(id => {
        Function.id,
        tag: account.versions->Map.get(id)->Option.map(u => u.tag),
      }),
    ),
    delete: async name => {
      account.asked->Array.push(`delete ${name}`)
      account.runs->Map.delete(name)->ignore
      Ok()
    },
    subdomain: async () => Ok("my-subdomain"),
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
