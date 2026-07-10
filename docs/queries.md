# Queries

The fluent `QueryBuilder` pushes conditions down to MongrelDB's native indexes
for sub-millisecond lookups - bitmap, learned-range, FM-index full text, HNSW
vector similarity, and more. Each condition type maps to one specialized
index; conditions are AND-ed together.

```gleam
let q =
  db
  |> mongreldb.query("orders")
  |> mongreldb.where_("range", [
    #("column", mongreldb.int_value(3)),
    #("min", mongreldb.float_value(100.0)),
    #("max", mongreldb.float_value(500.0)),
  ])
  |> mongreldb.projection([1, 2])
  |> mongreldb.limit_(100)
let assert Ok(rows) = mongreldb.execute(q)
```

This guide covers every condition type, projection, limits, combining
conditions, and the friendly aliases the builder translates for you.

---

## The basics

Every query starts with `mongreldb.query(db, table)` and ends with `execute`:

| Method | Purpose |
|--------|---------|
| `where_(qb, type, params)` | Add a native condition. Multiple `where_` calls are AND-ed. |
| `projection(qb, column_ids)` | Return only these column ids (omit for all columns). |
| `limit_(qb, n)` | Cap the number of rows. |
| `execute(qb)` | Send and decode. |

The request body produced by the builder matches the daemon's `/kit/query`
shape:

```json
{
  "table": "orders",
  "conditions": [{"range": {"column_id": 3, "lo": 100.0, "hi": 500.0}}],
  "projection": [1, 2],
  "limit": 100
}
```

## Condition types

`params` is a list of `#(String, Value)`. Column references use the numeric
**column id**, never the column name.

### `pk` - exact primary-key match

The fastest lookup. `value` is the primary-key value.

```gleam
let q =
  db
  |> mongreldb.query("orders")
  |> mongreldb.where_("pk", [#("value", mongreldb.int_value(42))])
let assert Ok(_) = mongreldb.execute(q)
```

### `range` - integer range (learned-range index)

Inclusive bounds. Omit `lo` (min) or `hi` (max) for an open range.

```gleam
let q =
  db
  |> mongreldb.query("orders")
  |> mongreldb.where_("range", [
    #("column", mongreldb.int_value(3)),
    #("min", mongreldb.int_value(100)),
    #("max", mongreldb.int_value(500)),
  ])
let assert Ok(_) = mongreldb.execute(q)
```

### `range_f64` - float range with inclusive/exclusive control

Adds `lo_inclusive` / `hi_inclusive` flags (default inclusive).

```gleam
let q =
  db
  |> mongreldb.query("orders")
  |> mongreldb.where_("range_f64", [
    #("column", mongreldb.int_value(3)),
    #("min", mongreldb.float_value(100.0)),
    #("max", mongreldb.float_value(500.0)),
    #("min_inclusive", mongreldb.bool_value(True)),
    #("max_inclusive", mongreldb.bool_value(False)), // (100.0, 500.0]
  ])
let assert Ok(_) = mongreldb.execute(q)
```

### `bitmap_eq` - equality on a bitmap-indexed column

Best for low-cardinality columns (status, category, booleans).

```gleam
let q =
  db
  |> mongreldb.query("orders")
  |> mongreldb.where_("bitmap_eq", [
    #("column", mongreldb.int_value(2)),
    #("value", mongreldb.string_value("Alice")),
  ])
let assert Ok(_) = mongreldb.execute(q)
```

### `is_null` / `is_not_null` - null checks

```gleam
let q =
  db
  |> mongreldb.query("orders")
  |> mongreldb.where_("is_null", [#("column", mongreldb.int_value(3))])
let assert Ok(_) = mongreldb.execute(q)
```

### `fm_contains` - full-text substring search (FM-index)

Substring match within a column. Use `pattern` (the server key) or the
friendly `value` alias - both translate to `pattern` on the wire for FTS
conditions.

```gleam
let q =
  db
  |> mongreldb.query("documents")
  |> mongreldb.where_("fm_contains", [
    #("column", mongreldb.int_value(2)),
    #("pattern", mongreldb.string_value("database performance")),
  ])
  |> mongreldb.limit_(10)
let assert Ok(_) = mongreldb.execute(q)
```

### `ann` - dense vector similarity (HNSW)

Approximate nearest-neighbors over a vector column. `k` is the result count.

```gleam
let vec = [
  mongreldb.float_value(0.1),
  mongreldb.float_value(0.2),
  mongreldb.float_value(0.3),
  mongreldb.float_value(0.4),
]

let q =
  db
  |> mongreldb.query("embeddings")
  |> mongreldb.where_("ann", [
    #("column", mongreldb.int_value(2)),
    #("query", vec_value(vec)),
    #("k", mongreldb.int_value(10)),
  ])
let assert Ok(_) = mongreldb.execute(q)
```

## Projection (column selection)

`projection(qb, [1, 2])` restricts the columns in each returned row. Omit the
call for all columns. Projecting to only the columns you need cuts bandwidth
and decode cost.

```gleam
let q =
  db
  |> mongreldb.query("orders")
  |> mongreldb.where_("range", [#("column", mongreldb.int_value(3)), #("min", mongreldb.int_value(100))])
  |> mongreldb.projection([1, 2])
let assert Ok(_) = mongreldb.execute(q)
```

## Limit

`limit_(qb, n)` caps the result.

```gleam
let q =
  db
  |> mongreldb.query("orders")
  |> mongreldb.where_("range", [#("column", mongreldb.int_value(3)), #("min", mongreldb.int_value(100))])
  |> mongreldb.limit_(100)
let assert Ok(rows) = mongreldb.execute(q)
```

## Multiple AND conditions

Chain `where_` calls. Every condition must match; the server intersects the
index results.

```gleam
let q =
  db
  |> mongreldb.query("orders")
  |> mongreldb.where_("bitmap_eq", [
    #("column", mongreldb.int_value(2)),
    #("value", mongreldb.string_value("Alice")),
  ])
  |> mongreldb.where_("range", [
    #("column", mongreldb.int_value(3)),
    #("min", mongreldb.int_value(100)),
    #("max", mongreldb.int_value(500)),
  ])
  |> mongreldb.projection([1, 3])
  |> mongreldb.limit_(50)
let assert Ok(_) = mongreldb.execute(q)
```

## Friendly alias translation

The builder accepts readable parameter names and translates them to the
server's canonical on-wire keys. Both spellings work, so use whichever is
clearer in context.

| You write | Sent as | Applies to |
|-----------|---------|------------|
| `column` | `column_id` | all condition types |
| `min` | `lo` | `range`, `range_f64` |
| `max` | `hi` | `range`, `range_f64` |
| `min_inclusive` | `lo_inclusive` | `range_f64` |
| `max_inclusive` | `hi_inclusive` | `range_f64` |
| `value` | `pattern` | `fm_contains`, `fm_contains_all` only |

The `value` -> `pattern` alias applies **only** to FTS conditions, because
`pk` and `bitmap_eq` use `value` as their canonical key. For those, write
`value` directly.

For arbitrary predicates, joins, and aggregations that the native indexes do
not cover, use SQL instead - see [sql.md](sql.md).
