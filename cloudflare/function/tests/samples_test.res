/***
 * The deployments samples run against the function kind on the fake account of `fake.res` and a
 * store in memory, as driver(machine)'s `function/tests/samples.rs` runs them. A `send` reaches
 * a Worker running, which no test here has, so it is counted and passed over.
 */
open Node
module Contracts = Envelope.Contracts

let samples = [
  "../platform/tests/kinds/deployments/deploys.json",
  "../platform/tests/kinds/deployments/lifecycle.json",
]

/** Where each fixture's description is, by its name. */
let fixtures = "../platform/tests/fixtures"

/** The most an artifact may be here, `Function`'s 64 MiB, which a padded fixture goes past. */
let largest = 67_108_864

let member = (json, key) => json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key))
let textOf = (json, key) => json->member(key)->Option.flatMap(JSON.Decode.string)

/** The modules a fixture's description names, each export answering the body it was sent. */
let echo = Tar.bundled([
  Tar.file(
    "main.js",
    `export default { fetch: async (request) => new Response(await request.text()) };`,
  ),
])

/** A fixture as a step deploys it, its address, its hash, its form and what the address serves. */
type fixture = {address: string, hash: Uint8Array.t, form: string, served: option<Uint8Array.t>}

let rec fixtureOf = async name => {
  let described = fromRoot(`${fixtures}/${name}/fixture.json`)
  switch described->textOf("of") {
  | None =>
    let form = described->textOf("form")->Option.getOr("")
    {address: name, hash: await Web.sha256(echo), form, served: Some(echo)}
  | Some(of_) =>
    let base = await fixtureOf(of_)
    let bytes = base.served->Option.getOr(echo)
    switch (described->textOf("served"), described->member("padded")) {
    | (Some("hash_mismatched"), None) =>
      let hash = await Web.sha256(Tar.concat([Web.utf8("not "), bytes]))
      {...base, address: name, hash}
    | (Some("unfetchable"), None) => {...base, address: name, served: None}
    | (None, Some(padded)) =>
      let plus = padded->member("plus")->Option.flatMap(JSON.Decode.float)->Option.getOr(0.)
      let past = Uint8Array.fromLength(largest + Float.toInt(plus))
      past->TypedArray.setArrayFrom(
        Array.fromInitializer(~length=TypedArray.length(bytes), i =>
          bytes->TypedArray.get(i)->Option.getOr(0)
        ),
        0,
      )
      {...base, address: name, hash: await Web.sha256(past), served: Some(past)}
    | _ => throw(JsExn.anyToExnInternal(`${name}: a fixture of another this test does not build`))
    }
  }
}

/** What an operation answered, as a step's `expect` writes it. */
let expected = (answer: JSON.t) =>
  switch answer->textOf("status") {
  | Some("success") => JSON.Object(dict{"output": answer->member("data")->Option.getOr(JSON.Null)})
  | _ =>
    JSON.Object(
      dict{
        "failure": answer->member("failure")->Option.getOr(JSON.Null),
        "reason": answer->member("reason")->Option.getOr(JSON.Null),
      },
    )
  }

/** Whether a value is as a sample expects it, `$any` and `$capture` standing for any value. */
let rec matches = (expect: JSON.t, actual: JSON.t) =>
  switch (expect->JSON.Decode.object, expect->JSON.Decode.array) {
  | (Some(e), _) if e->Dict.get("$any") != None || e->Dict.get("$capture") != None => true
  | (Some(e), _) =>
    switch actual->JSON.Decode.object {
    | Some(a) =>
      Dict.keysToArray(e)->Array.length == Dict.keysToArray(a)->Array.length &&
        e
        ->Dict.toArray
        ->Array.every(((key, value)) =>
          a->Dict.get(key)->Option.mapOr(false, v => matches(value, v))
        )
    | None => false
    }
  | (None, Some(e)) =>
    switch actual->JSON.Decode.array {
    | Some(a) =>
      Array.length(e) == Array.length(a) &&
        e->Array.everyWithIndex((value, i) => matches(value, a->Array.getUnsafe(i)))
    | None => false
    }
  | (None, None) => expect == actual
  }

let answerJson = (answer, data) => Contracts.Answer.toJson(answer, data)

/** One case's steps, each call answered as it expects; the sends it passes over, counted. */
let ran = async (case: JSON.t) => {
  let steps = case->member("steps")->Option.flatMap(JSON.Decode.array)->Option.getOr([])
  let made = Dict.make()
  for at in 0 to Array.length(steps) - 1 {
    switch steps->Array.getUnsafe(at)->textOf("fixture") {
    | Some(name) if made->Dict.get(name) == None => made->Dict.set(name, await fixtureOf(name))
    | Some(_) | None => ()
    }
  }
  let served =
    made->Dict.valuesToArray->Array.filterMap(f => f.served->Option.map(b => (f.address, b)))
  let (through, _, _, _) = Fake.setUp(~addresses=Dict.fromArray(served))
  let description = case->textOf("description")->Option.getOr("")
  let sent = ref(0)
  for at in 0 to Array.length(steps) - 1 {
    let step = steps->Array.getUnsafe(at)
    switch (step->member("send"), step->textOf("call")) {
    | (Some(_), _) => sent := sent.contents + 1
    | (None, None) => ok(false, ~message=`${description}, step ${Int.toString(at)} is no call`)
    | (None, Some(operation)) =>
      let input = step->member("input")->Option.flatMap(JSON.Decode.object)->Option.getOr(dict{})
      step
      ->textOf("fixture")
      ->Option.flatMap(name => made->Dict.get(name))
      ->Option.forEach(f => {
        let hash = JSON.String(Envelope.Hex.encode(f.hash))
        input->Dict.set("version", hash)
        input->Dict.set("form", JSON.String(f.form))
        input->Dict.set(
          "artifact",
          JSON.Object(dict{"address": JSON.String(f.address), "hash": hash}),
        )
      })
      let envelope = JSON.Object(
        dict{
          "interface": JSON.String("deployments"),
          "operation": JSON.String(operation),
          "input": JSON.Object(input),
        },
      )
      let answer = switch Contracts.Interface.Deployments.fromJson(envelope) {
      | Error(_) => JSON.Null
      | Ok({call}) =>
        let described = Contracts.DeploymentDescribed.toJson
        switch call {
        | Deploy(i) => answerJson(await Function.deploy(through, i), described)
        | Stop(i) => answerJson(await Function.stop(through, i), described)
        | Resume(i) => answerJson(await Function.resume(through, i), described)
        | Describe(i) => answerJson(await Function.describe(through, i), described)
        | Delete(i) =>
          answerJson(await Function.delete(through, i), Contracts.DeploymentDeleted.toJson)
        }
      }
      let expect = step->member("expect")->Option.getOr(JSON.Null)
      let told = `${description}, step ${Int.toString(at)}: expected ${JSON.stringify(
          expect,
        )}, answered ${JSON.stringify(answer)}`
      ok(matches(expect, expected(answer)), ~message=told)
    }
  }
  sent.contents
}

test("the deployments samples of modules hold but what they send", async () => {
  let cases = ref(0)
  let sent = ref(0)
  for s in 0 to Array.length(samples) - 1 {
    let listed =
      fromRoot(samples->Array.getUnsafe(s))->member("cases")->Option.flatMap(JSON.Decode.array)
    let listed = listed->Option.getOr([])
    for c in 0 to Array.length(listed) - 1 {
      cases := cases.contents + 1
      sent := sent.contents + (await ran(listed->Array.getUnsafe(c)))
    }
  }
  deepEqual((cases.contents, sent.contents), (10, 4))
})
