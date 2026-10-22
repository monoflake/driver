/**
 * Each written block's state by its package's name, as monoflake/platform's `model/plan/work.res`
 * holds its own. A block in work fails nothing, and one written but not named here is refused.
 */
let blocks: dict<Work.state> = dict{
  "driver-machine": InWork,
  "driver-machine-container": Accepted,
  "driver-machine-management": Accepted,
}
