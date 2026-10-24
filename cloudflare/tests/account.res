/***
 * A fake of one account's Workers behind Cloudflare's API, answering the calls the function kind
 * makes from the examples of `documented.res`, each answer's result filled with what it keeps.
 */
open Node

let api = "https://api.cloudflare.com/client/v4/accounts/023e105f4ecef8ad9ca31a8372d0c353"

/** A Worker as the account keeps it, each version's tag by its id and the one deployed. */
type script = {tags: Map.t<string, option<string>>, deployed: ref<option<string>>}

let member = (json, key) => json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key))

/** A documented answer, its result's fields set as the account keeps them. */
let answered = (documented, fields: array<(string, JSON.t)>) => {
  let json = JSON.parseOrThrow(documented)
  let result = json->member("result")->Option.flatMap(JSON.Decode.object)->Option.getOr(dict{})
  fields->Array.forEach(((key, value)) => result->Dict.set(key, value))
  answerText(JSON.stringify(json), {status: 200})
}

let absent = () => answerText(Documented.notFound, {status: 404})

/** The account, each Worker by its name, and the artifacts served by their addresses. */
let make = (~artifacts: dict<Uint8Array.t>) => {
  let scripts: Map.t<string, script> = Map.make()
  let numbered = ref(0)
  let tagOf = body =>
    body
    ->Option.flatMap(b => b->formField("metadata")->Nullable.toOption)
    ->Option.map(text => JSON.parseOrThrow(text))
    ->Option.flatMap(m => m->member("annotations"))
    ->Option.flatMap(a => a->member("workers/tag"))
    ->Option.flatMap(JSON.Decode.string)
  async (url, init: fetchInit) =>
    switch artifacts->Dict.get(url) {
    | Some(bytes) => answerBytes(bytes, {status: 200})
    | None =>
      let path = url->String.replace(api, "")->String.split("/")
      switch (init.method, path) {
      | ("GET", ["", "workers", "subdomain"]) => answerText(Documented.subdomainGot, {status: 200})
      | ("PUT", ["", "workers", "scripts", name]) =>
        scripts->Map.set(name, {tags: Map.make(), deployed: ref(None)})
        answerText(Documented.scriptUploaded, {status: 200})
      | ("POST", ["", "workers", "scripts", name, "subdomain"]) =>
        scripts->Map.has(name) ? answerText(Documented.subdomainEnabled, {status: 200}) : absent()
      | ("POST", ["", "workers", "scripts", name, "versions"]) =>
        switch scripts->Map.get(name) {
        | Some(script) =>
          numbered := numbered.contents + 1
          let id = `v${Int.toString(numbered.contents)}`
          script.tags->Map.set(id, tagOf(init.body))
          answered(Documented.versionUploaded, [("id", JSON.String(id))])
        | None => absent()
        }
      | ("POST", ["", "workers", "scripts", name, "deployments"]) =>
        switch scripts->Map.get(name) {
        | Some(script) =>
          let id =
            init.body
            ->Option.map(b => JSON.parseOrThrow(sentText(b)))
            ->Option.flatMap(b => b->member("versions"))
            ->Option.flatMap(JSON.Decode.array)
            ->Option.flatMap(v => v->Array.get(0))
            ->Option.flatMap(v => v->member("version_id"))
            ->Option.flatMap(JSON.Decode.string)
          script.deployed := id
          answerText(Documented.deploymentCreated, {status: 200})
        | None => absent()
        }
      | ("GET", ["", "workers", "scripts", name, "deployments"]) =>
        switch scripts->Map.get(name) {
        | Some(script) =>
          let listed = script.deployed.contents->Option.mapOr([], id => [
            JSON.Object(
              dict{
                "id": JSON.String("182bd5e5-6e1a-4fe4-a799-aa6d9a6ab26e"),
                "strategy": JSON.String("percentage"),
                "versions": JSON.Array([
                  JSON.Object(dict{"percentage": JSON.Number(100.), "version_id": JSON.String(id)}),
                ]),
              },
            ),
          ])
          answered(Documented.deploymentsListed, [("deployments", JSON.Array(listed))])
        | None => absent()
        }
      | ("GET", ["", "workers", "workers", name, "versions", id]) =>
        switch scripts->Map.get(name)->Option.flatMap(s => s.tags->Map.get(id)) {
        | Some(tag) =>
          let annotations = tag->Option.mapOr(dict{}, t => dict{"workers/tag": JSON.String(t)})
          answered(
            Documented.versionGot,
            [("id", JSON.String(id)), ("annotations", JSON.Object(annotations))],
          )
        | None => absent()
        }
      | ("DELETE", ["", "workers", "scripts", name]) =>
        scripts->Map.delete(name) ? answerText(Documented.scriptDeleted, {status: 200}) : absent()
      | _ => answerText(`{"success": false, "errors": [], "result": null}`, {status: 400})
      }
    }
}
