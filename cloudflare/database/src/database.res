/***
 * The Worker `database`, every call held to the binding's token before it is read, then answered on
 * the D1 database `database` for the one `database` item the list holds, RFC nrs5v.
 */
module Contracts = Envelope.Contracts
module Interface = Contracts.Interface.Database

type database = Stores.database

type env = {
  @as("DB") db: database,
  @as("DATABASE") database: database,
  @as("BINDING") binding: string,
  @as("API_TOKEN") apiToken: string,
  @as("ACCOUNT_ID") accountId: string,
  @as("DATABASE_ID") databaseId: string,
}

/** The most a call's body may be, the 100 MB a Worker's request takes on every plan. */
let largest = 100_000_000

/** The days of Time Travel kept, the paid plan's thirty, in milliseconds. */
let window =
  30. *. 24. *. 60. *. 60. *. 1000.

/** The second after the database was emptied that a rewind reaches, past a skew of clocks. */
let settled = 1000.

/** An answer of an operation, its error by a reason the operation declares and its message. */
let refused = (operation: Contracts.operation, reason, ~message=?) => Contracts.Answer.Error(
  Answer.error(~declared=operation.reasons, reason, ~message?),
)

let unheld = "the binding holds no database item"

/**
 * The database held for an item, emptied where it was held for another or for none by the one call
 * that took it, and what is recorded of it.
 */
let rec heldFor = async (env, item: Held.item) =>
  switch await Held.held(env.db) {
  | Some(held) if held.item == item.id => held
  | was =>
    let size = was->Option.mapOr(0., was => was.size)
    let held: Held.held = {item: item.id, since: Date.now(), size}
    if await Held.handed(env.db, ~was=was->Option.map(was => was.item), held) {
      let size = await Cleared.clear(env.database)
      await Held.sized(env.db, ~item=item.id, size)
      {...held, size}
    } else {
      await heldFor(env, item)
    }
  }

/** A statement's rows, its columns named as D1 keys each, in the order the first row holds them. */
let resultOf = (sql, ran: Stores.result): result<Contracts.DatabaseResult.t, Values.unread> => {
  let rows = ran.results->Nullable.toOption->Option.getOr([])
  let columns = rows->Array.get(0)->Option.mapOr([], Dict.keysToArray)
  let read = rows->Array.reduce(Ok([]), (done, row) =>
    done->Result.flatMap(rows =>
      columns
      ->Array.reduce(
        Ok([]),
        (cells, column) =>
          cells->Result.flatMap(
            cells =>
              switch row->Dict.get(column) {
              | Some(cell) => Values.read(cell)->Result.map(value => [...cells, value])
              | None => Ok([...cells, Contracts.DatabaseValue.Null])
              },
          ),
      )
      ->Result.map(cells => [...rows, cells])
    )
  )
  let changed = Statements.counts(sql) && ran.meta.changedDb ? ran.meta.changes : 0.
  read->Result.map((rows): Contracts.DatabaseResult.t => {columns, rows, changed})
}

let executed = async (env, item: option<Held.item>, input: Contracts.DatabaseExecute.t) => {
  let operation = Interface.execute
  let sqls = input.statements->Array.map(s => s.sql)
  switch item {
  | _ if sqls->Array.some(Statements.past) =>
    let bound = Int.toString(Statements.bound)
    refused(operation, "beyond_limit", ~message=`a statement is at most ${bound} bytes`)
  | None => refused(operation, "storage_full", ~message=unheld)
  | Some(item) =>
    let held = await heldFor(env, item)
    let writes = !(sqls->Array.every(Statements.reads))
    let full = writes ? Room.refusal(input.statements, ~held=held.size, ~size=item.size) : None
    switch full {
    | Some(message) => refused(operation, "storage_full", ~message)
    | None if input.statements == [] =>
      Contracts.Answer.Success(({results: []}: Contracts.DatabaseExecuted.t))
    | None =>
      let statements = input.statements->Array.map(s =>
        env.database
        ->Stores.prepare(s.sql)
        ->Stores.bind(s.parameters->Option.getOr([])->Array.map(Values.bound))
      )
      switch await env.database->Stores.batch(statements) {
      | ran =>
        // The batch committed, so a size not recorded is read again after the next batch.
        switch ran->Array.at(-1) {
        | Some(last) =>
          try await Held.sized(env.db, ~item=item.id, last.meta.sizeAfter) catch {
          | JsExn(_) => ()
          }
        | None => ()
        }
        let results =
          ran->Array.reduceWithIndex(Ok([]), (done, ran, at) =>
            done->Result.flatMap(results =>
              resultOf(sqls->Array.getUnsafe(at), ran)->Result.map(result => [...results, result])
            )
          )
        switch results {
        | Ok(results) =>
          Contracts.Answer.Success(({results: results}: Contracts.DatabaseExecuted.t))
        | Error(Beyond) =>
          let message = "an integer read is past what a JavaScript number carries whole"
          refused(operation, "beyond_range", ~message)
        | Error(Unknown) => refused(operation, "fault", ~message="a value read is of no known type")
        }
      | exception JsExn(e) =>
        let message = e->JsExn.message->Option.getOr("D1 failed")
        refused(operation, Failed.reasonOf(message), ~message)
      }
    }
  }
}

