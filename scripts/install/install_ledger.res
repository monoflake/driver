/***
 * The install id read from the account, each D1 named by 8 hex digits surveyed for its marker and
 * an id drawn where none is marked, and the names the driver records for its parts, RFC nrs5v.
 */
open Install_world

/** An install id, 8 lowercase hex digits. */
let installIdForm = /^[0-9a-f]{8}$/

/** What `d1 list --json` prints, an array, or an error where it is anything else. */
let listed = body =>
  switch parsed(body)->Option.flatMap(JSON.Decode.array) {
  | Some(all) => Ok(all)
  | None => Error("d1 list printed no JSON array, so the account's databases are not known")
  }

/** A database's id where `d1 list` holds one by its name. */
let listedDatabase = (body, name) =>
  listed(body)->Result.map(all =>
    all
    ->Array.find(db => db->text("name") == Some(name))
    ->Option.flatMap(db => db->text("uuid"))
  )

/** The names `d1 list` holds, and nothing more of any database. */
let listedNames = body =>
  listed(body)->Result.map(all => all->Array.filterMap(db => db->text("name")))

/** The install id a D1 named by 8 hex digits would be, its own name. */
let suffixOf = name => installIdForm->RegExp.test(name) ? Some(name) : None

/** The read-only query of a D1's tables, which says whether it holds the marker's table. */
let tablesQuery = "SELECT name FROM sqlite_master WHERE type = 'table'"

/** The read-only query of the driver's marker, the install id its table `install` holds. */
let markerQuery = "SELECT id FROM install WHERE one = 1"

/** The marker's table made and its one row written, the first statement a new D1 runs. */
let markerWrite = id =>
  [
    "CREATE TABLE install (one INTEGER PRIMARY KEY CHECK (one = 1), id TEXT NOT NULL);",
    `INSERT INTO install (one, id) VALUES (1, '${id}')`,
  ]->Array.join(" ")

/** The rows `d1 execute --json` printed for its one statement. */
let rowsOf = body =>
  switch parsed(body)->Option.flatMap(JSON.Decode.array) {
  | None => Error("d1 execute printed no JSON array")
  | Some(answers) =>
    switch answers->Array.get(0)->Option.flatMap(a => a->member("results")->JSON.Decode.array) {
    | Some(rows) => Ok(rows)
    | None => Error("d1 execute printed no results")
    }
  }

/** A table SQLite or Cloudflare keeps in every D1, never one a migration or install made. */
let internal = name => name->String.startsWith("_cf_") || name->String.startsWith("sqlite_")

/** The tables a D1 holds, its internal ones left out. */
let tablesOf = body =>
  rowsOf(body)->Result.map(rows =>
    rows->Array.filterMap(row => row->text("name"))->Array.filter(name => !internal(name))
  )

/** The install id `d1 execute --json` printed for the marker query, None where it holds none. */
let markOf = body =>
  rowsOf(body)->Result.map(rows => rows->Array.get(0)->Option.flatMap(row => row->text("id")))

/** What the account's D1 list and markers say, read alone before anything is written. */
type surveyed = {
  /** Every D1's name, so a drawn name is drawn again while a D1 holds it. */
  names: array<string>,
  /** The install ids of the D1s named by 8 hex digits holding the driver's marker. */
  marked: array<string>,
  /** The tables each marked D1 holds, so its records are read only where it holds them. */
  tables: dict<array<string>>,
  /** The names in the driver's form holding tables but no marker, passed over. */
  foreign: array<string>,
  /** The names in the driver's form holding no table at all, passed over and said apart. */
  empty: array<string>,
}

/** What one D1 in the driver's form holds, read by its tables and then its marker. */
type held = Marked(string, array<string>) | Foreign | Empty

/** One D1 in the driver's form read, its marker only where its tables hold `install`. */
let heldIn = (w, ~root, name) => {
  let known = result => result->Result.mapError(why => `the marker of ${name} is not known, ${why}`)
  let execute = ["d1", "execute", name, "--remote", "--command"]
  let read = query => w.run(commanded(w, ~root, ~cwd=root, [...execute, query, "--json"]))->known
  read(tablesQuery)
  ->then(body => known(tablesOf(body)))
  ->then(tables =>
    switch tables {
    | [] => Ok(Empty)
    | tables if tables->Array.includes("install") =>
      read(markerQuery)
      ->then(body => known(markOf(body)))
      ->Result.map(mark => mark->Option.mapOr(Foreign, mark => Marked(mark, tables)))
    | _ => Ok(Foreign)
    }
  )
}

/**
 * The account's D1 list, each named by 8 hex digits read for its marker, its install id equal to
 * its own name, any read failing refused.
 */
