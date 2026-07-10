# SQL

MongrelDB ships a DataFusion-backed SQL engine at `POST /sql`. From Gleam, run
SQL with `mongreldb.sql`:

```gleam
let assert Ok(rows) = mongreldb.sql(db, "SELECT 1")
```

This guide covers the SQL surface - DDL, DML, `CREATE TABLE AS SELECT`,
recursive CTEs, and window functions - and when to reach for SQL versus the
native query builder.

---

## How `sql` behaves

`mongreldb.sql(db, sql)` sends `{"sql": "...", "format": "json"}` to `/sql`. It
returns the decoded rows when the daemon replies with a JSON result set, and an
empty list with no error otherwise.

In practice:

- **DDL and DML** (`CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE`) reply with a
  non-JSON status body. `sql` returns an empty list - success is the signal.
- **`SELECT`** returns a JSON array of row objects keyed by column name when the
  server honors the requested JSON format; otherwise an empty list.

Errors are mapped to the same typed error set as everything else: an HTTP 400
or 5xx maps to `Error(Query(...))`/`Error(Http(...))`; 409 maps to
`Error(Conflict)`; and so on. See [errors.md](errors.md).

```gleam
case mongreldb.sql(db, "INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)") {
  Ok(_) -> io.println("inserted")
  Error(mongreldb.Conflict) -> io.println("duplicate row")
  Error(e) -> io.println("error: " <> string.inspect(e))
}
```

## CREATE TABLE

```gleam
let assert Ok(_) = mongreldb.sql(db,
  "CREATE TABLE products (
    id          INT64 PRIMARY KEY,
    name        VARCHAR,
    price       FLOAT64,
    category    VARCHAR,
    in_stock    BOOLEAN
  )",
)
```

## INSERT

```gleam
let assert Ok(_) = mongreldb.sql(db, "INSERT INTO products (id, name, price, category, in_stock) VALUES (1, 'Widget', 9.99, 'tools', true)")
let assert Ok(_) = mongreldb.sql(db, "INSERT INTO products VALUES (2, 'Gadget', 19.99, 'tools', true)")
```

For bulk inserts, the native batch transaction (`mongreldb.begin`) is usually
faster because it stages ops in one round trip without re-parsing SQL.

## UPDATE

```gleam
let assert Ok(_) = mongreldb.sql(db, "UPDATE products SET price = 14.99 WHERE id = 1")
let assert Ok(_) = mongreldb.sql(db, "UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'")
```

## DELETE

```gleam
let assert Ok(_) = mongreldb.sql(db, "DELETE FROM products WHERE in_stock = false")
let assert Ok(_) = mongreldb.sql(db, "DELETE FROM products WHERE id = 2")
```

## SELECT

```gleam
let assert Ok(_) = mongreldb.sql(db, "SELECT id, name FROM products WHERE category = 'tools' ORDER BY price")
let assert Ok(_) = mongreldb.sql(db, "SELECT category, COUNT(*) AS n FROM products GROUP BY category")
```

## CREATE TABLE AS SELECT

Materialize a query result into a new table. Great for snapshots, rollups,
and denormalized aggregates.

```gleam
// Snapshot all high-value orders into a new table.
let assert Ok(_) = mongreldb.sql(db, "CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")

// Roll up sales by customer.
let assert Ok(_) = mongreldb.sql(db,
  "CREATE TABLE sales_by_customer AS
   SELECT customer, SUM(amount) AS total
   FROM orders
   GROUP BY customer",
)
```

## Recursive CTEs

`WITH RECURSIVE` is fully supported. Classic use cases: series generation,
hierarchy/graph traversal.

```gleam
// Generate the numbers 1..10.
let assert Ok(_) = mongreldb.sql(db,
  "WITH RECURSIVE r(n) AS (
     SELECT 1
     UNION ALL
     SELECT n + 1 FROM r WHERE n < 10
   )
   SELECT n FROM r",
)
```

## Window functions

Window functions compute aggregates/rankings across a moving window without
collapsing rows. Useful for top-N-per-group, running totals, and row numbers.

```gleam
// Row number within each customer, ordered by amount descending.
let assert Ok(_) = mongreldb.sql(db,
  "SELECT id, customer, amount,
          ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) AS rn
   FROM orders",
)

// Running total per customer.
let assert Ok(_) = mongreldb.sql(db,
  "SELECT id, customer, amount,
          SUM(amount) OVER (PARTITION BY customer ORDER BY id) AS running_total
   FROM orders",
)
```

## When to use SQL vs. the query builder

| Reach for | When |
|-----------|------|
| **`QueryBuilder`** | Point lookups, range scans, bitmap filters, full-text, and vector similarity that map to a native index. Sub-millisecond, no parser overhead. |
| **SQL** | DDL, multi-statement setup, joins, recursive CTEs, window functions, and arbitrary aggregates. Also the natural choice for admin scripts and one-off analysis. |

Mix freely: create tables with SQL, write rows with `mongreldb.put`, read them
back with `QueryBuilder`, and run analytics with SQL.

## Next steps

- [queries.md](queries.md) - every native index condition in detail
- [transactions.md](transactions.md) - bulk inserts via batch transactions
- [errors.md](errors.md) - handling SQL execution errors
