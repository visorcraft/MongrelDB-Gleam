<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Gleam Client</h1>

History retention: `set_history_retention_epochs`, `history_retention`, `history_retention_epochs`, and `earliest_retained_epoch`.

<p align="center">
  <b>Pure Gleam client for MongrelDB - embedded+server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
  <br />
  Built on Erlang's <code>httpc</code> via <code>gleam/http</code>. The API mirrors the MongrelDB PHP and Go clients.
</p>

<p align="center">
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
  <a href="https://github.com/visorcraft/MongrelDB-Gleam/actions/workflows/ci.yml"><img src="https://github.com/visorcraft/MongrelDB-Gleam/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://gleam.run/"><img src="https://img.shields.io/badge/Gleam-1.4.0-ffaffb.svg" alt="Gleam" /></a>
</p>

## Package

| Surface | Module | Install |
|---|---|---|
| Gleam client | `mongreldb` | `gleam add mongreldb` |

## Requirements

- **Gleam 1.4.0 or newer** (targeting the BEAM/Erlang)
- Erlang/OTP (for `httpc`)
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put` (with optional idempotency keys for safe retries) and `delete_by_pk`, plus batched `put`/`delete`/`delete_by_pk` and `upsert`-style insert-or-update via `sql` when needed.
- **Fluent query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality/IN, learned-range, null checks, FM-index full-text search, HNSW vector similarity (`ann`), and sparse vector match. Friendly aliases (`column` -> `column_id`, `min`/`max` -> `lo`/`hi`) are translated to the server's on-wire keys.
- **Idempotent batch transactions** - operations staged locally and committed atomically, with the engine enforcing unique, foreign-key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint (JSON format requested): recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, and multi-statement execution.
- **Schema management**: typed table creation with enum/default fields and native constraints, full schema catalog, and per-table descriptors.
- **Typed errors**: `Auth` (401/403), `NotFound` (404), `Conflict` (409), `Query` (everything else non-2xx), `Http` (transport), and `Json` (malformed response) - a single tagged result you match on.

## Examples

Task-focused, commented guides live in [`docs/`](docs):

- [Quickstart](docs/quickstart.md) - install, start the daemon, write and run a complete program.
- [Transactions](docs/transactions.md) - batch commits, idempotency keys, constraint handling.
- [Queries](docs/queries.md) - every native condition type and the index it pushes down to.
- [SQL](docs/sql.md) - recursive CTEs, window functions, advanced SQL.
- [Authentication](docs/auth.md) - Bearer token, HTTP Basic, and open modes.
- [Errors](docs/errors.md) - the typed error set and recovery patterns.

## Quick Example

```gleam
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import mongreldb

pub fn main() {
  let assert Ok(db) =
    mongreldb.connect("http://127.0.0.1:8453", mongreldb.Options(token: "", username: "", password: ""))

  // Create a table. Column ids are stable on-wire identifiers.
  let assert Ok(_) = mongreldb.create_table(db, "orders", [
    mongreldb.Column(1, "id", "int64", True, False, None, None),
    mongreldb.Column(2, "customer", "varchar", False, False, None, None),
    mongreldb.Column(3, "amount", "float64", False, False, None, None),
  ])

  // Insert rows (cells pair column id -> value).
  let assert Ok(_) = mongreldb.put(db, "orders", [
    mongreldb.Cell(1, mongreldb.int_value(1)),
    mongreldb.Cell(2, mongreldb.string_value("Alice")),
    mongreldb.Cell(3, mongreldb.float_value(99.5)),
  ], "")

  // Query with a native index condition (learned-range index).
  let q =
    db
    |> mongreldb.query("orders")
    |> mongreldb.where_("range", [
      #("column", mongreldb.int_value(3)),
      #("min", mongreldb.float_value(100.0)),
    ])
    |> mongreldb.limit_(100)
  let assert Ok(rows) = mongreldb.execute(q)
  io.println("rows: " <> int.to_string(list.length(rows)))

  let assert Ok(n) = mongreldb.count(db, "orders")
  io.println("count: " <> int.to_string(n)) // 1
}
```

Use `ColumnWithDefaults` for static JSON scalar defaults and explicit dynamic
defaults. `default_value_json` takes precedence over legacy string
`default_value`; `default_expr` accepts `"now"` or `"uuid"` and takes
precedence server-side. The static-default matrix covers strings, integers,
booleans, explicit JSON `null`, and literal strings such as `"now"`.

## History retention

MongrelDB keeps a configurable number of recent commit epochs. The getters
`history_retention_epochs` and `earliest_retained_epoch` read the current
window and floor; `set_history_retention_epochs` changes the window. You can
query older versions with `AS OF EPOCH` through `sql`:

```gleam
import gleam/int

