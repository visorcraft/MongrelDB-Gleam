// Example: basic CRUD operations with the MongrelDB Gleam client.
//
// Run from the repo root:
//
//   gleam run -m basic_crud
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, inserts three rows, counts them, queries all rows, "updates"
// one row by overwriting it at its primary key, deletes one row, then drops
// the table. Progress is printed at every step.

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}

import mongreldb

const url = "http://127.0.0.1:8453"

pub fn main() {
  let assert Ok(db) =
    mongreldb.connect(url, mongreldb.Options(token: "", username: "", password: ""))

  // Health check; bail out if the daemon is unreachable.
  let assert Ok(True) = mongreldb.health(db)
  io.println("Connected to MongrelDB")

  // Unique table name per run so concurrent/repeated runs never collide.
  let table = unique_name("example_crud")
  _ = mongreldb.drop_table(db, table)

  // Create the table. Schema: id (int64 PK), name (varchar), score (float64).
  let assert Ok(tid) =
    mongreldb.create_table(
      db,
      table,
      [
        mongreldb.Column(1, "id", "int64", True, False, None, None),
        mongreldb.Column(2, "name", "varchar", False, False, None, None),
        mongreldb.Column(3, "score", "float64", False, False, None, None),
      ],
    )
  io.println("Created table " <> table <> " (id " <> int.to_string(tid) <> ")")

  // Insert three rows. Cells pair column id -> value.
  let assert Ok(_) = mongreldb.put(
    db,
    table,
    [
      mongreldb.Cell(1, mongreldb.int_value(1)),
      mongreldb.Cell(2, mongreldb.string_value("Alice")),
      mongreldb.Cell(3, mongreldb.float_value(95.5)),
    ],
    "",
  )
  let assert Ok(_) = mongreldb.put(
    db,
    table,
    [
      mongreldb.Cell(1, mongreldb.int_value(2)),
      mongreldb.Cell(2, mongreldb.string_value("Bob")),
      mongreldb.Cell(3, mongreldb.float_value(82.0)),
    ],
    "",
  )
  let assert Ok(_) = mongreldb.put(
    db,
    table,
    [
      mongreldb.Cell(1, mongreldb.int_value(3)),
      mongreldb.Cell(2, mongreldb.string_value("Carol")),
      mongreldb.Cell(3, mongreldb.float_value(78.3)),
    ],
    "",
  )
  io.println("Inserted 3 rows")

  let assert Ok(total) = mongreldb.count(db, table)
  io.println("Total rows: " <> int.to_string(total))

  // Query all rows (no conditions).
  let q = db |> mongreldb.query(table)
  let assert Ok(rows) = mongreldb.execute(q)
  io.println("Query returned " <> int.to_string(list.length(rows)) <> " rows")

  // Update Alice's score by re-putting the same primary key with new values.
  let assert Ok(_) = mongreldb.put(
    db,
    table,
    [
      mongreldb.Cell(1, mongreldb.int_value(1)),
      mongreldb.Cell(2, mongreldb.string_value("Alice")),
      mongreldb.Cell(3, mongreldb.float_value(100.0)),
    ],
    "",
  )
  io.println("Updated Alice's score to 100.0")

  // Delete Carol (primary key 3).
  let assert Ok(_) = mongreldb.delete_by_pk(db, table, mongreldb.int_value(3))
  let assert Ok(after_delete) = mongreldb.count(db, table)
  io.println("Deleted Carol; remaining rows: " <> int.to_string(after_delete))

  // Cleanup: always drop the table on exit.
  _ = mongreldb.drop_table(db, table)
  io.println("Dropped table " <> table)
}

/// `unique_name` returns a per-run unique table name.
fn unique_name(prefix: String) -> String {
  prefix <> "_" <> system_suffix()
}

@external(erlang, "mongreldb_util_ffi", "unique_suffix")
fn system_suffix() -> String
