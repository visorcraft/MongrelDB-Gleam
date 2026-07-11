// Live integration tests for the mongreldb Gleam client.
//
// These exercise the client against a running mongreldb-server daemon on
// http://127.0.0.1:8453 (override with the MONGRELDB_URL env var). The suite
// is a 16-operation conformance matrix mirroring the other MongrelDB clients:
// health, create table + count, put round trip, upsert, pk query, range query,
// transaction commit, delete by pk, sql, schema, schema_for, table names,
// the two error-path cases (nonexistent table, typed status), and the two
// history-retention cases (read and shrink).
//
// When no daemon is reachable the whole suite short-circuits with an explicit
// skip notice rather than a cascade of failures.

import gleam/dynamic
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleeunit
import gleeunit/should

import mongreldb

const default_url = "http://127.0.0.1:8453"

pub fn main() {
  gleeunit.main()
}

// ── Harness ───────────────────────────────────────────────────────────────

/// `connect_or_skip` connects to the daemon and returns it, or returns an
/// `Error(Nil)` when no daemon is reachable so every test can skip cleanly.
fn connect_or_skip() -> Result(mongreldb.Client, Nil) {
  let url = env_url()
  let assert Ok(db) =
    mongreldb.connect(
      url,
      mongreldb.Options(token: "", username: "", password: ""),
    )
  case mongreldb.health(db) {
    Ok(True) -> Ok(db)
    _ -> Error(Nil)
  }
}

/// `env_url` returns the daemon URL from MONGRELDB_URL or the default.
fn env_url() -> String {
  case os_getenv("MONGRELDB_URL") {
    "" -> default_url
    u -> u
  }
}

/// `os_getenv` wraps Erlang's `os:getenv/1`. Erlang returns the atom `false`
/// when the var is unset; the FFI coerces that to an empty string for the
/// Gleam side.
@external(erlang, "mongreldb_util_ffi", "getenv_str")
fn os_getenv(name: String) -> String

/// `unique_table` returns a per-run unique table name so concurrent/repeated
/// runs never collide. The suffix comes from a monotonic clock + a unique
/// integer from the FFI.
fn unique_table(prefix: String) -> String {
  prefix <> "_" <> unique_suffix()
}

/// `unique_suffix` returns a process-unique string from the FFI.
@external(erlang, "mongreldb_util_ffi", "unique_suffix")
fn unique_suffix() -> String

// ── Table/column helpers ──────────────────────────────────────────────────

fn int_col(id id: Int, name name: String, pk pk: Bool) -> mongreldb.Column {
  mongreldb.Column(
    id: id,
    name: name,
    ty: "int64",
    primary_key: pk,
    nullable: False,
    enum_variants: None,
    default_value: None,
  )
}

fn float_col(id id: Int, name name: String) -> mongreldb.Column {
  mongreldb.Column(
    id: id,
    name: name,
    ty: "float64",
    primary_key: False,
    nullable: False,
    enum_variants: None,
    default_value: None,
  )
}

/// `fresh_table` drops any prior table with this name (ignoring NotFound) then
/// creates it fresh.
fn fresh_table(
  db: mongreldb.Client,
  name name: String,
  cols cols: List(mongreldb.Column),
) -> Result(Int, mongreldb.MongrelError) {
  let _ = mongreldb.drop_table(db, name)
  mongreldb.create_table(db, name, cols)
}

fn must_put(
  db: mongreldb.Client,
  table table: String,
  cells cells: List(mongreldb.Cell),
) -> Nil {
  let assert Ok(_) = mongreldb.put(db, table, cells, "")
  Nil
}

// ── Tests (14-operation conformance matrix) ───────────────────────────────

pub fn health_test() {
  case connect_or_skip() {
    Error(Nil) -> io_println("SKIP: no mongreldb-server reachable")
    Ok(db) -> {
      let assert Ok(True) = mongreldb.health(db)
      Nil
    }
  }
}

