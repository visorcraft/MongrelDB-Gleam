//// mongreldb is the pure-Gleam HTTP client for [MongrelDB].
////
//// It talks to a running mongreldb-server daemon's JSON API over Erlang's
//// built-in `httpc` (via `gleam/http`). The surface mirrors the MongrelDB PHP
//// and Go clients: typed CRUD, a fluent query builder that pushes conditions
//// down to the engine's native indexes, idempotent batch transactions, full SQL
//// access, and schema introspection.
////
//// Connect with `connect` and a base URL:
////
//// ```gleam
//// let assert Ok(db) = mongreldb.connect("http://127.0.0.1:8453", mongreldb.Options(token: "", username: "", password: ""))
//// let assert Ok(true) = mongreldb.health(db)
//// ```
////
//// [MongrelDB]: https://www.MongrelDB.com

import gleam/bit_array
import gleam/dict
import gleam/dynamic
import gleam/http.{type Method, Delete, Get, Post, Put}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// ── Public types ──────────────────────────────────────────────────────────

/// `default_base_url` is the daemon address used when none is supplied.
pub const default_base_url = "http://127.0.0.1:8453"

/// `max_response_bytes` caps the size of a response body read from the daemon
/// (256 MB). Bodies larger than this are aborted as a `ResponseTooLarge` error.
pub const max_response_bytes = 268_435_456

/// `strip_trailing_slash` removes a single trailing `/` from a URL base. Used
/// when normalizing the base URL; the older `string.trim_right(_, "/")` form is
/// unavailable in the pinned gleam_stdlib (0.47.x trims whitespace only).
fn strip_trailing_slash(s: String) -> String {
  case string.ends_with(s, "/") {
    False -> s
    True -> string.drop_end(s, 1)
  }
}

/// `strip_leading_slash` removes a single leading `/` from a path segment.
fn strip_leading_slash(s: String) -> String {
  case string.starts_with(s, "/") {
    False -> s
    True -> string.drop_start(s, 1)
  }
}

/// `MongrelError` is the typed error returned by every client operation. HTTP
/// status codes are mapped to a category: 401/403 -> `Auth`, 404 -> `NotFound`,
/// 409 -> `Conflict`, any other non-2xx -> `Query`. Transport failures are
/// reported as `Http`, malformed responses as `Json`.
pub type MongrelError {
  /// A transport error or a server status we do not map more narrowly (3xx and
  /// most 5xx).
  Http(String)
  /// The server returned a malformed or unexpected JSON body.
  Json(String)
  /// Authentication or authorization failed (HTTP 401 or 403).
  Auth
  /// The table or row does not exist (HTTP 404).
  NotFound
  /// A constraint violation rolled back a transaction, or a payment-required
  /// response (HTTP 402 or 409).
  Conflict
  /// The request was malformed: a bad condition, projection, or SQL statement
  /// (HTTP 400 and other 4xx).
  Query(String)
  /// The response body exceeded `max_response_bytes`.
  ResponseTooLarge
  /// A `Transaction` method was called after `commit` or `rollback`.
  AlreadyCommitted
}

/// `Client` is the MongrelDB HTTP client. Create one with `connect`.
pub type Client {
  Client(base_url: String, token: String, username: String, password: String)
}

/// `Options` configures a `Client`.
pub type Options {
  Options(
    /// `token` authenticates requests with a Bearer token (--auth-token mode).
    /// When set, it takes precedence over basic-auth credentials.
    token: String,
    /// `username` / `password` authenticate with HTTP Basic credentials
    /// (--auth-users mode). Ignored if `token` is also supplied.
    username: String,
    password: String,
  )
}

/// `Column` describes one column in a CREATE TABLE request.
pub type Column {
  Column(
    id: Int,
    name: String,
    ty: String,
    primary_key: Bool,
    nullable: Bool,
    /// Optional list of allowed enum variants. `None` means the column is not
    /// an enum.
    enum_variants: Option(List(String)),
    /// Optional default value as a raw string (the daemon coerces per the
    /// column's `ty`). `None` means no default.
    default_value: Option(String),
  )
  ColumnWithDefaults(
    id: Int,
    name: String,
    ty: String,
    primary_key: Bool,
    nullable: Bool,
    enum_variants: Option(List(String)),
    /// Legacy string default.
    default_value: Option(String),
    /// Static JSON scalar. Takes precedence over `default_value`.
    default_value_json: Option(json.Json),
    /// Dynamic default: `now` or `uuid`.
    default_expr: Option(String),
  )
}

