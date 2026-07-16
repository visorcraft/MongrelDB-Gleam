# Quickstart

Zero to a running MongrelDB Gleam program in fifteen minutes. This guide assumes
a fresh machine and walks through installing the prerequisites, starting the
daemon, and writing, running, and understanding a complete program.

---

## 1. Prerequisites

You need two things installed: the Gleam toolchain (with Erlang/OTP) and a
`mongreldb-server` daemon.

### Install Gleam 1.4.0 or newer

Verify it:

```sh
gleam --version
# gleam 1.4.0 ...
```

If you do not have it, install from <https://gleam.run/getting-started/installing-gleam/>
or your package manager.

### Install mongreldb-server

Fetch a prebuilt server binary from the
[MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.58.2/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

Verify it runs:

```sh
./bin/mongreldb-server --version
```

## 2. Start the daemon

By default `mongreldb-server` listens on `http://127.0.0.1:8453` and stores
data in the current working directory.

```sh
mkdir -p /tmp/mdb-data && cd /tmp/mdb-data
/path/to/mongreldb-server
```

In another terminal, sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

Leave the daemon running for the rest of this guide.

## 3. Create a project and pull in the client

```sh
gleam new my_app
cd my_app
gleam add mongreldb
```

## 4. Write your first program

Edit `src/my_app.gleam`:

```gleam
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import mongreldb

pub fn main() {
  // 1. Connect to the daemon. Empty URL falls back to http://127.0.0.1:8453.
  let assert Ok(db) =
    mongreldb.connect("http://127.0.0.1:8453", mongreldb.Options(token: "", username: "", password: ""))

  // 2. Health check before doing anything else.
  let assert Ok(True) = mongreldb.health(db)

  // 3. Create a table. Each column has a stable numeric id, a name, a type,
  //    and optional constraint-style fields (`enum_variants`, `default_value`).
  //    The primary_key column is the row identity.
  let assert Ok(tid) = mongreldb.create_table(db, "orders", [
    mongreldb.Column(1, "id", "int64", True, False, None, None),
    mongreldb.Column(2, "customer", "varchar", False, False, None, None),
    mongreldb.Column(3, "amount", "float64", False, False, None, None),
    // Enum column: only the four listed values are accepted.
    mongreldb.Column(
      4, "status", "varchar", False, False,
      Some(["pending", "shipped", "delivered", "cancelled"]),
      None,
    ),
    // Enum column with a default applied when the cell is omitted.
    mongreldb.Column(
      5, "currency", "varchar", False, False,
      Some(["USD", "EUR", "GBP"]),
      Some("USD"),
    ),
  ])
  io.println("created table id: " <> int.to_string(tid))

  // 4. Insert rows. Cells pair column id -> value.
  let assert Ok(_) = mongreldb.put(db, "orders", [
    mongreldb.Cell(1, mongreldb.int_value(1)),
    mongreldb.Cell(2, mongreldb.string_value("Alice")),
    mongreldb.Cell(3, mongreldb.float_value(99.5)),
    mongreldb.Cell(4, mongreldb.string_value("pending")),
    mongreldb.Cell(5, mongreldb.string_value("USD")),
  ], "")

  // 5. Query with a native index condition. The range index serves this in
  //    sub-millisecond.
  let q =
    db
    |> mongreldb.query("orders")
    |> mongreldb.where_("range", [
      #("column", mongreldb.int_value(3)),
      #("min", mongreldb.float_value(100.0)),
    ])
    |> mongreldb.projection([1, 2])
    |> mongreldb.limit_(100)
  let assert Ok(rows) = mongreldb.execute(q)
  io.println("rows: " <> int.to_string(list.length(rows)))

  // 6. Count the rows.
  let assert Ok(n) = mongreldb.count(db, "orders")
  io.println("total rows: " <> int.to_string(n))
}
```

Build and run it:

```sh
gleam run
```

You should see:

```
created table id: 1
rows: 1
total rows: 2
```

## 5. What each part does

| Code | What it does |
|------|--------------|
| `mongreldb.connect(url, options)` | Builds an HTTP client targeting one daemon. Backed by Erlang `httpc` via `gleam/http`. |
| `mongreldb.health(db)` | GET `/health`; returns `Ok(True)` when the daemon answers. |
| `mongreldb.create_table(db, name, columns)` / `create_table_with_constraints(db, name, columns, constraints)` | POST `/kit/create_table`. Column `id`s are the on-wire identifiers; `enum_variants` and `default_value` are optional and emitted only when set; the constraints helper forwards the native `constraints` object. |
| `mongreldb.put(db, table, cells, key)` | Single-op transaction: POST `/kit/txn` with one `put` op. `cells` is flattened to `[col_id, val, ...]`. |
| `mongreldb.query(db, table) |> mongreldb.where_(...)` | Builds a `/kit/query` body. `where_` pushes a condition down to a native index. |
| `mongreldb.projection(qb, [1, 2])` | Server returns only those column ids, saving bandwidth. |
| `mongreldb.limit_(qb, 100)` | Caps the result. |
| `mongreldb.execute(qb)` | Sends the query and decodes the `rows` array. |
| `mongreldb.count(db, table)` | GET `/tables/{name}/count`. |

## 6. Constrained columns and defaults

`Column` accepts two optional constraint-style fields that are forwarded to the
daemon verbatim. They are omitted from the JSON body when `None`, so existing
schemas that don't set them produce an identical payload.

| Field | Type | Effect |
|-------|------|--------|
| `enum_variants` | `Option(List(String))` | Restrict the column to one of the listed string values. The engine rejects writes outside the set with `Error(Conflict)`. |
| `default_value` | `Option(String)` | Legacy string default applied when the cell is omitted on a `put`. |

For typed static defaults and dynamic defaults use `ColumnWithDefaults`:

```gleam
import gleam/json
import gleam/option.{None, Some}

// Static JSON scalar defaults preserve their JSON type.
mongreldb.ColumnWithDefaults(
  id: 4,
  name: "active",
  ty: "bool",
  primary_key: False,
  nullable: True,
  enum_variants: None,
  default_value: None,
  default_value_json: Some(json.bool(True)),
  default_expr: None,
)

// Explicit JSON null is a valid static default.
mongreldb.ColumnWithDefaults(
  id: 5,
  name: "notes",
  ty: "varchar",
  primary_key: False,
  nullable: True,
  enum_variants: None,
  default_value: None,
  default_value_json: Some(json.null()),
  default_expr: None,
)

// Dynamic defaults use default_expr; accepted values are "now" or "uuid".
mongreldb.ColumnWithDefaults(
  id: 6,
  name: "created",
  ty: "varchar",
  primary_key: False,
  nullable: True,
  enum_variants: None,
  default_value: None,
  default_value_json: None,
  default_expr: Some("now"),
)
```

`default_expr` takes precedence server-side. A literal `"now"` string default
must be set through `default_value_json` (as `json.string("now")`), not
`default_expr`. An empty `enum_variants` list is also omitted, so `None` and
`Some([])` produce identical wire shapes.

## 7. History retention

MongrelDB keeps a configurable number of recent commit epochs. The getters
`history_retention_epochs` and `earliest_retained_epoch` read the current
window and floor; `set_history_retention_epochs` changes the window. You can
query older versions with `AS OF EPOCH` through `sql`:

```gleam
import gleam/int

let assert Ok(#(window, earliest)) =
  mongreldb.set_history_retention_epochs(db, 10_000)
let assert Ok(window) = mongreldb.history_retention_epochs(db)
let assert Ok(earliest) = mongreldb.earliest_retained_epoch(db)

let stmt = "SELECT * FROM orders AS OF EPOCH " <> int.to_string(earliest)
let assert Ok(rows) = mongreldb.sql(db, stmt)
```

Lowering retention advances the earliest retained epoch; raising it again does
not restore history that was already pruned.

## 8. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `id` from `create_table`, never the `name`. The query builder's `column`
alias maps to the server's `column_id` - pass the integer id, not the string
name.

**Treating a single `put` as non-transactional.** `put` is a one-op
transaction. A unique constraint violation surfaces as `Error(Conflict)` (HTTP
409), not as a silent no-op.

**Calling `commit` twice on the same `Transaction`.** The second call returns
`Error(AlreadyCommitted)`. Start a fresh `mongreldb.begin(db)` for each logical
unit of work.

**Pointing at a daemon that requires auth.** If the daemon was started with
`--auth-token` or `--auth-users`, every call returns `Error(Auth)` unless you
set `token` or `username`/`password` in `Options`. See [auth.md](auth.md).

## Next steps

- [transactions.md](transactions.md) - atomic batches, idempotency, retries
- [queries.md](queries.md) - every native index condition
- [sql.md](sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`
- [auth.md](auth.md) - bearer tokens, basic auth, user/role management
- [errors.md](errors.md) - the full typed error set and recovery patterns
