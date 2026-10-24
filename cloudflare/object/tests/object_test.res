/*** The Worker `object` where the samples do not reach, its token, its one item and its count. */
open Node
module Contracts = Envelope.Contracts

let reasonOf = ((status, json)) => (status, json->Served.textOf("reason"))
let messageOf = ((_, json)) => json->Served.textOf("message")
let success = data => JSON.parseOrThrow(`{"status": "success", "data": ${data}}`)

/** A write of so many bytes, its content base64url. */
let write = (served, name, length) =>
  served->Served.call(
    "write",
    `{"name": "${name}", "content": "${Envelope.Base64url.encode(Uint8Array.fromLength(length))}"}`,
  )

test("a call is answered only for the binding's token, or the tokens an apply named", async () => {
  let served = Served.make(~size=1024.)
  let describe = authorization => served->Served.call(~authorization, "describe", `{"name": "a"}`)
  let other = Uint8Array.fromLength(32)->TypedArray.fillAll(9)
  let theirs = `Bearer 1.${Envelope.Base64url.encode(other)}`
  deepEqual(reasonOf(await describe("")), (403, Some("denied")))
  deepEqual(reasonOf(await describe(theirs)), (403, Some("denied")))
  deepEqual(await describe(`Bearer ${Served.token}`), (200, success("{}")))
  let hash = Envelope.Hex.encode(Keys.Hash.plain(other))
  served.sqlite->run("UPDATE held SET listed = 1", [])
  served.sqlite->run("INSERT INTO tokens (hash) VALUES (?)", [JSON.String(hash)])
  deepEqual(reasonOf(await describe(`Bearer ${Served.token}`)), (403, Some("denied")))
  deepEqual(await describe(theirs), (200, success("{}")))
})

test(
  "with no object item a read is not found, a list holds nothing and a write no room",
  async () => {
    let served = Served.make()
    served->Served.item(~kind="database", 1024.)
    served->Served.item(~id=2., ~state="failed", 1024.)
    deepEqual(reasonOf(await served->write("a", 5)), (503, Some("storage_full")))
    deepEqual(
      reasonOf(await served->Served.call("read", `{"name": "a"}`)),
      (404, Some("not_found")),
    )
    deepEqual(await served->Served.call("describe", `{"name": "a"}`), (200, success("{}")))
    deepEqual(await served->Served.call("delete", `{"name": "a"}`), (200, success("{}")))
    deepEqual(
      await served->Served.call("list", `{"prefix": ""}`),
      (200, success(`{"objects": []}`)),
    )
  },
)

test("an item unasked once made still holds the bucket, within its grace", async () => {
  let served = Served.make()
  served->Served.item(~state="unasked", ~address="object.my-subdomain.workers.dev", ~since=1., 8.)
  deepEqual(await served->write("a", 5), (200, success("{}")))
  deepEqual(reasonOf(await served->write("b", 5)), (503, Some("storage_full")))
})

test(
  "what the bucket holds is counted, a write replacing or a delete freeing its room",
  async () => {
    let served = Served.make(~size=10.)
    deepEqual(await served->write("a", 6), (200, success("{}")))
    deepEqual(reasonOf(await served->write("b", 6)), (503, Some("storage_full")))
    served.clock := 1000.
    deepEqual(await served->write("a", 4), (200, success("{}")))
    deepEqual(await served->write("b", 6), (200, success("{}")))
    deepEqual(counted(served.sqlite), [(1., "a", 4.), (1., "b", 6.)])
    deepEqual(await served->Served.call("delete", `{"name": "a"}`), (200, success("{}")))
    deepEqual(counted(served.sqlite), [(1., "b", 6.)])
    deepEqual(await served->write("c", 4), (200, success("{}")))
  },
)

test("a write refused after another to its key is counted as the other left it", async () => {
  let served = Served.make(~size=10.)
  ignore(await served->write("a", 3))
  served.clock := 1000.
  // A second write lands between the first's count and its put, which R2 then refuses.
  served.env.objects->before("put", async () => ignore(await served->write("a", 2)))
  deepEqual(reasonOf(await served->write("a", 5)), (500, Some("fault")))
  deepEqual((keys(served.env.objects), counted(served.sqlite)), (["1/a"], [(1., "a", 2.)]))
})

test("a delete between a write's count and its put leaves the object counted", async () => {
  let served = Served.make(~size=10.)
  served.env.objects->before("put", async () =>
    ignore(await served->Served.call("delete", `{"name": "a"}`))
  )
  deepEqual(await served->write("a", 5), (200, success("{}")))
  deepEqual((keys(served.env.objects), counted(served.sqlite)), (["1/a"], [(1., "a", 5.)]))
})

