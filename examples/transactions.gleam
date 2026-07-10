// Example: atomic batch transactions with the MongrelDB Gleam client.
//
// Run from the repo root:
//
//   gleam run -m transactions
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, stages three inserts in a single transaction, commits them
// atomically, verifies the count, then demonstrates idempotent retries by
// re-committing with the same idempotency key (the daemon returns the original
// result and applies no duplicate rows). Cleans up by dropping the table.

import gleam/int
import gleam/io
import gleam/option.{None}

import mongreldb

const url = "http://127.0.0.1:8453"

pub fn main() {
  let assert Ok(db) =
    mongreldb.connect(url, mongreldb.Options(token: "", username: "", password: ""))

  let assert Ok(True) = mongreldb.health(db)
  io.println("Connected to MongrelDB")

  // Unique table name + idempotency key per run so concurrent/repeated runs
  // never collide and retry logic isn't confused with a prior run's batch.
  let suffix = system_suffix()
  let table = "example_txn_" <> suffix
  let idempotency_key = "example-txn-" <> suffix
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

  // Stage three puts and commit them atomically. Either every op lands or none
  // do; a constraint violation rolls back the whole batch.
  let txn = mongreldb.begin(db)
  let assert Ok(txn) = mongreldb.txn_put(
    txn,
    table,
    [
      mongreldb.Cell(1, mongreldb.int_value(1)),
      mongreldb.Cell(2, mongreldb.string_value("Alice")),
      mongreldb.Cell(3, mongreldb.float_value(95.5)),
    ],
    False,
  )
  let assert Ok(txn) = mongreldb.txn_put(
    txn,
    table,
    [
      mongreldb.Cell(1, mongreldb.int_value(2)),
      mongreldb.Cell(2, mongreldb.string_value("Bob")),
      mongreldb.Cell(3, mongreldb.float_value(82.0)),
    ],
    False,
  )
  let assert Ok(txn) = mongreldb.txn_put(
    txn,
    table,
    [
      mongreldb.Cell(1, mongreldb.int_value(3)),
      mongreldb.Cell(2, mongreldb.string_value("Carol")),
      mongreldb.Cell(3, mongreldb.float_value(78.3)),
    ],
    False,
  )
  io.println("Staged " <> int.to_string(mongreldb.txn_count(txn)) <> " operations")

  let assert Ok(#(_, results)) = mongreldb.commit(txn, "")
  io.println(
    "Committed atomically: " <> int.to_string(list_length(results)) <> " operations applied",
  )

  let assert Ok(after_commit) = mongreldb.count(db, table)
  io.println("Verified row count after commit: " <> int.to_string(after_commit))

  // Idempotent retry: stage the same batch again with an idempotency key, then
  // commit a second time with the SAME key. The daemon replays the original
  // result and applies no extra rows.
  let retry = mongreldb.begin(db)
  let assert Ok(retry) = mongreldb.txn_put(
    retry,
    table,
    [
      mongreldb.Cell(1, mongreldb.int_value(4)),
      mongreldb.Cell(2, mongreldb.string_value("Dave")),
      mongreldb.Cell(3, mongreldb.float_value(60.0)),
    ],
    False,
  )
  let assert Ok(_) = mongreldb.commit(retry, idempotency_key)
  let assert Ok(after_first) = mongreldb.count(db, table)
  io.println("After first idempotent commit: " <> int.to_string(after_first) <> " rows")

  let retry2 = mongreldb.begin(db)
  let assert Ok(retry2) = mongreldb.txn_put(
    retry2,
    table,
    [
      mongreldb.Cell(1, mongreldb.int_value(4)),
      mongreldb.Cell(2, mongreldb.string_value("Dave")),
      mongreldb.Cell(3, mongreldb.float_value(60.0)),
    ],
    False,
  )
  let assert Ok(_) = mongreldb.commit(retry2, idempotency_key)
  let assert Ok(after_dup) = mongreldb.count(db, table)
  io.println(
    "After duplicate idempotent commit (same key): " <> int.to_string(after_dup) <> " rows (no double-apply)",
  )

  // Cleanup.
  _ = mongreldb.drop_table(db, table)
  io.println("Dropped table " <> table)
}

fn list_length(list: List(a)) -> Int {
  do_length(list, 0)
}

fn do_length(list: List(a), acc: Int) -> Int {
  case list {
    [] -> acc
    [_, ..rest] -> do_length(rest, acc + 1)
  }
}

@external(erlang, "mongreldb_util_ffi", "unique_suffix")
fn system_suffix() -> String
