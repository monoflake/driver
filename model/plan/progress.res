/**
 * Each written block's state by its package's name, as monoflake/platform's `model/plan/work.res`
 * holds its own. A block in work fails nothing, and one written but not named here is refused.
 */
let blocks: dict<Work.state> = dict{
  "driver-machine": Accepted,
  "driver-machine-container": Accepted,
  "driver-machine-function": Accepted,
  "driver-machine-management": Accepted,
  "driver-machine-object": Accepted,
}