test("a write within a second of the last to its key is a fault asking it again", async () => {
  let served = Served.make(~size=10.)
  deepEqual(await served->write("a", 3), (200, success("{}")))
  let again = await served->write("a", 5)
  deepEqual(
    (reasonOf(again), messageOf(again)),
    (
      (500, Some("fault")),
      Some("R2 takes one write a second to a key, so send this write again in a second"),
    ),
  )
  deepEqual(counted(served.sqlite), [(1., "a", 3.)])
  let first = await served->write("b", 2)
  let refused = await served->write("b", 2)
  deepEqual((first, reasonOf(refused)), ((200, success("{}")), (500, Some("fault"))))
  deepEqual(counted(served.sqlite), [(1., "a", 3.), (1., "b", 2.)])
})

test("a range of no bytes, or past the end, is read empty beside the size", async () => {
  let served = Served.make(~size=10.)
  ignore(await served->write("a", 5))
  let read = range => served->Served.call("read", `{"name": "a", "range": ${range}}`)
  // The bucket in memory fails a get of no bytes, so these two never ask R2 for one.
  deepEqual(await read(`{"start": 2, "length": 0}`), (200, success(`{"content": "", "size": 5}`)))
  deepEqual(await read(`{"start": 9, "length": 0}`), (200, success(`{"content": "", "size": 5}`)))
  deepEqual(
    reasonOf(
      await served->Served.call("read", `{"name": "b", "range": {"start": 0, "length": 0}}`),
    ),
    (404, Some("not_found")),
  )
  deepEqual(await read(`{"start": 9, "length": 3}`), (200, success(`{"content": "", "size": 5}`)))
  deepEqual(
    reasonOf(
      await served->Served.call("read", `{"name": "b", "range": {"start": 9, "length": 3}}`),
    ),
    (404, Some("not_found")),
  )
})

test("a call in CBOR is answered in CBOR", async () => {
  let served = Served.make(~size=10.)
  let envelope: Contracts.Interface.Object.envelope = {
    call: Write({name: "a", content: Web.utf8("hello")}),
    capabilities: [],
  }
  let body = Contracts.Interface.Object.toCbor(envelope)->Codec.Cbor.encode->Result.getOrThrow
  let response = await Object.fetch(
    request(
      "https://object.example.workers.dev/object/write",
      {
        method: "POST",
        headers: dict{
          "authorization": `Bearer ${Served.token}`,
          "content-type": "application/cbor",
        },
        body,
      },
    ),
    served.env,
  )
  let answer =
    (await response->Web.responseBytes)
    ->Codec.Cbor.decode
    ->Result.getOrThrow
    ->Contracts.Answer.fromCbor(Contracts.ObjectWritten.fromCbor)
  deepEqual(
    (
      response->Web.status,
      answer->Result.map(a => Contracts.Answer.toJson(a, Contracts.ObjectWritten.toJson)),
    ),
    (200, Ok(success("{}"))),
  )
})

test("a call not as its interface writes it is malformed", async () => {
  let served = Served.make(~size=10.)
  let malformed = (400, Some("malformed"))
  let describe = `{"name": "a"}`
  deepEqual(reasonOf(await served->Served.call(~method="PUT", "describe", describe)), malformed)
  deepEqual(
    reasonOf(await served->Served.call(~path="/object/read", "describe", describe)),
    malformed,
  )
  deepEqual(
    reasonOf(await served->Served.call(~path="/objects/describe", "describe", describe)),
    malformed,
  )
  deepEqual(reasonOf(await served->Served.call(~path="/object", "describe", describe)), malformed)
  deepEqual(reasonOf(await served->Served.call("describe", "{}")), malformed)
  deepEqual(
    reasonOf(await served->Served.call(~contentType="text/plain", "describe", describe)),
    (400, None),
  )
})

test("a body past a content at its bound in base64url and 2 MiB beside is malformed", async () => {
  let served = Served.make(~size=10.)
  let largest = 24_466_776
  let sent = async length => {
    let response = await Object.fetch(
      request(
        "https://object.example.workers.dev/object/write",
        {
          method: "POST",
          headers: dict{
            "authorization": `Bearer ${Served.token}`,
            "content-type": "application/json",
          },
          body: Uint8Array.fromLength(length)->TypedArray.fillAll(32),
        },
      ),
      served.env,
    )
    let json = JSON.parseOrThrow(Web.fromUtf8(await response->Web.responseBytes)->Option.getOr(""))
    (response->Web.status, json->Served.textOf("reason"), json->Served.textOf("message"))
  }
  deepEqual(
    await sent(largest + 1),
    (400, Some("malformed"), Some("a call's body is at most 24466776 bytes")),
  )
  // At the bound the body is read whole, and being blank it is no JSON.
  deepEqual(await sent(largest), (400, Some("malformed"), Some("the body is not JSON")))
})

/** The item made now replaced by another, as an end and the next list leave D1. */
let replaced = (served: Served.served, id) => {
  served.sqlite->run("DELETE FROM items", [])
  served->Served.item(~id, 1024.)
}

test("an item made after another ended sees none of its objects, nor counts them", async () => {
  let served = Served.make(~size=1024.)
  ignore(await served->write("a", 5))
  ignore(await served->write("b", 5))
  served->replaced(2.)
  deepEqual(reasonOf(await served->Served.call("read", `{"name": "a"}`)), (404, Some("not_found")))
  deepEqual(await served->Served.call("describe", `{"name": "b"}`), (200, success("{}")))
  deepEqual(await served->Served.call("list", `{"prefix": ""}`), (200, success(`{"objects": []}`)))
  deepEqual(await served->write("a", 1024), (200, success("{}")))
  deepEqual(keys(served.env.objects), ["2/a"])
  deepEqual(counted(served.sqlite), [(2., "a", 1024.)])
})

