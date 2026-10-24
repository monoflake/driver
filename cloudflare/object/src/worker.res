/*** The Worker's module, its default export answering each request, as `wrangler.json` names it. */
type worker = {fetch: (Web.request, Object.env) => promise<Web.response>}

let default = {fetch: Object.fetch}