let surveyed = (w, ~root) =>
  w.run(commanded(w, ~root, ~cwd=root, ["d1", "list", "--json"]))
  ->then(listedNames)
  ->then(names =>
    names
    ->Array.filterMap(name => suffixOf(name)->Option.map(id => (name, id)))
    ->Array.reduce(Ok({names, marked: [], tables: dict{}, foreign: [], empty: []}), (
      done,
      (name, id),
    ) =>
      done->then(
        survey =>
          heldIn(w, ~root, name)->Result.map(
            held =>
              switch held {
              | Marked(mark, tables) if mark == id =>
                survey.tables->Dict.set(id, tables)
                {...survey, marked: [...survey.marked, id]}
              | Marked(_) | Foreign => {...survey, foreign: [...survey.foreign, name]}
              | Empty => {...survey, empty: [...survey.empty, name]}
              },
          ),
      )
    )
  )

/**
 * Each foreign D1 said, and each empty one as possibly an interrupted install, none written, a name
 * the driver's records hold passed over, since it is the driver's own.
 */
let passedOver = (w, ~foreign, ~empty, ~records: array<(string, string)>) => {
  let own = name => records->Array.some(((held, _)) => held == name)
  foreign
  ->Array.filter(name => !own(name))
  ->Array.forEach(name =>
    w.say(`${name} holds no driver's marker, so it is passed over and never written`)
  )
  empty
  ->Array.filter(name => !own(name))
  ->Array.forEach(name =>
    w.say(
      [
        `${name} holds no tables, possibly an interrupted install of this driver;`,
        " delete it by hand if it is yours",
      ]->Array.join(""),
    )
  )
}

/** The Workers the account holds, by Cloudflare's documented List Workers, read alone. */
let workersList = (w, ~root) => {
  program: "curl",
  // `-q` first, so curl reads no .curlrc.
  args: [
    "-q",
    "--silent",
    "--show-error",
    "--fail-with-body",
    "--header",
    "@-",
    `https://api.cloudflare.com/client/v4/accounts/${value(w.env, account)->Option.getOr(
        "",
      )}/workers/scripts`,
  ],
  cwd: root,
  // The token reaches curl on stdin alone, as a header, never in an argument.
  input: `Authorization: Bearer ${value(w.env, installToken)->Option.getOr("")}`,
  env: quiet(w.env),
}

/** Whether an answer says it holds one page of more, as no documented List Workers answer does. */
let paged = json => {
  let info = json->member("result_info")
  let number = name => info->member(name)->JSON.Decode.float
  switch (number("total_pages"), number("count"), number("total_count")) {
  | (Some(pages), _, _) if pages > 1. => true
  | (_, Some(count), Some(total)) if count < total => true
  | _ => info->text("cursor")->Option.mapOr(false, cursor => cursor != "")
  }
}

/**
 * The names List Workers answered, each script's id, its answer one page by the documentation,
 * developers.cloudflare.com/api/resources/workers/subresources/scripts/methods/list, read whole.
 */
let listedWorkers = body => {
  let unknown = why => Error(`the Workers list ${why}, so the account's Workers are not known`)
  switch parsed(body) {
  | Some(json) if json->member("success") != JSON.Boolean(true) => unknown("did not succeed")
  | Some(json) if paged(json) => unknown("came in pages and was not read whole")
  | Some(json) =>
    switch json->member("result")->JSON.Decode.array {
    | Some(all) => Ok(all->Array.filterMap(script => script->text("id")))
    | None => unknown("printed no result array")
    }
  | None => unknown("printed no result array")
  }
}

/** How many ids are drawn at most for one name before install gives up. */
let draws = 8

/**
 * `count` names drawn, each drawn again while a D1, a Worker, a name in `taken` or one drawn before
 * it is so named, the account's Workers listed once.
 */
let drawn = (w, ~workers, ~taken, ~count) =>
  if count == 0 {
    Ok([])
  } else {
    Ok(workers)->then(workers => {
      let rec draw = (left, ~held) =>
        switch w.draw() {
        | id if !(installIdForm->RegExp.test(id)) =>
          Error(`an install id drawn is not 8 lowercase hex digits, ${id}`)
        | id if held->Array.includes(id) && left > 1 =>
          w.say(
            `the name ${id} drawn is the account's or the driver's already, so another is drawn`,
          )
          draw(left - 1, ~held)
        | id if held->Array.includes(id) =>
          Error(`no name drawn was free in ${Int.toString(draws)} draws`)
        | id => Ok(id)
        }
      Array.make(~length=count, ())->Array.reduce(Ok([]), (done, ()) =>
        done->then(
          names =>
            draw(draws, ~held=[...taken, ...workers, ...names])->Result.map(id => [...names, id]),
        )
      )
    })
  }

/** The rule, said where a dry run cannot say which install id. */
let rule = w => {
  w.say(`  it reuses the install id of the one D1 named by 8 hex digits holding the driver's`)
  w.say(`  marker, draws a new one where none does, and refuses where more than one does`)
}

let more = marked => {
  let all = marked->Array.join(", ")
  Error(`the account holds more than one driver's D1, ${all}, so none is chosen`)
}