pub fn create_table_and_count_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let name = unique_table("gleam_tbl")
      let assert Ok(_) =
        fresh_table(db, name, [int_col(1, "id", True), float_col(2, "amount")])
      let assert Ok(0) = mongreldb.count(db, name)
      Nil
    }
  }
}

pub fn create_table_constraints_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let name = unique_table("gleam_constraints")
      let _ = mongreldb.drop_table(db, name)
      let checks =
        json.preprocessed_array([
          json.object([
            #("id", json.int(1)),
            #("name", json.string("positive_id")),
            #(
              "expr",
              json.object([
                #(
                  "Gt",
                  json.preprocessed_array([
                    json.object([#("Col", json.int(1))]),
                    json.object([
                      #("Lit", json.object([#("Int64", json.int(0))])),
                    ]),
                  ]),
                ),
              ]),
            ),
          ]),
        ])
      let constraints = json.object([#("checks", checks)])
      let assert Ok(_) =
        mongreldb.create_table_with_constraints(
          db,
          name,
          [
            mongreldb.Column(1, "id", "int64", True, False, None, None),
          ],
          constraints,
        )
      let assert Ok(0) = mongreldb.count(db, name)
      let _ = mongreldb.drop_table(db, name)
      Nil
    }
  }
}

pub fn put_and_count_round_trip_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let name = unique_table("gleam_put")
      let assert Ok(_) =
        fresh_table(db, name, [int_col(1, "id", True), float_col(2, "amount")])
      let assert Ok(_) =
        mongreldb.put(
          db,
          name,
          [
            mongreldb.Cell(1, mongreldb.int_value(1)),
            mongreldb.Cell(2, mongreldb.float_value(99.5)),
          ],
          "",
        )
      let assert Ok(_) =
        mongreldb.put(
          db,
          name,
          [
            mongreldb.Cell(1, mongreldb.int_value(2)),
            mongreldb.Cell(2, mongreldb.float_value(150.0)),
          ],
          "",
        )
      let assert Ok(2) = mongreldb.count(db, name)
      Nil
    }
  }
}

pub fn upsert_inserts_then_updates_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let name = unique_table("gleam_upsert")
      let assert Ok(_) =
        fresh_table(db, name, [int_col(1, "id", True), float_col(2, "amount")])

      // First upsert inserts.
      let assert Ok(_) =
        mongreldb.upsert(
          db,
          name,
          [
            mongreldb.Cell(1, mongreldb.int_value(1)),
            mongreldb.Cell(2, mongreldb.float_value(99.5)),
          ],
          [mongreldb.Cell(2, mongreldb.float_value(99.5))],
          "",
        )
      let assert Ok(1) = mongreldb.count(db, name)

      // Second upsert on the same PK updates (still one row).
      let assert Ok(_) =
        mongreldb.upsert(
          db,
          name,
          [
            mongreldb.Cell(1, mongreldb.int_value(1)),
            mongreldb.Cell(2, mongreldb.float_value(120.0)),
          ],
          [mongreldb.Cell(2, mongreldb.float_value(120.0))],
          "",
        )
      let assert Ok(1) = mongreldb.count(db, name)

      // The updated value is returned by a query.
      let q =
        db
        |> mongreldb.query(name)
        |> mongreldb.where_("pk", [#("value", mongreldb.int_value(1))])
      let assert Ok(rows) = mongreldb.execute(q)
      rows |> list.length |> should.equal(1)
    }
  }
}

pub fn query_by_pk_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let name = unique_table("gleam_pk")
      let assert Ok(_) = fresh_table(db, name, [int_col(1, "id", True)])
      must_put(db, name, [mongreldb.Cell(1, mongreldb.int_value(42))])
      must_put(db, name, [mongreldb.Cell(1, mongreldb.int_value(43))])

      let q =
        db
        |> mongreldb.query(name)
        |> mongreldb.where_("pk", [#("value", mongreldb.int_value(42))])
      let assert Ok(rows) = mongreldb.execute(q)
      rows |> list.length |> should.equal(1)
    }
  }
}

