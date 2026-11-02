/** The upload metadata keeps secrets while sending only the names a deploy gives. */
open Node
open Calls

let metadataOf = (init: fetchInit) =>
  init.body
  ->Option.flatMap(body => body->formField("metadata")->Nullable.toOption)
  ->Option.map(text => JSON.parseOrThrow(text))
  ->Option.getOrThrow

let checkedMetadata = (metadata, bindings) => {
  deepEqual(metadata->Account.member("keep_bindings"), Some(JSON.parseOrThrow(`["secret_text"]`)))
  let secret = binding => binding->Account.member("type") == Some(JSON.String("secret_text"))
  let listed = metadata->Account.member("bindings")->Option.flatMap(JSON.Decode.array)
  deepEqual(listed->Option.map(all => all->Array.filter(secret)), Some(bindings))
}

/** Each upload captured at the account boundary, with a previous deployment when asked. */
let uploaded = async (~first=false, ~secrets) => {
  let env = envOf()
  let account = Account.make(~artifacts=dict{"https://artifacts.example/hello": artifact})
  let uploads = ref([])
  let restore = replaced(async (url, init) => {
    if init.method == "PUT" || (init.method == "POST" && url->String.endsWith("/versions")) {
      uploads.contents->Array.push((init.method, metadataOf(init)))
    }
    await account(url, init)
  })
  try {
    let base = await deployInput(app(1))
    if !first {
      let (status, _, _) = await deploying(env, "deploy", base)
      deepEqual(status, 200)
      uploads := []
    }
    let input = base->String.replace(`"secrets": {},`, secrets)
    let input = first
      ? input
      : input->String.replace(
          `"version": "${Envelope.Hex.encode(await sha256(artifact))}"`,
          `"version": "${String.repeat("ff", 32)}"`,
        )
    let (status, _, _) = await deploying(env, "deploy", input)
    deepEqual(status, 200)
    restore()
    uploads.contents
  } catch {
  | JsExn(error) =>
    restore()
    throw(JsExn.anyToExnInternal(error))
  }
}

test("a deploy without secrets keeps secret text and uploads no secret names", async () => {
  let uploads = await uploaded(~secrets="")
  deepEqual(uploads->Array.map(((method, _)) => method), ["POST"])
  let (_, metadata) = uploads->Array.getUnsafe(0)
  checkedMetadata(metadata, [])
})

test("a deploy naming one secret sends it and keeps other secret text", async () => {
  let uploads = await uploaded(
    ~secrets=`"secrets": {"KEY": "${Envelope.Base64url.encode(Web.utf8("new value"))}"},`,
  )
  deepEqual(uploads->Array.map(((method, _)) => method), ["POST"])
  let (_, metadata) = uploads->Array.getUnsafe(0)
  checkedMetadata(
    metadata,
    [JSON.parseOrThrow(`{"type": "secret_text", "name": "KEY", "text": "new value"}`)],
  )
})

test("a first deploy keeps secret text on each upload including the initial stub", async () => {
  let uploads = await uploaded(~first=true, ~secrets="")
  deepEqual(uploads->Array.map(((method, _)) => method), ["POST", "PUT", "POST"])
  uploads->Array.forEach(((_, metadata)) => checkedMetadata(metadata, []))
})