let assert Ok(#(window, floor)) = mongreldb.set_history_retention_epochs(db, 10_000)
let assert Ok(window) = mongreldb.history_retention_epochs(db)
let assert Ok(floor) = mongreldb.earliest_retained_epoch(db)

// The chosen epoch must be >= floor.
let stmt = "SELECT * FROM orders AS OF EPOCH " <> int.to_string(floor)
let assert Ok(rows) = mongreldb.sql(db, stmt)
```

Lowering retention advances the earliest retained epoch; raising it again does
not restore history that was already pruned.

## Authentication

```gleam
// Bearer token (--auth-token mode)
let assert Ok(db) =
  mongreldb.connect("http://127.0.0.1:8453", mongreldb.Options(
    token: "my-secret-token",
    username: "",
    password: "",
  ))

// HTTP Basic (--auth-users mode)
let assert Ok(db) =
  mongreldb.connect("http://127.0.0.1:8453", mongreldb.Options(
    token: "",
    username: "admin",
    password: "s3cret",
  ))
```

A Bearer token takes precedence over Basic credentials when both are supplied.

## Batch transactions

Operations are staged locally and committed atomically. The engine enforces
unique, foreign-key, and check constraints at commit time.

```gleam
let txn = mongreldb.begin(db)
let assert Ok(txn) = mongreldb.txn_put(txn, "orders", [
  mongreldb.Cell(1, mongreldb.int_value(10)),
], False)

// atomic - all or nothing
let assert Ok(#(_, results)) = mongreldb.commit(txn, "")

// Idempotent commit - safe to retry; the daemon returns the original response.
let retry = mongreldb.begin(db)
let assert Ok(retry) = mongreldb.txn_put(retry, "orders", [
  mongreldb.Cell(1, mongreldb.int_value(20)),
], False)
let assert Ok(_) = mongreldb.commit(retry, "order-20-create")
```

## Native query builder

Conditions push down to the engine's specialized indexes. The builder accepts
friendly aliases that are translated to the server's on-wire keys: `column`
(-> `column_id`), `min`/`max` (-> `lo`/`hi`). The canonical keys are also
accepted directly.

```gleam
// Bitmap equality (low-cardinality columns).
let q1 =
  db
  |> mongreldb.query("orders")
  |> mongreldb.where_("bitmap_eq", [
    #("column", mongreldb.int_value(2)),
    #("value", mongreldb.string_value("Alice")),
  ])
let assert Ok(_) = mongreldb.execute(q1)

// Range query (learned-range index).
let q2 =
  db
  |> mongreldb.query("orders")
  |> mongreldb.where_("range", [
    #("column", mongreldb.int_value(3)),
    #("min", mongreldb.float_value(50.0)),
    #("max", mongreldb.float_value(150.0)),
  ])
  |> mongreldb.limit_(100)
let assert Ok(_) = mongreldb.execute(q2)
```

## SQL

```gleam
let assert Ok(_) = mongreldb.sql(db, "INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)")
let assert Ok(_) = mongreldb.sql(db, "CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")

// Recursive CTEs and window functions
let cte =
  "WITH RECURSIVE r(n) AS (
    SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10
  ) SELECT n FROM r"
let assert Ok(_) = mongreldb.sql(db, cte)
```

The `/sql` endpoint is requested in JSON format. For statements that yield no
rows (DDL/DML) `sql` returns an empty list with no error.

## Error handling

Every non-2xx response is mapped to a typed error. Match on the variant.

```gleam
case mongreldb.schema_for(db, "missing_table") {
  Ok(desc) -> io.println("found")
  Error(mongreldb.NotFound) -> io.println("not found")
  Error(mongreldb.Conflict) -> io.println("constraint violation")
  Error(mongreldb.Auth) -> io.println("not authorized")
  Error(mongreldb.Query(_)) -> io.println("query/server error")
  Error(_) -> io.println("other error")
}
```

| HTTP status | Error |
|-------------|-------|
| 401, 403 | `Auth` |
| 404 | `NotFound` |
| 409 | `Conflict` |
| other non-2xx | `Query` |
| transport failure | `Http` |
| malformed JSON | `Json` |

## API reference

### `mongreldb`

| Method | Description |
|--------|-------------|
| `connect(url, options) Result(Client, Nil)` | Construct a client (url defaults to `http://127.0.0.1:8453`) |
| `health(db) Result(Bool, MongrelError)` | Check daemon health |
| `table_names(db) Result(List(String), MongrelError)` | List table names |
| `create_table(db, name, columns) Result(Int, MongrelError)` / `create_table_with_constraints(db, name, columns, constraints)` | Create a table; the constraints helper forwards the native `constraints` object |
| `drop_table(db, name) Result(Nil, MongrelError)` | Drop a table |
| `count(db, table) Result(Int, MongrelError)` | Row count |
| `history_retention(db) Result(#(Int, Int), MongrelError)` | Get both retention values |
| `history_retention_epochs(db) Result(Int, MongrelError)` | Get the retention window |
| `earliest_retained_epoch(db) Result(Int, MongrelError)` | Get the earliest readable epoch |
| `set_history_retention_epochs(db, epochs) Result(#(Int, Int), MongrelError)` | Set the retention window |
| `put(db, table, cells, key) Result(Value, MongrelError)` | Insert a row |
| `upsert(db, table, cells, update_cells, key) Result(Value, MongrelError)` | Insert or update on PK conflict |
| `delete(db, table, row_id) Result(Nil, MongrelError)` | Delete by row id |
| `delete_by_pk(db, table, pk) Result(Nil, MongrelError)` | Delete by primary key |
| `query(db, table) QueryBuilder` | Start a native query |
| `begin(db) Transaction` | Start a batch |
| `commit(txn, key) Result(#(Transaction, List(Value)), MongrelError)` | Commit atomically |
| `rollback(txn) Result(Transaction, MongrelError)` | Discard all operations |
| `sql(db, sql) Result(List(Value), MongrelError)` | Execute SQL |
| `schema(db) Result(List(#(String, Value)), MongrelError)` | Full schema catalog |
| `schema_for(db, table) Result(Value, MongrelError)` | Single-table descriptor |

### `QueryBuilder`

| Method | Description |
|--------|-------------|
| `where_(qb, type, params) QueryBuilder` | Add a native condition (AND-ed) |
| `projection(qb, column_ids) QueryBuilder` | Set column projection |
| `limit_(qb, n) QueryBuilder` | Set row limit |
| `offset(qb, n) QueryBuilder` | Skip matching rows before the limit |
| `execute(qb) Result(List(Value), MongrelError)` | Run the query; returns the rows |

### `Transaction`

| Method | Description |
|--------|-------------|
| `txn_put(txn, table, cells, returning) Result(Transaction, MongrelError)` | Stage an insert |
| `txn_delete(txn, table, row_id) Result(Transaction, MongrelError)` | Stage a delete by row id |
| `txn_delete_by_pk(txn, table, pk) Result(Transaction, MongrelError)` | Stage a delete by primary key |
| `txn_count(txn) Int` | Number of staged operations |
| `commit(txn, key) Result(#(Transaction, List(Value)), MongrelError)` | Commit atomically |
| `rollback(txn) Result(Transaction, MongrelError)` | Discard all operations |

## Building and testing

The test suite is a live integration suite: it boots a real `mongreldb-server`
daemon and exercises the full client surface against it. It skips cleanly when
no daemon is available.

```sh
# Run the offline unit tests (wire-shape conformance) + live suite (self-skips
# without a daemon).
gleam test

# Run the examples.
gleam run -m basic_crud
gleam run -m query_builder
gleam run -m transactions
```

Fetch a prebuilt server binary from the [MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.60.2/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

### Using the client in your project

Add the package to your `gleam.toml`:

```toml
[dependencies]
mongreldb = { version = ">= 0.60.2" }
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change - the suite must stay green.
3. Keep the client a thin wrapper over `mongreldb-server`.

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