let rewound = async (env, item: option<Held.item>, input: Contracts.DatabaseRewind.t) => {
  let operation = Interface.rewind
  switch item {
  | None => refused(operation, "beyond_window", ~message=unheld)
  | Some(item) =>
    let held = await heldFor(env, item)
    let now = Date.now()
    if input.to < held.since +. settled {
      let message = "the moment is not a second past when the database was emptied for the item"
      refused(operation, "beyond_window", ~message)
    } else if input.to < now -. window || input.to > now {
      refused(operation, "beyond_window", ~message="a rewind is to a moment of the last 30 days")
    } else {
      // The moment before the restore, which a rewind to undoes it.
      let before = now
      switch await Restored.restore(
        ~accountId=env.accountId,
        ~databaseId=env.databaseId,
        ~token=env.apiToken,
        ~to=input.to,
      ) {
      | Ok() =>
        // The size the restore left, read again where it can be and else after the next batch.
        switch await env.database->Stores.prepare("SELECT 1")->Stores.bind([])->Stores.run {
        | ran => await Held.sized(env.db, ~item=item.id, ran.meta.sizeAfter)
        | exception JsExn(_) => ()
        }
        Contracts.Answer.Success(({before: before}: Contracts.DatabaseRewound.t))
      | Error(message) => refused(operation, "fault", ~message)
      }
    }
  }
}

let operationOf = (call: Interface.call) =>
  switch call {
  | Execute(_) => "execute"
  | Rewind(_) => "rewind"
  }

/** A call on the database, against the one `database` item the list holds. */
let answered = async (env, item, call: Interface.call, form) =>
  switch call {
  | Execute(input) =>
    (await executed(env, item, input))->Answer.written(
      form,
      ~toJson=Contracts.DatabaseExecuted.toJson,
      ~toCbor=Contracts.DatabaseExecuted.toCbor,
    )
  | Rewind(input) =>
    (await rewound(env, item, input))->Answer.written(
      form,
      ~toJson=Contracts.DatabaseRewound.toJson,
      ~toCbor=Contracts.DatabaseRewound.toCbor,
    )
  }

/** A call of a caller held to a token, as its path and its body say it. */
let called = async (request, env, forms: Answer.forms, parts, ~holding) => {
  let early = error => Answer.refused(error, forms.answer)
  switch (parts, request->Web.method_, forms.body) {
  | (["", "database", operation], "POST", Some(form)) =>
    switch await request->Web.bytesOf(~largest) {
    | None => early(Answer.malformed(`a call's body is at most ${Int.toString(largest)} bytes`))
    | Some(bytes) =>
      switch Answer.call(form, bytes, ~fromJson=Interface.fromJson, ~fromCbor=Interface.fromCbor) {
      | Ok(envelope) if operationOf(envelope.call) == operation =>
        await answered(env, holding, envelope.call, forms.answer)
      | Ok(envelope) =>
        let named = operationOf(envelope.call)
        early(Answer.malformed(`the path names ${operation} and the call ${named}`))
      | Error(error) => early(error)
      }
    }
  | (["", "database", _], "POST", None) =>
    early(Answer.malformed("a call's body is application/json or application/cbor"))
  | (["", other, _], "POST", _) => early(Answer.malformed(`no interface ${other}, one of database`))
  | _ => early(Answer.malformed("a call is POST /database/{operation}"))
  }
}

let serve = async (request, env, forms: Answer.forms) => {
  let header = name => request->Web.requestHeaders->Web.header(name)->Nullable.toOption
  let early = error => Answer.refused(error, forms.answer)
  // An unset or empty BINDING holds no token, so every caller is denied.
  let given =
    Secrets.read(env.binding)
    ->Nullable.toOption
    ->Option.map(binding => binding->String.trim->String.toLowerCase)
    ->Option.filter(binding => binding != "")
  // A caller not yet held to a token is told nothing of why its token could not be read.
  let held = switch Bearer.hashOf(header("authorization")) {
  | Some(hash) =>
    switch await Held.holds(env.db, ~given, hash) {
    | held => Ok(held)
    | exception Held.Unkept(_) => Error()
    | exception JsExn(_) => Error()
    }
  | None => Ok(false)
  }
  let parts = Web.parts(request->Web.url)->Web.pathname->String.split("/")
  switch held {
  | Error() => early(Answer.error("fault", ~message="the call's token was not checked"))
  | Ok(false) => early(Answer.error("denied"))
  | Ok(true) =>
    let holding = await Held.item(env.db)
    await called(request, env, forms, parts, ~holding)
  }
}

let fetch = async (request, env) => {
  let header = name => request->Web.requestHeaders->Web.header(name)->Nullable.toOption
  let forms = Answer.formsOf(~contentType=header("content-type"), ~accept=header("accept"))
  let fault = message => Answer.refused(Answer.error("fault", ~message), forms.answer)
  switch await serve(request, env, forms) {
  | response => response
  | exception Held.Unkept(message) => fault(message)
  | exception JsExn(e) => fault(e->JsExn.message->Option.getOr("the Worker failed while answering"))
  }
}