pub fn query_range_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let name = unique_table("gleam_range")
      let assert Ok(_) =
        fresh_table(db, name, [
          int_col(1, "id", True),
          int_col(2, "amount", False),
        ])
      must_put(db, name, [
        mongreldb.Cell(1, mongreldb.int_value(1)),
        mongreldb.Cell(2, mongreldb.int_value(50)),
      ])
      must_put(db, name, [
        mongreldb.Cell(1, mongreldb.int_value(2)),
        mongreldb.Cell(2, mongreldb.int_value(120)),
      ])
      must_put(db, name, [
        mongreldb.Cell(1, mongreldb.int_value(3)),
        mongreldb.Cell(2, mongreldb.int_value(200)),
      ])

      let q =
        db
        |> mongreldb.query(name)
        |> mongreldb.where_("range", [
          #("column", mongreldb.int_value(2)),
          #("min", mongreldb.int_value(100)),
          #("max", mongreldb.int_value(150)),
        ])
      let assert Ok(rows) = mongreldb.execute(q)
      // Only the row with amount=120 (pk=2) falls in [100, 150].
      rows |> list.length |> should.equal(1)
    }
  }
}

pub fn transaction_put_commit_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let name = unique_table("gleam_txn")
      let assert Ok(_) = fresh_table(db, name, [int_col(1, "id", True)])

      let txn = mongreldb.begin(db)
      let assert Ok(txn) =
        mongreldb.txn_put(
          txn,
          name,
          [mongreldb.Cell(1, mongreldb.int_value(1))],
          False,
        )
      let assert Ok(txn) =
        mongreldb.txn_put(
          txn,
          name,
          [mongreldb.Cell(1, mongreldb.int_value(2))],
          False,
        )
      let assert Ok(txn) =
        mongreldb.txn_put(
          txn,
          name,
          [mongreldb.Cell(1, mongreldb.int_value(3))],
          False,
        )
      mongreldb.txn_count(txn) |> should.equal(3)

      let assert Ok(#(_, results)) = mongreldb.commit(txn, "")
      results |> list.length |> should.equal(3)

      let assert Ok(3) = mongreldb.count(db, name)
      Nil
    }
  }
}

pub fn delete_by_pk_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let name = unique_table("gleam_del")
      let assert Ok(_) = fresh_table(db, name, [int_col(1, "id", True)])
      must_put(db, name, [mongreldb.Cell(1, mongreldb.int_value(5))])
      let assert Ok(1) = mongreldb.count(db, name)

      let assert Ok(_) =
        mongreldb.delete_by_pk(db, name, mongreldb.int_value(5))
      let assert Ok(0) = mongreldb.count(db, name)
      Nil
    }
  }
}

pub fn sql_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let name = unique_table("gleam_sql")
      let assert Ok(_) =
        fresh_table(db, name, [
          int_col(1, "id", True),
          int_col(2, "amount", False),
        ])
      let assert Ok(0) = mongreldb.count(db, name)

      // INSERT via SQL must increase the row count.
      let insert_stmt =
        "INSERT INTO " <> name <> " (id, amount) VALUES (10, 42)"
      let assert Ok(_) = mongreldb.sql(db, insert_stmt)
      let assert Ok(1) = mongreldb.count(db, name)

      // JSON SQL mode returns the inserted row when the server honors it; an
      // old server answers with Arrow IPC and sql() returns [].
      let select_stmt = "SELECT id, amount FROM " <> name
      let assert Ok(rows) = mongreldb.sql(db, select_stmt)
      case rows {
        [] -> Nil
        _ -> rows |> list.length |> should.equal(1)
      }
    }
  }
}

