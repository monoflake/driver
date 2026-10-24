/*** A Worker's script and what is asked of its account for it, the types `Function` names. */

type refused = {reason: string, message: string}

type kind = Es | CommonJs | Wasm | Text | Data | Json

type module_ = {name: string, kind: kind, bytes: Uint8Array.t}

type bundle = {
  modules: array<module_>,
  compatibilityDate: string,
  compatibilityFlags: array<string>,
}

type bound = PlainText({name: string, text: string}) | SecretText({name: string, text: string})

type upload = {bundle: bundle, bindings: array<bound>, tag: string}

type running = {id: string, tag: option<string>}

type api = {
  upload: (string, upload) => promise<result<string, refused>>,
  deploy: (string, string) => promise<result<unit, refused>>,
  running: string => promise<result<option<running>, refused>>,
  delete: string => promise<result<unit, refused>>,
  address: string => promise<result<string, refused>>,
}
