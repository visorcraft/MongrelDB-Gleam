# Authentication & Authorization

A `mongreldb-server` daemon runs in one of three modes:

1. **Open** (default) - no auth required.
2. **Bearer token** (`--auth-token <TOKEN>`) - every request must carry an
   `Authorization: Bearer <TOKEN>` header.
3. **HTTP Basic** (`--auth-users`) - every request must carry an
   `Authorization: Basic <base64(user:pass)>` header.

The Gleam client supports all three through the `Options` struct passed to
`mongreldb.connect`. This guide shows each mode and how to manage users and
roles via SQL when the server is in Basic mode.

---

## Bearer token mode

Start the daemon with a token:

```sh
mongreldb-server --auth-token s3cret-token
```

Connect with `token`. The token is sent as `Authorization: Bearer ...` on
every request.

```gleam
let assert Ok(db) =
  mongreldb.connect("http://127.0.0.1:8453", mongreldb.Options(
    token: "s3cret-token",
    username: "",
    password: "",
  ))

case mongreldb.health(db) {
  Ok(True) -> io.println("healthy")
  _ -> io.println("unhealthy")
}
```

A missing or wrong token surfaces as `Error(Auth)` (HTTP 401/403).

## Basic auth mode

Start the daemon with a users file or inline users:

```sh
mongreldb-server --auth-users
```

Connect with `username` / `password`:

```gleam
let assert Ok(db) =
  mongreldb.connect("http://127.0.0.1:8453", mongreldb.Options(
    token: "",
    username: "admin",
    password: "s3cret",
  ))
```

The client base64-encodes `username:password` and sets
`Authorization: Basic ...` on every request.

## Token takes precedence

If you supply both, `token` wins and Basic credentials are ignored. This lets
you layer an override without branching:

```gleam
let assert Ok(db) =
  mongreldb.connect("http://127.0.0.1:8453", mongreldb.Options(
    username: "fallback",
    password: "user",
    token: "overrides-everything",
  ))
```

## User and role management via SQL

When the daemon is in Basic auth mode, users and roles live in the catalog and
are managed with SQL. Run these statements through `mongreldb.sql`.

### Create a user

```gleam
let assert Ok(_) = mongreldb.sql(db, "CREATE USER alice WITH PASSWORD 'hunter2'")
```

### Alter a user

```gleam
let assert Ok(_) = mongreldb.sql(db, "ALTER USER alice WITH PASSWORD 'new-password'")
let assert Ok(_) = mongreldb.sql(db, "ALTER USER alice ADMIN")
```

### Drop a user

```gleam
let assert Ok(_) = mongreldb.sql(db, "DROP USER alice")
```

### Roles and grants

```gleam
let assert Ok(_) = mongreldb.sql(db, "CREATE ROLE analyst")
let assert Ok(_) = mongreldb.sql(db, "GRANT SELECT ON orders TO analyst")
let assert Ok(_) = mongreldb.sql(db, "GRANT analyst TO alice")
let assert Ok(_) = mongreldb.sql(db, "REVOKE SELECT ON orders FROM analyst")
let assert Ok(_) = mongreldb.sql(db, "DROP ROLE analyst")
```

## Common pitfalls

**Auth errors look like other errors without a typed match.** A 401/403 maps
to `Error(Auth)`; a 404 maps to `Error(NotFound)`. Always discriminate with a
`case` rather than string-matching messages.

**Forgetting to set auth in production.** A client built with default
`Options` sends no credentials. Against an auth-enabled daemon, every call
returns `Error(Auth)`. Centralize client construction so the auth option is
never accidentally dropped.

**Token in version control.** Put secrets in the environment, a secret
manager, or a file outside the repo. Never commit a real token.

## Next steps

- [errors.md](errors.md) - `Error(Auth)` and the rest of the typed error set
- [quickstart.md](quickstart.md) - the full end-to-end walkthrough