/** What recovery found, the state D1 marked where one is, every D1's name and its tables. */
type recovery = {
  /** The marked D1's name, its install id, none where a new one is to be drawn. */
  state: option<string>,
  names: array<string>,
  tables: array<string>,
  foreign: array<string>,
  empty: array<string>,
  /** Every Worker's name, read once, so a drawn name is drawn again while a Worker holds it. */
  workers: array<string>,
}

/** A name of the driver's old naming, `driver-<8 hex>`, which install only ever reports. */
let oldForm = /^driver-[0-9a-f]{8}$/

/**
 * Each D1 and Worker left over from the old naming said, never written, deleted or reused as the
 * state, so the author clears it by hand, RFC nrs5v's Ledger.
 */
let leftOver = (w, ~databases, ~workers) => {
  let said = (what, name) =>
    w.say(`the ${what} ${name} is left over from the old naming; install never writes, deletes or`)
  let after = () => w.say(`  reuses it, so clear it by hand in Cloudflare's dashboard`)
  databases
  ->Array.filter(name => oldForm->RegExp.test(name))
  ->Array.forEach(name => {
    said("D1", name)
    after()
  })
  workers
  ->Array.filter(name => oldForm->RegExp.test(name))
  ->Array.forEach(name => {
    said("Worker", name)
    after()
  })
}

/** The account's Workers, by List Workers read whole, each left over from the old naming said. */
let workersOf = (w, ~root, ~databases) =>
  w.run(workersList(w, ~root))
  ->then(listedWorkers)
  ->Result.map(workers => {
    leftOver(w, ~databases, ~workers)
    workers
  })

/**
 * The state D1 read from the D1s' markers alone, none where none is marked so one is drawn, the one
 * reused where one is, and refused where more are.
 */
let recovered = (w, ~dry, ~root) => {
  let found = (survey: surveyed): recovery => {
    state: None,
    names: survey.names,
    tables: [],
    foreign: survey.foreign,
    empty: survey.empty,
    workers: [],
  }
  let chosen = survey =>
    switch survey.marked {
    | [] => Ok(found(survey))
    | [id] =>
      Ok({
        ...found(survey),
        state: Some(id),
        tables: survey.tables->Dict.get(id)->Option.getOr([]),
      })
    | marked => more(marked)
    }
  if dry {
    // A dry run writes nothing, so it reads the list and the markers alone, given the account.
    let unknown = () => Ok({
      state: None,
      names: [],
      tables: [],
      foreign: [],
      empty: [],
      workers: [],
    })
    switch [account, installToken]->Array.filter(name => value(w.env, name) == None) {
    | [] =>
      switch surveyed(w, ~root) {
      | Ok(survey) =>
        chosen(survey)->Result.map(found => {
          switch found.state {
          | None =>
            let none = "d1 list names no driver's D1 holding its marker"
            w.say(`${none}, so a new install id would be drawn`)
            w.say(`  by ${shown(workersList(w, ~root))}, again while a D1 or a Worker is so named`)
          | Some(id) => w.say(`d1 list names ${id}, so the install id ${id} would be reused`)
          }
          switch workersOf(w, ~root, ~databases=found.names) {
          | Ok(workers) => {...found, workers}
          | Error(why) =>
            leftOver(w, ~databases=found.names, ~workers=[])
            w.say(`the Workers are not known, as ${why}, so none left over is said`)
            found
          }
        })
      | Error(why) =>
        w.say(`the install id is not known, as ${why};`)
        rule(w)
        unknown()
      }
    | unset =>
      w.say(`the install id is not known, as ${unset->Array.join(" and ")} unset;`)
      rule(w)
      unknown()
    }
  } else {
    surveyed(w, ~root)->then(survey => {
      chosen(survey)->then(found => {
        found.state->Option.forEach(
          id => w.say(`the install id ${id} is reused, the account holding the D1 ${id}`),
        )
        workersOf(w, ~root, ~databases=found.names)->Result.map(workers => {...found, workers})
      })
    })
  }
}

/** The read-only query of the names the driver records, each with its role. */
let recordsQuery = "SELECT name, role FROM owned ORDER BY name"

/** Each name a state D1 records and its role, none where it holds no table `owned` yet. */
let recordsOf = (w, ~root, ~state, ~tables) =>
  if tables->Array.includes("owned") {
    let read = ["d1", "execute", state, "--remote", "--command", recordsQuery, "--json"]
    w.run(commanded(w, ~root, ~cwd=root, read))
    ->then(rowsOf)
    ->Result.map(rows =>
      rows->Array.filterMap(row =>
        switch (row->text("name"), row->text("role")) {
        | (Some(name), Some(role)) => Some((name, role))
        | _ => None
        }
      )
    )
    ->Result.mapError(why => `the records of ${state} are not known, ${why}`)
  } else {
    Ok([])
  }

/** The records written into the state D1, one statement, each name drawn and its role. */
let recordsWrite = (records: array<(string, string)>) =>
  "INSERT INTO owned (name, role) VALUES " ++
  records->Array.map(((name, role)) => `('${name}', '${role}')`)->Array.join(", ")