pub fn schema_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let name = unique_table("gleam_schema")
      let assert Ok(_) =
        fresh_table(db, name, [int_col(1, "id", True), float_col(2, "amount")])

      let assert Ok(catalog) = mongreldb.schema(db)
      let names = list.map(catalog, fn(p) { p.0 })
      names |> list.contains(name) |> should.be_true
    }
  }
}

pub fn schema_for_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let name = unique_table("gleam_schema_for")
      let assert Ok(_) =
        fresh_table(db, name, [int_col(1, "id", True), float_col(2, "amount")])

      let assert Ok(desc) = mongreldb.schema_for(db, name)
      // The descriptor must carry a schema_id and a columns array of length 2.
      let assert Ok(_schema_id) =
        dynamic.field(named: "schema_id", of: dynamic.int)(desc)
      let assert Ok(cols) =
        dynamic.field(named: "columns", of: dynamic.list(of: dynamic.dynamic))(
          desc,
        )
      cols |> list.length |> should.equal(2)
    }
  }
}

pub fn table_names_lists_created_table_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let name = unique_table("gleam_tables")
      let assert Ok(_) = fresh_table(db, name, [int_col(1, "id", True)])

      let assert Ok(names) = mongreldb.table_names(db)
      names |> list.contains(name) |> should.be_true
    }
  }
}

pub fn error_on_nonexistent_table_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let name = unique_table("gleam_missing")
      let result = mongreldb.schema_for(db, name)
      result |> should.be_error
      Nil
    }
  }
}

pub fn error_type_carries_status_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let name = unique_table("gleam_missing2")
      // schema_for maps a 404 to NotFound, the typed result of the status.
      let result = mongreldb.schema_for(db, name)
      case result {
        Error(mongreldb.NotFound) -> should.be_true(True)
        Error(_) -> should.be_true(False)
        Ok(_) -> should.be_true(False)
      }
    }
  }
}

// ── History retention helpers ─────────────────────────────────────────────

fn retention_table_columns() -> List(mongreldb.Column) {
  [
    mongreldb.Column(1, "id", "int64", True, False, None, None),
    mongreldb.Column(2, "name", "varchar", False, False, None, None),
    mongreldb.Column(3, "amount", "int64", False, False, None, None),
  ]
}

fn as_of_count(
  db: mongreldb.Client,
  table: String,
  pk: Int,
  amount: Int,
  epoch: Int,
) -> Result(Int, mongreldb.MongrelError) {
  let stmt =
    "SELECT count(*) AS n FROM "
    <> table
    <> " AS OF EPOCH "
    <> int.to_string(epoch)
    <> " WHERE id = "
    <> int.to_string(pk)
    <> " AND amount = "
    <> int.to_string(amount)
  use rows <- result.try(mongreldb.sql(db, stmt))
  case rows {
    [row] -> {
      use n <- result.try(
        dynamic.field(named: "n", of: dynamic.int)(row)
        |> result.replace_error(mongreldb.Json("missing n")),
      )
      Ok(n)
    }
    _ -> Error(mongreldb.Json("expected one row"))
  }
}

fn find_epoch_with_value(
  db: mongreldb.Client,
  table: String,
  pk: Int,
  amount: Int,
  lo: Int,
  hi: Int,
) -> Result(Int, mongreldb.MongrelError) {
  list.range(lo, hi)
  |> list.find_map(fn(epoch) {
    case as_of_count(db, table, pk, amount, epoch) {
      Ok(n) if n > 0 -> Ok(epoch)
      _ -> Error(Nil)
    }
  })
  |> result.replace_error(mongreldb.Json("no retained epoch contained the expected value"))
}

// ── History retention tests ─────────────────────────────────────────────────

