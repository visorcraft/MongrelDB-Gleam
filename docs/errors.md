# Error Handling

The Gleam client surfaces failures as values of a single, small custom type
rather than as exceptions. Each variant maps to a category of HTTP or
transport failure, so you discriminate with a `case` and recover precisely.

```gleam
import mongreldb
```

## The error type

Every public function on the client returns `Result(T, MongrelError)`, where
`MongrelError` is this type:

| Variant             | Meaning                                                          |
|---------------------|------------------------------------------------------------------|
| `Http(String)`      | A transport error or a server status we do not map more narrowly (3xx and most 5xx). |
| `Json(String)`      | The server returned a malformed or unexpected JSON body.         |
| `Auth`              | Authentication or authorization failed (HTTP 401 or 403).       |
| `NotFound`          | The table or row does not exist (HTTP 404).                      |
| `Conflict`          | A constraint violation rolled back a transaction, or a payment-required response (HTTP 402 or 409). |
| `Query(String)`     | The request was malformed: a bad condition, projection, or SQL statement (HTTP 400 and other 4xx). |
| `ResponseTooLarge`  | The response body exceeded `max_response_bytes`.                 |
| `AlreadyCommitted`  | A `Transaction` method was called after `commit` or `rollback`.  |

Because Gleam custom types are exhaustive, you cannot accidentally forget a
case once you write a `case` over them.

## How HTTP status maps to an error

The client converts the daemon's response into a variant:

| HTTP status            | Error              |
|------------------------|--------------------|
| 200 / 2xx              | (success, no error)|
| 401, 403               | `Auth`             |
| 404                    | `NotFound`         |
| 402, 409               | `Conflict`         |
| 400 and other 4xx      | `Query`            |
| 3xx, 5xx, and transport failures | `Http`   |
| Body that is not valid JSON | `Json`         |

Malformed JSON (a truncated body, a missing field the decoder expects) is
reported as `Json` regardless of the HTTP status.

## Matching errors

Use a `case` to handle each case:

```gleam
case mongreldb.schema_for(db, "users") {
  Ok(desc) -> io.println("found")
  Error(mongreldb.Auth) -> io.println("invalid credentials")
  Error(mongreldb.NotFound) -> io.println("table missing")
  Error(mongreldb.Query(_)) -> io.println("malformed query")
  Error(_) -> io.println("other error")
}
```

For the common "log and propagate" shape, a plain `let assert` or `use ... <-`
is enough:

```gleam
let assert Ok(rows) = mongreldb.execute(mongreldb.query(db, "users"))
```

## Transaction conflicts

A `commit` runs all staged ops in a single atomic batch. If any op violates a
unique, foreign-key, check, or trigger constraint, the daemon rolls back the
entire batch and returns HTTP 409, which the client surfaces as
`Error(Conflict)`.

```gleam
let txn = mongreldb.begin(db)
let assert Ok(txn) = mongreldb.txn_put(txn, "orders", [mongreldb.Cell(1, mongreldb.int_value(10))], False)

case mongreldb.commit(txn, "order-batch-001") {
  Ok(_) -> io.println("committed")
  Error(mongreldb.Conflict) -> io.println("batch rolled back - fix the data and retry")
  Error(e) -> panic as string.inspect(e)
}
```

The idempotency key makes a safe retry possible: re-stage the same ops on a
fresh transaction and commit with the same key. The daemon returns the
original response on duplicate commits.

## Single-use transactions

`commit` and `rollback` both flip an internal flag. Calling any method on the
transaction afterward returns `Error(AlreadyCommitted)`. Start a new
transaction for each batch:

```gleam
let txn = mongreldb.begin(db)
let assert Ok(_) = mongreldb.commit(txn, "key-1")

// reuse is an error:
// case mongreldb.txn_put(txn, "orders", [...], False) {
//   Error(mongreldb.AlreadyCommitted) -> ...
// }

let next = mongreldb.begin(db)
let assert Ok(_) = mongreldb.commit(next, "key-2")
```

## Retries and idempotency

Network glitches and daemon restarts happen. Pair an idempotency key with a
retry loop for commit. Only retry on `Error(Http(...))` (transport) with the
same idempotency key. `Conflict` and `Query` indicate a problem with the
request itself and must be fixed before retrying.

## Common pitfalls

**Swallowing errors with a catch-all.** A bare `let _ = result` discards the
category and hides bugs. Match with `case` so each branch is explicit.

**Retrying `Conflict`.** A conflict means the batch violated a constraint;
replaying the same ops will fail the same way. Fix the offending op, then
retry.

**Forgetting `AlreadyCommitted`.** A transaction is single-use. If you share
one across function boundaries, make it obvious who calls `commit` or
`rollback`.

## Next steps

- [transactions.md](transactions.md) - atomic batches and idempotency
- [auth.md](auth.md) - where `Error(Auth)` comes from
