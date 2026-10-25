/***
 * The install id read from the account, each D1's marker surveyed and an id drawn where none is
 * marked, RFC nrs5v's Ledger.
 */
open Install_world

/** An install id, 8 lowercase hex digits. */
let installIdForm = /^[0-9a-f]{8}$/

/** A D1 name in the driver's form, `driver-<8 hex>`, its own only where it holds its marker. */
let driverForm = /^driver-([0-9a-f]{8})$/

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

/** The install id a name in the driver's D1 form ends in, `driver-<8 hex>`. */
let suffixOf = name =>
  driverForm
  ->RegExp.exec(name)
  ->Option.flatMap(found => found->RegExp.Result.matches->Array.get(0)->Option.flatMap(id => id))

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
  /** Every D1's name, so a drawn id is drawn again while one ends in it. */
  names: array<string>,
  /** The install ids of the D1s in the driver's form holding the driver's marker. */
  marked: array<string>,
  /** The names in the driver's form holding tables but no marker, passed over. */
  foreign: array<string>,
  /** The names in the driver's form holding no table at all, passed over and said apart. */
  empty: array<string>,
}

/** What one D1 in the driver's form holds, read by its tables and then its marker. */
type held = Marked(string) | Foreign | Empty

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
      ->Result.map(mark => mark->Option.mapOr(Foreign, mark => Marked(mark)))
    | _ => Ok(Foreign)
    }
  )
}

/**
 * The account's D1 list, each name in the driver's form read for its marker, its install id equal
 * to the name's suffix, any read failing refused.
 */
let surveyed = (w, ~root) =>
  w.run(commanded(w, ~root, ~cwd=root, ["d1", "list", "--json"]))
  ->then(listedNames)
  ->then(names =>
    names
    ->Array.filterMap(name => suffixOf(name)->Option.map(id => (name, id)))
    ->Array.reduce(Ok({names, marked: [], foreign: [], empty: []}), (done, (name, id)) =>
      done->then(
        survey =>
          heldIn(w, ~root, name)->Result.map(
            held =>
              switch held {
              | Marked(mark) if mark == id => {...survey, marked: [...survey.marked, id]}
              | Marked(_) | Foreign => {...survey, foreign: [...survey.foreign, name]}
              | Empty => {...survey, empty: [...survey.empty, name]}
              },
          ),
      )
    )
  )

/** Each foreign D1 said, and each empty one as possibly an interrupted install, none written. */
let passedOver = (w, survey) => {
  survey.foreign->Array.forEach(name =>
    w.say(`${name} holds no driver's marker, so it is passed over and never written`)
  )
  survey.empty->Array.forEach(name =>
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

/** How many ids are drawn at most before install gives up. */
let draws = 8

/** An id drawn and drawn again while a D1's or a Worker's name ends in it. */
let drawn = (w, ~root, ~names) =>
  w.run(workersList(w, ~root))
  ->then(listedWorkers)
  ->then(workers => {
    let taken = id => [...names, ...workers]->Array.some(name => name->String.endsWith(`-${id}`))
    let rec draw = left =>
      switch w.draw() {
      | id if !(installIdForm->RegExp.test(id)) =>
        Error(`an install id drawn is not 8 lowercase hex digits, ${id}`)
      | id if taken(id) && left > 1 =>
        w.say(`the install id ${id} drawn ends a name the account holds, so another is drawn`)
        draw(left - 1)
      | id if taken(id) => Error(`no install id drawn was free in ${Int.toString(draws)} draws`)
      | id => Ok(id)
      }
    draw(draws)
  })

/** The rule, said where a dry run cannot say which install id. */
let rule = w => {
  w.say(`  it reuses the install id of the one driver-<8 hex> holding the driver's marker, draws a`)
  w.say(`  new one where none does, and refuses where more than one does`)
}

let more = marked => {
  let all = marked->Array.map(id => named(database, ~id))->Array.join(", ")
  Error(`the account holds more than one driver's D1, ${all}, so none is chosen`)
}

/** The install id read from the D1s' markers alone, drawn where none is marked, reused where one
 * is, and refused where more are, with whether it was drawn so the new D1 is marked. */
let recovered = (w, ~dry, ~root) =>
  if dry {
    // A dry run writes nothing, so it reads the list and the markers alone, given the account.
    let unknown = () => Ok(("<install id>", true))
    switch [account, installToken]->Array.filter(name => value(w.env, name) == None) {
    | [] =>
      switch surveyed(w, ~root) {
      | Ok(survey) =>
        passedOver(w, survey)
        switch survey.marked {
        | [] =>
          let none = "d1 list names no driver's D1 holding its marker"
          w.say(`${none}, so a new install id would be drawn`)
          w.say(`  by ${shown(workersList(w, ~root))}, again while a D1 or a Worker ends in it`)
          unknown()
        | [id] =>
          w.say(`d1 list names ${named(database, ~id)}, so the install id ${id} would be reused`)
          Ok((id, false))
        | marked => more(marked)
        }
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
      passedOver(w, survey)
      switch survey.marked {
      | [] =>
        drawn(w, ~root, ~names=survey.names)->Result.map(id => {
          w.say(
            `no driver's D1 holding its marker on the account, so the install id ${id} is drawn`,
          )
          (id, true)
        })
      | [id] =>
        w.say(`the install id ${id} is reused, the account holding ${named(database, ~id)}`)
        Ok((id, false))
      | marked => more(marked)
      }
    })
  }