/// `Value` is a dynamic JSON value used for cells, query parameters, and the
/// untyped payloads returned by the daemon.
pub type Value =
  dynamic.Dynamic

/// `Cell` pairs a column id with its value. The client flattens a list of
/// cells to the server's on-wire `[col_id, value, col_id, value, ...]` array
/// before sending.
pub type Cell {
  Cell(id: Int, value: Value)
}

// ── Connect ───────────────────────────────────────────────────────────────

/// `connect` returns a `Client` for the daemon at `base_url`. If `base_url`
/// is empty, `default_base_url` is used. The base URL has any trailing slash
/// trimmed.
pub fn connect(base_url: String, options: Options) -> Result(Client, Nil) {
  let url = case base_url {
    "" -> default_base_url
    other -> strip_trailing_slash(other)
  }
  Ok(Client(
    base_url: url,
    token: options.token,
    username: options.username,
    password: options.password,
  ))
}

// ── Health & tables ───────────────────────────────────────────────────────

/// `health` reports whether the daemon is reachable and healthy.
pub fn health(db: Client) -> Result(Bool, MongrelError) {
  use _body <- result.try(raw_request(db, Get, "/health", None))
  Ok(True)
}

/// `table_names` lists all table names in the database.
pub fn table_names(db: Client) -> Result(List(String), MongrelError) {
  use body <- result.try(raw_request(db, Get, "/tables", None))
  use data <- result.try(json_decode(body))
  use arr <- result.try(
    dynamic.list(of: dynamic.string)(data)
    |> result.replace_error(Json("expected an array of strings")),
  )
  Ok(arr)
}

/// `set_history_retention_epochs` sets the retention window and returns the
/// post-update `(history_retention_epochs, earliest_retained_epoch)` pair.
pub fn set_history_retention_epochs(db: Client, epochs: Int) -> Result(#(Int, Int), MongrelError) {
  use body <- result.try(raw_request(db, Put, "/history/retention", Some(history_retention_request_body(epochs))))
  history_retention_response_parse(body)
}

/// `history_retention` returns the current retention window and earliest retained
/// epoch as a pair.
pub fn history_retention(db: Client) -> Result(#(Int, Int), MongrelError) {
  use body <- result.try(raw_request(db, Get, "/history/retention", None))
  history_retention_response_parse(body)
}

/// `history_retention_epochs` returns the configured retention window.
pub fn history_retention_epochs(db: Client) -> Result(Int, MongrelError) {
  use values <- result.try(history_retention(db))
  Ok(values.0)
}

/// `earliest_retained_epoch` returns the earliest readable epoch floor.
pub fn earliest_retained_epoch(db: Client) -> Result(Int, MongrelError) {
  use values <- result.try(history_retention(db))
  Ok(values.1)
}