test(
  "an item's keys left of another still in items stay apart from it, by name or after",
  async () => {
    let served = Served.make()
    // Items 1 and 20 are unasked and were never made, so they hold no bucket yet stay in `items`.
    served->Served.item(~state="unasked", 1024.)
    served->Served.item(~id=2., 1024.)
    served->Served.item(~id=20., ~state="unasked", 1024.)
    for at in 0 to 2 {
      let key = ["1/a", "1/b/c", "20/a"]->Array.getUnsafe(at)
      await served.env.objects->placed(key, Uint8Array.fromLength(3))
    }
    ignore(await served->write("z", 1))
    let call = (operation, input) => served->Served.call(operation, input)
    let none = (200, success("{}"))
    deepEqual(await call("describe", `{"name": "a"}`), none)
    deepEqual(await call("describe", `{"name": "../1/a"}`), none)
    deepEqual(await call("describe", `{"name": "0/a"}`), none)
    deepEqual(reasonOf(await call("read", `{"name": "b/c"}`)), (404, Some("not_found")))
    deepEqual(reasonOf(await call("read", `{"name": "../1/b/c"}`)), (404, Some("not_found")))
    let own = (200, success(`{"objects": [{"name": "z", "size": 1}]}`))
    deepEqual(await call("list", `{"prefix": ""}`), own)
    deepEqual(await call("list", `{"prefix": "", "after": "../1/"}`), own)
    deepEqual(await call("list", `{"prefix": "", "after": "\\u0000"}`), own)
    deepEqual(await call("list", `{"prefix": "0"}`), (200, success(`{"objects": []}`)))
    deepEqual(await call("list", `{"prefix": "", "after": "z"}`), (200, success(`{"objects": []}`)))
    deepEqual(keys(served.env.objects), ["1/a", "1/b/c", "2/z", "20/a"])
  },
)

test("a clear spares an item made and written to after it listed the bucket", async () => {
  let served = Served.make()
  served.env.objects->before("prefixes", async () => {
    served->Served.item(~id=2., 1024.)
    await served.env.objects->placed("2/a", Uint8Array.fromLength(5))
    served.sqlite->run("INSERT INTO objects (item, name, size) VALUES (2, 'a', 5)", [])
  })
  ignore(await served->Served.call("describe", `{"name": "a"}`))
  deepEqual((keys(served.env.objects), counted(served.sqlite)), (["2/a"], [(2., "a", 5.)]))
  // A row alone, its put not yet done, is spared as its key is.
  let served = Served.make()
  served.env.objects->before("prefixes", async () => {
    served->Served.item(~id=2., 1024.)
    served.sqlite->run("INSERT INTO objects (item, name, size) VALUES (2, 'a', 5)", [])
  })
  ignore(await served->Served.call("describe", `{"name": "a"}`))
  deepEqual(counted(served.sqlite), [(2., "a", 5.)])
})

test("what no item made now holds is cleared a batch of 1000 keys a request", async () => {
  let served = Served.make(~size=1024.)
  let names = Array.fromInitializer(~length=1500, at => `n${Int.toString(at)}`)
  for at in 0 to 1499 {
    let name = names->Array.getUnsafe(at)
    await served.env.objects->placed(`1/${name}`, Uint8Array.fromLength(1))
    served.sqlite->run(
      "INSERT INTO objects (item, name, size) VALUES (1, ?, 1)",
      [JSON.String(name)],
    )
  }
  // An item ended with no other made clears as an item replaced does.
  served.sqlite->run("DELETE FROM items", [])
  let describe = () => served->Served.call("describe", `{"name": "a"}`)
  ignore(await describe())
  deepEqual(
    (Array.length(keys(served.env.objects)), Array.length(counted(served.sqlite))),
    (500, 500),
  )
  served->replaced(2.)
  ignore(await served->write("a", 1))
  deepEqual((keys(served.env.objects), counted(served.sqlite)), (["2/a"], [(2., "a", 1.)]))
})

test("rows left of an item no longer made are cleared once its keys are gone", async () => {
  let served = Served.make()
  served->Served.item(~id=2., 1024.)
  served.sqlite->run("INSERT INTO objects (item, name, size) VALUES (1, 'a', 5)", [])
  ignore(await served->Served.call("describe", `{"name": "a"}`))
  deepEqual(counted(served.sqlite), [])
})

test("a denied call clears nothing", async () => {
  let served = Served.make()
  served->Served.item(~id=2., 1024.)
  await served.env.objects->placed("1/a", Uint8Array.fromLength(1))
  ignore(await served->Served.call(~authorization="", "describe", `{"name": "a"}`))
  deepEqual(keys(served.env.objects), ["1/a"])
})
