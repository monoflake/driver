/**
 * What this repository's blocks provide beside the role each is named for, and the edges they add
 * where the design has none, RFC s42ex, as monoflake/platform's `Provided.block` has it.
 */
open Components

let blocks: dict<Provided.block> = dict{
  "driver(machine)": {
    // Its entry serves the machine's requests, and each deployment's workerd runs an app as a host.
    provides: ["host", "?entry"],
    extra: [
      e(
        "?roster",
        #start,
        hard,
        "binds its host to an organization's control once, by the binding's token, a place added to the roster, RFC rxmd9",
        ~contract=["bindings"],
      ),
      e(
        "?builder",
        #deploy,
        hard,
        "fetches each artifact over plain HTTP from the one origin it is given, RFC rxmd9",
      ),
    ],
  },
}