/// `history_retention_request_body` returns the exact JSON body sent by
/// `set_history_retention_epochs`. Exposed so wire-shape tests can assert the
/// PUT payload without a daemon.
pub fn history_retention_request_body(epochs: Int) -> String {
  json.to_string(json.object([#("history_retention_epochs", json.int(epochs))]))
}

/// `history_retention_response_parse` decodes the GET/PUT /history/retention
/// response shape. Exposed so wire-shape tests can exercise the parsing path
/// without a daemon. Rejects objects with missing or extra keys.
pub fn history_retention_response_parse(body: String) -> Result(#(Int, Int), MongrelError) {
  use data <- result.try(json_decode(body))
  use obj <- result.try(
    dynamic.dict(of: dynamic.string, to: dynamic.dynamic)(data)
    |> result.replace_error(Json("history retention response is not a JSON object")),
  )
  case dict.size(obj) == 2 {
    False -> Error(Json("history retention response keys mismatch"))
    True -> {
      use epochs <- result.try(dynamic.field(named: "history_retention_epochs", of: dynamic.int)(data) |> result.replace_error(Json("missing history_retention_epochs")))
      use earliest <- result.try(dynamic.field(named: "earliest_retained_epoch", of: dynamic.int)(data) |> result.replace_error(Json("missing earliest_retained_epoch")))
      Ok(#(epochs, earliest))
    }
  }
}

/// `create_table` creates a table named `name` with the given columns and
/// returns the assigned table id.
pub fn create_table(
  db: Client,
  name: String,
  columns: List(Column),
) -> Result(Int, MongrelError) {
  create_table_request(db, name, columns, None)
}

/// `create_table_with_constraints` adds the daemon's native `constraints` block. The value
/// is a JSON object such as `json.object([#("checks", ...)])`.
pub fn create_table_with_constraints(
  db: Client,
  name: String,
  columns: List(Column),
  constraints: json.Json,
) -> Result(Int, MongrelError) {
  create_table_request(db, name, columns, Some(constraints))
}

fn create_table_request(
  db: Client,
  name: String,
  columns: List(Column),
  constraints: Option(json.Json),
) -> Result(Int, MongrelError) {
  let col_arr = list.map(columns, column_to_json)
  let payload = case constraints {
    None ->
      json.object([
        #("name", json.string(name)),
        #("columns", json.preprocessed_array(col_arr)),
      ])
    Some(value) ->
      json.object([
        #("name", json.string(name)),
        #("columns", json.preprocessed_array(col_arr)),
        #("constraints", value),
      ])
  }
  use body <- result.try(post_json(db, "/kit/create_table", payload))
  use data <- result.try(json_decode(body))
  use obj <- result.try(
    dynamic.field(named: "table_id", of: dynamic.int)(data)
    |> result.replace_error(Json("missing table_id")),
  )
  Ok(obj)
}

/// `drop_table` drops a table by name.
pub fn drop_table(db: Client, name: String) -> Result(Nil, MongrelError) {
  let path = "/tables/" <> url_path_escape(name)
  use _body <- result.try(raw_request(db, Delete, path, None))
  Ok(Nil)
}

/// `count` returns the row count for a table.
pub fn count(db: Client, table: String) -> Result(Int, MongrelError) {
  let path = "/tables/" <> url_path_escape(table) <> "/count"
  use body <- result.try(raw_request(db, Get, path, None))
  use data <- result.try(json_decode(body))
  use obj <- result.try(
    dynamic.field(named: "count", of: dynamic.int)(data)
    |> result.replace_error(Json("missing count")),
  )
  Ok(obj)
}

// ── CRUD (via the Kit typed transaction endpoint) ─────────────────────────

/// `put` inserts a row. `idempotency_key`, if non-empty, makes the commit safe
/// to retry. Returns the per-operation result object (the first element of the
/// server's results array).
pub fn put(
  db: Client,
  table: String,
  cells: List(Cell),
  idempotency_key: String,
) -> Result(Value, MongrelError) {
  let inner =
    json.object([
      #("table", json.string(table)),
      #("cells", json.preprocessed_array(flatten_cells(cells))),
      #("returning", json.bool(False)),
    ])
  let op = json.object([#("put", inner)])
  use results <- result.try(commit_txn(db, op, idempotency_key))
  case results {
    [] -> Ok(dynamic.from(Nil))
    [first, ..] -> Ok(first)
  }
}

/// `upsert` inserts a row, or updates it on a primary-key conflict. `cells`
/// are the insert values; `update_cells`, when non-empty, are the values to
/// apply on a conflict (an empty list means DO NOTHING).
pub fn upsert(
  db: Client,
  table: String,
  cells: List(Cell),
  update_cells: List(Cell),
  idempotency_key: String,
) -> Result(Value, MongrelError) {
  let base = [
    #("table", json.string(table)),
    #("cells", json.preprocessed_array(flatten_cells(cells))),
    #("returning", json.bool(False)),
  ]
  let entries = case update_cells {
    [] -> base
    _ -> [
      #("update_cells", json.preprocessed_array(flatten_cells(update_cells))),
      ..base
    ]
  }
  let inner = json.object(entries)
  let op = json.object([#("upsert", inner)])
  use results <- result.try(commit_txn(db, op, idempotency_key))
  case results {
    [] -> Ok(dynamic.from(Nil))
    [first, ..] -> Ok(first)
  }
}

/// `delete` removes a row by its internal row id.
pub fn delete(
  db: Client,
  table: String,
  row_id: Int,
) -> Result(Nil, MongrelError) {
  let inner =
    json.object([
      #("table", json.string(table)),
      #("row_id", json.int(row_id)),
    ])
  let op = json.object([#("delete", inner)])
  use _ <- result.try(commit_txn(db, op, ""))
  Ok(Nil)
}

/// `delete_by_pk` removes a row by its primary-key value.
pub fn delete_by_pk(
  db: Client,
  table: String,
  pk: Value,
) -> Result(Nil, MongrelError) {
  let inner =
    json.object([
      #("table", json.string(table)),
      #("pk", json_value_of_dynamic(pk)),
    ])
  let op = json.object([#("delete_by_pk", inner)])
  use _ <- result.try(commit_txn(db, op, ""))
  Ok(Nil)
}

// ── Query ─────────────────────────────────────────────────────────────────

/// `QueryCondition` is a normalized (type, params) condition pushed down to a
/// native index.
pub type QueryCondition {
  QueryCondition(condition_type: String, params: List(#(String, Value)))
}

/// `QueryBuilder` accumulates a single table query.
pub type QueryBuilder {
  QueryBuilder(
    client: Client,
    table: String,
    conditions: List(QueryCondition),
    projection: Option(List(Int)),
    limit: Option(Int),
    offset: Option(Int),
  )
}

/// `query` starts a fluent `QueryBuilder` against `table`.
pub fn query(db: Client, table: String) -> QueryBuilder {
  QueryBuilder(
    client: db,
    table: table,
    conditions: [],
    projection: None,
    limit: None,
    offset: None,
  )
}

/// `where` appends a condition. `cond_type` names the condition (e.g. `"pk"`,
/// `"column_eq"`, `"range"`); `params` is the condition payload, normalized.
pub fn where_(
  qb: QueryBuilder,
  cond_type: String,
  params: List(#(String, Value)),
) -> QueryBuilder {
  let normalized = normalize_condition(cond_type, params)
  QueryCondition(cond_type, normalized)
  |> fn(c) { QueryBuilder(..qb, conditions: [c, ..qb.conditions]) }
}

/// `projection` requests only the given column ids in each row.
pub fn projection(qb: QueryBuilder, column_ids: List(Int)) -> QueryBuilder {
  QueryBuilder(..qb, projection: Some(column_ids))
}

/// `limit_` caps the number of rows returned.
pub fn limit_(qb: QueryBuilder, row_limit: Int) -> QueryBuilder {
  QueryBuilder(..qb, limit: Some(row_limit))
}

/// `offset` skips matching rows before applying the limit.
pub fn offset(qb: QueryBuilder, row_offset: Int) -> QueryBuilder {
  QueryBuilder(..qb, offset: Some(row_offset))
}

/// `execute` builds the request, POSTs it to `/kit/query`, decodes the result
/// set, and returns the rows.
pub fn execute(qb: QueryBuilder) -> Result(List(Value), MongrelError) {
  let conds_json =
    list.map(qb.conditions, fn(c) {
      let params_json =
        list.map(c.params, fn(p) { #(p.0, json_value_of_dynamic(p.1)) })
      json.object([#(c.condition_type, json.object(params_json))])
    })
  let base = [#("table", json.string(qb.table))]
  let with_conds = case qb.conditions {
    [] -> base
    _ -> [#("conditions", json.preprocessed_array(conds_json)), ..base]
  }
  let with_proj = case qb.projection {
    None -> with_conds
    Some(ids) -> [
      #("projection", json.array(from: ids, of: json.int)),
      ..with_conds
    ]
  }
  let with_limit = case qb.limit {
    None -> with_proj
    Some(n) -> [#("limit", json.int(n)), ..with_proj]
  }
  let with_offset = case qb.offset {
    None -> with_limit
    Some(n) -> [#("offset", json.int(n)), ..with_limit]
  }
  let payload = json.object(with_offset)
  use body <- result.try(post_json(qb.client, "/kit/query", payload))
  use data <- result.try(json_decode(body))
  use obj <- result.try(
    dynamic.field(named: "rows", of: dynamic.list(of: dynamic.dynamic))(data)
    |> result.replace_error(Json("missing rows")),
  )
  Ok(obj)
}

// ── Transactions ──────────────────────────────────────────────────────────

/// `Transaction` buffers a sequence of operations and flushes them atomically
/// in a single `/kit/txn` request.
pub type Transaction {
  Transaction(client: Client, ops: List(json.Json), committed: Bool)
}

/// `begin` starts a new batch transaction.
pub fn begin(db: Client) -> Transaction {
  Transaction(client: db, ops: [], committed: False)
}

/// `txn_put` stages an insert on the transaction.
pub fn txn_put(
  txn: Transaction,
  table: String,
  cells: List(Cell),
  returning: Bool,
) -> Result(Transaction, MongrelError) {
  case txn.committed {
    True -> Error(AlreadyCommitted)
    False -> {
      let inner =
        json.object([
          #("table", json.string(table)),
          #("cells", json.preprocessed_array(flatten_cells(cells))),
          #("returning", json.bool(returning)),
        ])
      let op = json.object([#("put", inner)])
      Ok(Transaction(..txn, ops: [op, ..txn.ops]))
    }
  }
}

/// `txn_delete` stages a delete by row id.
pub fn txn_delete(
  txn: Transaction,
  table: String,
  row_id: Int,
) -> Result(Transaction, MongrelError) {
  case txn.committed {
    True -> Error(AlreadyCommitted)
    False -> {
      let inner =
        json.object([
          #("table", json.string(table)),
          #("row_id", json.int(row_id)),
        ])
      let op = json.object([#("delete", inner)])
      Ok(Transaction(..txn, ops: [op, ..txn.ops]))
    }
  }
}

/// `txn_delete_by_pk` stages a delete by primary key.
pub fn txn_delete_by_pk(
  txn: Transaction,
  table: String,
  pk: Value,
) -> Result(Transaction, MongrelError) {
  case txn.committed {
    True -> Error(AlreadyCommitted)
    False -> {
      let inner =
        json.object([
          #("table", json.string(table)),
          #("pk", json_value_of_dynamic(pk)),
        ])
      let op = json.object([#("delete_by_pk", inner)])
      Ok(Transaction(..txn, ops: [op, ..txn.ops]))
    }
  }
}

/// `txn_count` returns the number of staged operations.
pub fn txn_count(txn: Transaction) -> Int {
  list.length(txn.ops)
}

/// `commit` sends a batch of staged operations atomically to `/kit/txn` and
/// returns the per-operation results array.
pub fn commit(
  txn: Transaction,
  idempotency_key: String,
) -> Result(#(Transaction, List(Value)), MongrelError) {
  case txn.committed {
    True -> Error(AlreadyCommitted)
    False -> {
      // An empty batch commits to nothing; mark committed and return empty.
      case txn.ops {
        [] -> Ok(#(Transaction(..txn, committed: True), []))
        _ -> {
          use results <- result.try(commit_txn_raw(
            txn.client,
            txn.ops,
            idempotency_key,
          ))
          Ok(#(Transaction(..txn, committed: True), results))
        }
      }
    }
  }
}

/// `rollback` discards all locally staged operations.
pub fn rollback(txn: Transaction) -> Result(Transaction, MongrelError) {
  case txn.committed {
    True -> Error(AlreadyCommitted)
    False -> Ok(Transaction(..txn, committed: True, ops: []))
  }
}

// ── SQL ───────────────────────────────────────────────────────────────────

/// `sql` executes a SQL statement via the `/sql` endpoint, requesting JSON
/// output. The server returns a JSON array of row objects keyed by column
/// name. For statements that yield no rows (DDL/DML), an empty list is
/// returned.
pub fn sql(db: Client, sql_text: String) -> Result(List(Value), MongrelError) {
  let payload =
    json.object([
      #("sql", json.string(sql_text)),
      #("format", json.string("json")),
    ])
  use body <- result.try(post_json(db, "/sql", payload))
  let trimmed = string.trim(body)
  case trimmed {
    "" -> Ok([])
    s -> {
      // JSON format requested; a leading '{' is a single object (e.g. an
      // error envelope), not a row set, so return an empty list. A '[' begins
      // the row array to decode.
      case string.starts_with(s, "[") {
        False -> Ok([])
        True -> {
          use data <- result.try(json_decode(body))
          use arr <- result.try(
            dynamic.list(of: dynamic.dynamic)(data)
            |> result.replace_error(Json("expected a JSON array")),
          )
          Ok(arr)
        }
      }
    }
  }
}

// ── Schema ────────────────────────────────────────────────────────────────

/// `schema` returns the full schema catalog: a list of (table-name,
/// descriptor) pairs.
pub fn schema(db: Client) -> Result(List(#(String, Value)), MongrelError) {
  use body <- result.try(raw_request(db, Get, "/kit/schema", None))
  use data <- result.try(json_decode(body))
  use tables <- result.try(
    dynamic.field(
      named: "tables",
      of: dynamic.dict(of: dynamic.string, to: dynamic.dynamic),
    )(data)
    |> result.map(dict.to_list)
    |> result.replace_error(Json("missing tables")),
  )
  Ok(tables)
}

/// `schema_for` returns the descriptor for a single table.
pub fn schema_for(db: Client, table: String) -> Result(Value, MongrelError) {
  let path = "/kit/schema/" <> url_path_escape(table)
  use body <- result.try(raw_request(db, Get, path, None))
  use data <- result.try(json_decode(body))
  Ok(data)
}

// ── Internal HTTP plumbing ────────────────────────────────────────────────

/// `commit_txn` is the convenience helper used by single-op methods. It builds
/// the JSON ops array and returns the decoded results.
fn commit_txn(
  db: Client,
  ops: json.Json,
  idempotency_key: String,
) -> Result(List(Value), MongrelError) {
  commit_txn_raw(db, [ops], idempotency_key)
}

fn commit_txn_raw(
  db: Client,
  ops: List(json.Json),
  idempotency_key: String,
) -> Result(List(Value), MongrelError) {
  let base = [#("ops", json.preprocessed_array(ops))]
  let entries = case idempotency_key {
    "" -> base
    k -> [#("idempotency_key", json.string(k)), ..base]
  }
  let payload = json.object(entries)
  use body <- result.try(post_json(db, "/kit/txn", payload))
  use data <- result.try(json_decode(body))
  use results <- result.try(
    dynamic.field(named: "results", of: dynamic.list(of: dynamic.dynamic))(data)
    |> result.replace_error(Json("missing results")),
  )
  Ok(results)
}

/// `post_json` performs a POST with a JSON body (Content-Type: application/json)
/// and returns the raw response body string.
fn post_json(
  db: Client,
  path: String,
  payload: json.Json,
) -> Result(String, MongrelError) {
  raw_request(db, Post, path, Some(json.to_string(payload)))
}

/// `raw_request` builds and runs one request against the daemon via Erlang's
/// `httpc`. Non-2xx responses are mapped to typed errors via `map_status`.
fn raw_request(
  db: Client,
  method: Method,
  path: String,
  body: Option(String),
) -> Result(String, MongrelError) {
  let url = db.base_url <> "/" <> strip_leading_slash(path)

  let assert Ok(req) = request.to(url)
  let req = request.set_method(req, method)

  // Add a Content-Type header whenever a JSON body is present (the server's
  // JSON extractors require it).
  let req = case body {
    Some(_) -> request.set_header(req, "content-type", "application/json")
    None -> req
  }
  let req = request.set_header(req, "accept", "application/json")

  // Bearer token takes precedence over basic auth.
  let req = case db.token {
    "" -> req
    t -> request.set_header(req, "authorization", "Bearer " <> t)
  }
  let req = case db.token, db.username {
    "", "" -> req
    "", _ -> {
      let creds = db.username <> ":" <> db.password
      let encoded = base64_encode(creds)
      request.set_header(req, "authorization", "Basic " <> encoded)
    }
    _, _ -> req
  }

  let req = case body {
    Some(b) -> request.set_body(req, bit_array.from_string(b))
    None -> request.set_body(req, <<>>)
  }

  // Reject any request whose body contains a raw CRLF. HTTP request smuggling
  // relies on injecting \r\n into headers or the request line; this guard makes
  // it impossible for caller-supplied table names, SQL, or values to inject a
  // header boundary.
  use _ <- result.try(crlf_check(req))
  use resp <- result.try(send(req))
  // Cap the response: a body larger than max_response_bytes is aborted.
  let len = bit_array.byte_size(resp.body)
  case len > max_response_bytes {
    True -> Error(ResponseTooLarge)
    False -> {
      let code = resp.status
      case code < 200 || code >= 300 {
        False ->
          bit_array.to_string(resp.body)
          |> result.replace_error(Json("non-UTF-8 response body"))
        True -> {
          case bit_array.to_string(resp.body) {
            Ok(body) -> case string.starts_with(body, "not found:") {
              True -> Error(NotFound)
              False -> Error(map_status(code))
            }
            Error(_) -> Error(map_status(code))
          }
        }
      }
    }
  }
}

@external(erlang, "mongreldb_ffi", "send")
fn send(req: Request(BitArray)) -> Result(Response(BitArray), MongrelError)

@external(erlang, "mongreldb_ffi", "base64_encode")
fn base64_encode(input: String) -> String

/// `crlf_check` rejects any request string that contains a raw CR or LF, which
/// would let an attacker inject additional headers or split the request.
fn crlf_check(req: Request(BitArray)) -> Result(Nil, MongrelError) {
  let header_contains_crlf =
    list.any(req.headers, fn(h) {
      string.contains(h.1, "\r") || string.contains(h.1, "\n")
    })
  case header_contains_crlf {
    True -> Error(Query("request header contains CRLF"))
    False -> Ok(Nil)
  }
}

/// `map_status` maps an HTTP status code to a typed `MongrelError`.
fn map_status(code: Int) -> MongrelError {
  case code {
    300 | 301 | 302 | 303 | 304 | 307 | 308 -> Http("redirect")
    401 | 403 -> Auth
    402 | 409 -> Conflict
    404 -> NotFound
    n if n >= 500 && n <= 599 -> Http("server error " <> int.to_string(n))
    _ -> Query("status " <> int.to_string(code))
  }
}

/// `json_value_of_dynamic` recursively rebuilds a `json.Json` from a `Value`
/// (Dynamic). gleam_json 1.x has no `json.dynamic`, so callers that need to
/// embed a server-supplied value into an outgoing JSON payload use this to
/// re-encode it. It covers every JSON class a MongrelDB value can carry.
fn json_value_of_dynamic(v: Value) -> json.Json {
  case dynamic.classify(v) {
    "Int" -> {
      let assert Ok(n) = dynamic.int(v)
      json.int(n)
    }
    "Float" -> {
      let assert Ok(f) = dynamic.float(v)
      json.float(f)
    }
    "String" -> {
      let assert Ok(s) = dynamic.string(v)
      json.string(s)
    }
    "Bool" -> {
      let assert Ok(b) = dynamic.bool(v)
      json.bool(b)
    }
    "BitArray" -> json.null()
    "Nil" -> json.null()
    "List" -> {
      let assert Ok(items) = dynamic.list(of: dynamic.dynamic)(v)
      json.preprocessed_array(list.map(items, json_value_of_dynamic))
    }
    // JSON objects are decoded as Erlang maps, which classify as "Dict".
    "Dict" -> {
      let assert Ok(d) =
        dynamic.dict(of: dynamic.string, to: dynamic.dynamic)(v)
      json.object(
        list.map(dict.to_list(d), fn(entry) {
          #(entry.0, json_value_of_dynamic(entry.1))
        }),
      )
    }
    _ -> json.null()
  }
}

/// `json_decode` decodes a JSON string into a `Value`.
fn json_decode(body: String) -> Result(Value, MongrelError) {
  json.decode(from: body, using: dynamic.dynamic)
  |> result.replace_error(Json("malformed JSON body"))
}

// ── Cell / column helpers ─────────────────────────────────────────────────

/// `flatten_cells` converts a list of cells to the server's flat
/// `[col_id, value, ...]` JSON array in ascending column-id order.
/// Stable ordering is required for idempotency keys: the server hashes the
/// request payload, and unordered pair order would make two commits of the
/// same cells look like a reuse mismatch.
pub fn flatten_cells(cells: List(Cell)) -> List(json.Json) {
  cells
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
  |> list.flat_map(fn(c) {
    [json.int(c.id), json_value_of_dynamic(c.value)]
  })
}

/// `column_to_json` serializes a single `Column` into the JSON object the
/// daemon's `/kit/create_table` extractor recognizes.
pub fn column_to_json(c: Column) -> json.Json {
  let base = [
    #("id", json.int(c.id)),
    #("name", json.string(c.name)),
    #("ty", json.string(c.ty)),
    #("primary_key", json.bool(c.primary_key)),
    #("nullable", json.bool(c.nullable)),
  ]
  let with_enum = case c.enum_variants {
    None -> base
    Some(variants) ->
      case variants {
        [] -> base
        _ -> [
          #("enum_variants", json.array(from: variants, of: json.string)),
          ..base
        ]
      }
  }
  let with_default = case c {
    ColumnWithDefaults(default_expr: Some(expr), ..) ->
      [#("default_expr", json.string(expr)), ..with_enum]
    ColumnWithDefaults(default_value_json: Some(d), ..) ->
      [#("default_value", d), ..with_enum]
    _ ->
      case c.default_value {
        None -> with_enum
        Some(d) -> [#("default_value", json.string(d)), ..with_enum]
      }
  }
  json.object(with_default)
}

/// `column_to_json_string` serializes a `Column` to a compact JSON string.
/// Exposed so wire-shape conformance tests can assert the produced body
/// without a live daemon and without importing the internal JSON type.
pub fn column_to_json_string(c: Column) -> String {
  c
  |> column_to_json
  |> json.to_string
}

/// `normalize_condition` rewrites user-facing param names to the engine's
/// canonical condition fields.
pub fn normalize_condition(
  cond_type: String,
  params: List(#(String, Value)),
) -> List(#(String, Value)) {
  let fm_contains = cond_type == "fm_contains" || cond_type == "fm_contains_all"
  list.map(params, fn(p) {
    let key = p.0
    let name = case key {
      "column" -> "column_id"
      "min" -> "lo"
      "max" -> "hi"
      "min_inclusive" -> "lo_inclusive"
      "max_inclusive" -> "hi_inclusive"
      _ if fm_contains && key == "value" -> "pattern"
      _ -> key
    }
    #(name, p.1)
  })
}

// ── URL escaping ──────────────────────────────────────────────────────────

/// `url_path_escape` percent-escapes a path segment so table names containing
/// '/', '?', '#', or spaces cannot inject extra segments or break routing.
pub fn url_path_escape(seg: String) -> String {
  // Fast path: nothing to escape.
  let needs_escape =
    string.to_utf_codepoints(seg)
    |> list.any(fn(ch) { !is_unreserved(ch) })
  case needs_escape {
    False -> seg
    True -> {
      let chars = string.to_graphemes(seg)
      chars
      |> list.map(fn(ch) {
        case is_unreserved_grapheme(ch) {
          True -> ch
          False -> {
            // Percent-encode each byte.
            let bytes = bit_array.from_string(ch)
            bytes_to_pct(bytes)
          }
        }
      })
      |> string.concat
    }
  }
}

fn is_unreserved(ch: UtfCodepoint) -> Bool {
  let codepoint = string.utf_codepoint_to_int(ch)
  let is_upper = codepoint >= 0x41 && codepoint <= 0x5a
  let is_lower = codepoint >= 0x61 && codepoint <= 0x7a
  let is_digit = codepoint >= 0x30 && codepoint <= 0x39
  let is_dash = codepoint == 0x2d
  let is_under = codepoint == 0x5f
  let is_dot = codepoint == 0x2e
  let is_tilde = codepoint == 0x7e
  is_upper || is_lower || is_digit || is_dash || is_under || is_dot || is_tilde
}

fn is_unreserved_grapheme(ch: String) -> Bool {
  case string.to_utf_codepoints(ch) {
    [cp] -> is_unreserved(cp)
    _ -> False
  }
}

fn bytes_to_pct(bytes: BitArray) -> String {
  case bytes {
    <<>> -> ""
    <<first, rest:bytes>> -> {
      let hex = byte_to_hex(first)
      "%" <> hex <> bytes_to_pct(rest)
    }
    _ -> ""
  }
}

fn byte_to_hex(byte: Int) -> String {
  let high = int.bitwise_shift_right(byte, 4)
  let low = int.bitwise_and(byte, 15)
  nibble_to_hex(high) <> nibble_to_hex(low)
}

fn nibble_to_hex(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    9 -> "9"
    10 -> "A"
    11 -> "B"
    12 -> "C"
    13 -> "D"
    14 -> "E"
    _ -> "F"
  }
}

// ── Value constructors ────────────────────────────────────────────────────

/// `int_value` builds a JSON integer cell value.
pub fn int_value(i: Int) -> Value {
  dynamic.from(i)
}

/// `float_value` builds a JSON float cell value.
pub fn float_value(f: Float) -> Value {
  dynamic.from(f)
}

/// `string_value` builds a JSON string cell value.
pub fn string_value(s: String) -> Value {
  dynamic.from(s)
}

/// `bool_value` builds a JSON boolean cell value.
pub fn bool_value(b: Bool) -> Value {
  dynamic.from(b)
}

/// `null_value` builds a JSON null cell value.
pub fn null_value() -> Value {
  dynamic.from(Nil)
}
