// Example: query builder conditions with the MongrelDB Gleam client.
//
// Run from the repo root:
//
//   gleam run -m query_builder
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, inserts five rows with varying scores, then uses the native
// query builder to fetch rows by a range condition and by an exact primary-key
// match. Cleans up by dropping the table.

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}

import mongreldb

const url = "http://127.0.0.1:8453"

pub fn main() {
  let assert Ok(db) =
    mongreldb.connect(url, mongreldb.Options(token: "", username: "", password: ""))

  let assert Ok(True) = mongreldb.health(db)
  io.println("Connected to MongrelDB")

  // Unique table name per run so concurrent/repeated runs never collide.
  let table = unique_name("example_query")
  _ = mongreldb.drop_table(db, table)

  let assert Ok(_) =
    mongreldb.create_table(
      db,
      table,
      [
        mongreldb.Column(1, "id", "int64", True, False, None, None),
        mongreldb.Column(2, "name", "varchar", False, False, None, None),
        mongreldb.Column(3, "score", "float64", False, False, None, None),
      ],
    )
  io.println("Created table " <> table)

  // Five rows with varying scores.
  let assert Ok(_) = mongreldb.put(
    db,
    table,
    [
      mongreldb.Cell(1, mongreldb.int_value(1)),
      mongreldb.Cell(2, mongreldb.string_value("Alice")),
      mongreldb.Cell(3, mongreldb.float_value(40.0)),
    ],
    "",
  )
  let assert Ok(_) = mongreldb.put(
    db,
    table,
    [
      mongreldb.Cell(1, mongreldb.int_value(2)),
      mongreldb.Cell(2, mongreldb.string_value("Bob")),
      mongreldb.Cell(3, mongreldb.float_value(65.0)),
    ],
    "",
  )
  let assert Ok(_) = mongreldb.put(
    db,
    table,
    [
      mongreldb.Cell(1, mongreldb.int_value(3)),
      mongreldb.Cell(2, mongreldb.string_value("Carol")),
      mongreldb.Cell(3, mongreldb.float_value(82.0)),
    ],
    "",
  )
  let assert Ok(_) = mongreldb.put(
    db,
    table,
    [
      mongreldb.Cell(1, mongreldb.int_value(4)),
      mongreldb.Cell(2, mongreldb.string_value("Dave")),
      mongreldb.Cell(3, mongreldb.float_value(91.0)),
    ],
    "",
  )
  let assert Ok(_) = mongreldb.put(
    db,
    table,
    [
      mongreldb.Cell(1, mongreldb.int_value(5)),
      mongreldb.Cell(2, mongreldb.string_value("Eve")),
      mongreldb.Cell(3, mongreldb.float_value(12.5)),
    ],
    "",
  )
  io.println("Inserted 5 rows")

  // Range condition: scores in [60.0, 90.0]. The "column" alias maps to the
  // server's column_id; pass the numeric column id (3), not the name.
  let range_q =
    db
    |> mongreldb.query(table)
    |> mongreldb.where_("range_f64", [
      #("column", mongreldb.int_value(3)),
      #("min", mongreldb.float_value(60.0)),
      #("max", mongreldb.float_value(90.0)),
      #("min_inclusive", mongreldb.bool_value(True)),
      #("max_inclusive", mongreldb.bool_value(True)),
    ])
  let assert Ok(range_rows) = mongreldb.execute(range_q)
  io.println(
    "Range query (score in [60,90]) returned " <> int.to_string(
      list.length(range_rows),
    ) <> " rows",
  )

  // Primary-key condition: fetch the single row with id == 4.
  let pk_q =
    db
    |> mongreldb.query(table)
    |> mongreldb.where_("pk", [#("value", mongreldb.int_value(4))])
  let assert Ok(pk_rows) = mongreldb.execute(pk_q)
  io.println(
    "PK query (id == 4) returned " <> int.to_string(list.length(pk_rows)) <> " rows",
  )

  // Cleanup.
  _ = mongreldb.drop_table(db, table)
  io.println("Dropped table " <> table)
}

/// `unique_name` returns a per-run unique table name.
fn unique_name(prefix: String) -> String {
  prefix <> "_" <> system_suffix()
}

@external(erlang, "mongreldb_util_ffi", "unique_suffix")
fn system_suffix() -> String
