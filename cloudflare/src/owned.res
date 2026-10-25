/***
 * The names the driver holds on the account, each with its role, in its state D1's `owned`; a name
 * the records do not hold is never acted on, RFC nrs5v's bare ids.
 */
open Stores

/** What a name is to the driver, one of its own parts or a deployment's Worker. */
type role = [#state | #driver | #object | #bucket | #database | #user_database | #deployment]

let roleName = (role: role) =>
  switch role {
  | #state => "state"
  | #driver => "driver"
  | #object => "object"
  | #bucket => "bucket"
  | #database => "database"
  | #user_database => "user_database"
  | #deployment => "deployment"
  }

let roleOf = (text): role =>
  switch text {
  | "state" => #state
  | "driver" => #driver
  | "object" => #object
  | "bucket" => #bucket
  | "database" => #database
  | "user_database" => #user_database
  | "deployment" => #deployment
  | other => throw(Kept.Unkept(`a name held in no role the driver keeps, ${other}`))
  }

/** What a part is called where a message names it. */
let roleSaid = (role: role) =>
  switch role {
  | #state => "state D1"
  | #driver => "Worker driver"
  | #object => "Worker object"
  | #bucket => "bucket"
  | #database => "Worker database"
  | #user_database => "database kind's D1"
  | #deployment => "deployment's Worker"
  }

/** Each name held and its role. */
type records = array<(string, role)>

type row = {name: string, role: string}

let read = async (db: database): records => {
  let rows: rows<row> = await db
  ->prepare("SELECT name, role FROM owned ORDER BY name")
  ->bind([])
  ->all
  rows.results->Array.map(row => (row.name, roleOf(row.role)))
}

/** The role a name is held in, none where the records do not hold it. */
let roleIn = (records: records, name) =>
  records->Array.find(((held, _)) => held == name)->Option.map(((_, role)) => role)

/** The one name a part of the driver's own is held by. */
let named = (records: records, role: role) =>
  records->Array.find(((_, held)) => held == role)->Option.map(((name, _)) => name)

/** Every deployment's Worker the driver made. */
let deployments = (records: records) =>
  records->Array.filter(((_, role)) => role == #deployment)->Array.map(((name, _)) => name)

/** A deployment's Worker recorded as the driver's, before the first call that makes it. */
let claim = (db, name) =>
  db->batch([
    db->prepare("INSERT INTO owned (name, role) VALUES (?, 'deployment')")->bind([Text(name)]),
  ])

/** A deployment's Worker claimed and then found to be another's, given back untouched. */
let unclaim = (db, name) =>
  db->batch([
    db
    ->prepare("DELETE FROM owned WHERE name = ? AND role = 'deployment'")
    ->bind([Text(name)]),
  ])