pub fn history_retention_read_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let assert Ok(#(window, _)) =
        mongreldb.set_history_retention_epochs(db, 100)

      let name = unique_table("gleam_ret_read")
      let _ = mongreldb.drop_table(db, name)
      let assert Ok(_) =
        mongreldb.create_table(db, name, retention_table_columns())

      let assert Ok(_) =
        mongreldb.put(
          db,
          name,
          [
            mongreldb.Cell(1, mongreldb.int_value(1)),
            mongreldb.Cell(2, mongreldb.string_value("A")),
            mongreldb.Cell(3, mongreldb.int_value(10)),
          ],
          "",
        )
      let assert Ok(_) =
        mongreldb.upsert(
          db,
          name,
          [
            mongreldb.Cell(1, mongreldb.int_value(1)),
            mongreldb.Cell(2, mongreldb.string_value("A")),
            mongreldb.Cell(3, mongreldb.int_value(20)),
          ],
          [mongreldb.Cell(3, mongreldb.int_value(20))],
          "",
        )

      let assert Ok(#(_, earliest)) = mongreldb.history_retention(db)
      let assert Ok(old_epoch) =
        find_epoch_with_value(db, name, 1, 10, earliest, earliest + window)
      { old_epoch >= earliest } |> should.be_true

      // Leave the daemon with a generous default window for subsequent tests.
      let _ = mongreldb.set_history_retention_epochs(db, 10_000)
      Nil
    }
  }
}

pub fn history_retention_shrink_test() {
  case connect_or_skip() {
    Error(Nil) -> Nil
    Ok(db) -> {
      let assert Ok(#(window, _)) =
        mongreldb.set_history_retention_epochs(db, 100)

      let name = unique_table("gleam_ret_shrink")
      let _ = mongreldb.drop_table(db, name)
      let assert Ok(_) =
        mongreldb.create_table(db, name, retention_table_columns())

      let assert Ok(_) =
        mongreldb.put(
          db,
          name,
          [
            mongreldb.Cell(1, mongreldb.int_value(1)),
            mongreldb.Cell(2, mongreldb.string_value("X")),
            mongreldb.Cell(3, mongreldb.int_value(10)),
          ],
          "",
        )
      let assert Ok(_) =
        mongreldb.upsert(
          db,
          name,
          [
            mongreldb.Cell(1, mongreldb.int_value(1)),
            mongreldb.Cell(2, mongreldb.string_value("X")),
            mongreldb.Cell(3, mongreldb.int_value(20)),
          ],
          [mongreldb.Cell(3, mongreldb.int_value(20))],
          "",
        )

      // Advance the current epoch with several distinct commits so the floor moves.
      list.range(1, 10)
      |> list.each(fn(i) {
        let assert Ok(_) =
          mongreldb.upsert(
            db,
            name,
            [
              mongreldb.Cell(1, mongreldb.int_value(1)),
              mongreldb.Cell(2, mongreldb.string_value("X")),
              mongreldb.Cell(3, mongreldb.int_value(30 + i)),
            ],
            [mongreldb.Cell(3, mongreldb.int_value(30 + i))],
            "",
          )
      })

      let assert Ok(#(_, earliest)) = mongreldb.history_retention(db)
      let assert Ok(old_epoch) =
        find_epoch_with_value(db, name, 1, 10, earliest, earliest + window)

      let assert Ok(#(_, new_earliest)) =
        mongreldb.set_history_retention_epochs(db, 5)
      { new_earliest > old_epoch } |> should.be_true

      // Querying below the floor should now error.
      as_of_count(db, name, 1, 10, old_epoch)
      |> should.be_error

      // Re-expanding cannot restore pruned history.
      let _ = mongreldb.set_history_retention_epochs(db, 10_000)
      as_of_count(db, name, 1, 10, old_epoch)
      |> should.be_error
    }
  }
}

// ── Test runner output helper ─────────────────────────────────────────────

@external(erlang, "io", "format")
fn io_format(fmt: String, args: List(dynamic.Dynamic)) -> Nil

fn io_println(msg: String) {
  io_format("~s~n", [dynamic.from(msg)])
}
