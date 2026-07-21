// Wire-shape conformance tests for the mongreldb Gleam client.
//
// These are pure (no daemon required): they serialize a `Column` via
// `column_to_json_string`, and assert the exact keys + values appear in the
// outgoing JSON body. They guard the ergonomic extension that adds
// `enum_variants` and `default_value` keys to the per-column payload that
// `/kit/create_table` accepts. A future regression that drops either key would
// silently break user schemas, so the wire shape is asserted here.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/json
import gleam/string
import gleeunit
import gleeunit/should

import mongreldb

pub fn main() {
  gleeunit.main()
}

fn render(col: mongreldb.Column) -> String {
  mongreldb.column_to_json_string(col)
}

pub fn column_to_json_emits_enum_and_default_test() {
  let col =
    mongreldb.Column(
      id: 1,
      name: "color",
      ty: "string",
      primary_key: False,
      nullable: False,
      enum_variants: Some(["a", "b"]),
      default_value: Some("a"),
    )
  let s = render(col)
  string.contains(s, "\"enum_variants\":[\"a\",\"b\"]") |> should.be_true
  string.contains(s, "\"default_value\":\"a\"") |> should.be_true
}

pub fn column_to_json_emits_scalar_and_expression_defaults_test() {
  let scalar =
    mongreldb.ColumnWithDefaults(
      id: 4,
      name: "attempts",
      ty: "int64",
      primary_key: False,
      nullable: False,
      enum_variants: None,
      default_value: Some("legacy"),
      default_value_json: Some(json.int(3)),
      default_expr: None,
    )
  let scalar_s = render(scalar)
  string.contains(scalar_s, "\"default_value\":3") |> should.be_true
  let expr =
    mongreldb.ColumnWithDefaults(
      id: 4,
      name: "attempts",
      ty: "int64",
      primary_key: False,
      nullable: False,
      enum_variants: None,
      default_value: Some("legacy"),
      default_value_json: Some(json.int(3)),
      default_expr: Some("uuid"),
    )
  let expr_s = render(expr)
  string.contains(expr_s, "\"default_expr\":\"uuid\"") |> should.be_true
  string.contains(expr_s, "default_value") |> should.be_false
  let base = fn(value) {
    mongreldb.ColumnWithDefaults(id: 5, name: "x", ty: "string", primary_key: False, nullable: True, enum_variants: None, default_value: None, default_value_json: Some(value), default_expr: None)
  }
  string.contains(render(base(json.string("draft"))), "\"default_value\":\"draft\"") |> should.be_true
  string.contains(render(base(json.bool(True))), "\"default_value\":true") |> should.be_true
  string.contains(render(base(json.null())), "\"default_value\":null") |> should.be_true
}

pub fn column_to_json_omits_absent_enum_and_default_test() {
  let col =
    mongreldb.Column(
      id: 2,
      name: "amount",
      ty: "int64",
      primary_key: True,
      nullable: False,
      enum_variants: None,
      default_value: None,
    )
  let s = render(col)
  // Both keys must be absent so the wire shape matches the baseline.
  string.contains(s, "enum_variants") |> should.be_false
  string.contains(s, "default_value") |> should.be_false
  string.contains(s, "\"primary_key\":true") |> should.be_true
  string.contains(s, "\"nullable\":false") |> should.be_true
}

pub fn column_to_json_omits_empty_enum_test() {
  let col =
    mongreldb.Column(
      id: 3,
      name: "label",
      ty: "string",
      primary_key: False,
      nullable: False,
      enum_variants: Some([]),
      default_value: Some("x"),
    )
  let s = render(col)
  // An explicit empty slice should not be emitted.
  string.contains(s, "enum_variants") |> should.be_false
  string.contains(s, "\"default_value\":\"x\"") |> should.be_true
}

// ── History retention wire shape ────────────────────────────────────────────

pub fn history_retention_request_body_test() {
  mongreldb.history_retention_request_body(250)
  |> should.equal("{\"history_retention_epochs\":250}")
}

pub fn history_retention_response_parse_valid_test() {
  mongreldb.history_retention_response_parse(
    "{\"history_retention_epochs\":100,\"earliest_retained_epoch\":5}",
  )
  |> should.equal(Ok(#(100, 5)))
}

pub fn history_retention_response_parse_missing_key_test() {
  mongreldb.history_retention_response_parse(
    "{\"history_retention_epochs\":100}",
  )
  |> should.be_error
}

pub fn history_retention_response_parse_extra_key_test() {
  mongreldb.history_retention_response_parse(
    "{\"history_retention_epochs\":100,\"earliest_retained_epoch\":5,\"extra\":1}",
  )
  |> should.be_error
}

pub fn history_retention_response_parse_non_integer_test() {
  mongreldb.history_retention_response_parse(
    "{\"history_retention_epochs\":\"100\",\"earliest_retained_epoch\":5}",
  )
  |> should.be_error
}

// ── Transport-level retention tests ─────────────────────────────────────────
//
// The payload and parser tests above exercise the JSON helpers in isolation.
// These tests drive the client's real `set_history_retention_epochs` and
// `history_retention` functions through the HTTP transport (`raw_request` ->
// `send` -> Erlang `httpc`) against an in-process mock TCP server (provided
// by `mongreldb_ffi`), so we can assert the actual on-wire method, the
// `/history/retention` path, the PUT body key, the GET response keys, and the
// propagation of a non-2xx response to a typed `MongrelError`. The mock uses
// only Erlang/OTP built-ins - no new dependency.

@external(erlang, "mongreldb_ffi", "start_mock_server")
fn start_mock_server() -> Result(Int, Nil)

@external(erlang, "mongreldb_ffi", "stop_mock_server")
fn stop_mock_server() -> Nil

@external(erlang, "mongreldb_ffi", "set_mock_response")
fn set_mock_response(status: Int, body: String) -> Nil

@external(erlang, "mongreldb_ffi", "last_mock_request")
fn last_mock_request() -> Result(#(String, String, String), Nil)

/// `mock_url` builds the base URL the mongreldb client should target to reach
/// the mock on its assigned port.
fn mock_url(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port)
}

pub fn create_table_ann_backend_options_test() {
  let assert Ok(port) = start_mock_server()
  set_mock_response(200, "{\"table_id\":1}")
  let assert Ok(db) =
    mongreldb.connect(mock_url(port), mongreldb.Options(token: "", username: "", password: ""))
  let ann = json.object([
    #("algorithm", json.string("diskann")),
    #("quantization", json.string("dense")),
    #("diskann", json.object([
      #("r", json.int(64)), #("l", json.int(128)),
      #("beam_width", json.int(8)), #("alpha", json.int(120)),
    ])),
  ])
  let index = json.object([
    #("name", json.string("ann")), #("column_id", json.int(2)),
    #("kind", json.string("ann")), #("options", json.object([#("ann", ann)])),
  ])
  let assert Ok(1) = mongreldb.create_table_with_schema(db, "vectors", [], None, [index])
  let assert Ok(#(_, _, body)) = last_mock_request()
  should.be_true(string.contains(body, "\"algorithm\":\"diskann\""))
  should.be_true(string.contains(body, "\"quantization\":\"dense\""))
  should.be_true(string.contains(body, "\"beam_width\":8"))
  stop_mock_server()
}

pub fn history_retention_transport_get_test() {
  let assert Ok(port) = start_mock_server()
  set_mock_response(
    200,
    "{\"history_retention_epochs\":250,\"earliest_retained_epoch\":5}",
  )
  let assert Ok(db) =
    mongreldb.connect(mock_url(port), mongreldb.Options(token: "", username: "", password: ""))
  let assert Ok(#(epochs, earliest)) = mongreldb.history_retention(db)
  should.equal(epochs, 250)
  should.equal(earliest, 5)
  let assert Ok(#(method, path, _body)) = last_mock_request()
  should.equal(method, "GET")
  should.be_true(string.contains(path, "/history/retention"))
  stop_mock_server()
}

pub fn history_retention_transport_put_test() {
  let assert Ok(port) = start_mock_server()
  set_mock_response(
    200,
    "{\"history_retention_epochs\":2048,\"earliest_retained_epoch\":7}",
  )
  let assert Ok(db) =
    mongreldb.connect(mock_url(port), mongreldb.Options(token: "", username: "", password: ""))
  let assert Ok(#(epochs, earliest)) =
    mongreldb.set_history_retention_epochs(db, 2048)
  should.equal(epochs, 2048)
  should.equal(earliest, 7)
  let assert Ok(#(method, path, body)) = last_mock_request()
  should.equal(method, "PUT")
  should.be_true(string.contains(path, "/history/retention"))
  // The PUT body must carry the single key the server reads.
  should.be_true(string.contains(body, "\"history_retention_epochs\":2048"))
  stop_mock_server()
}

pub fn history_retention_transport_non_2xx_test() {
  let assert Ok(port) = start_mock_server()
  // 500 maps to MongrelError.Http in map_status.
  set_mock_response(500, "{\"error\":{\"message\":\"boom\"}}")
  let assert Ok(db) =
    mongreldb.connect(mock_url(port), mongreldb.Options(token: "", username: "", password: ""))
  let result = mongreldb.history_retention(db)
  should.be_error(result)
  let assert Error(err) = result
  should.be_true(is_http_error(err))
  stop_mock_server()
}

pub fn history_retention_transport_404_test() {
  let assert Ok(port) = start_mock_server()
  // 404 maps to MongrelError.NotFound.
  set_mock_response(404, "{\"error\":{\"message\":\"no such setting\"}}")
  let assert Ok(db) =
    mongreldb.connect(mock_url(port), mongreldb.Options(token: "", username: "", password: ""))
  let result = mongreldb.set_history_retention_epochs(db, 1)
  should.be_error(result)
  let assert Error(err) = result
  should.be_true(is_not_found(err))
  stop_mock_server()
}

/// `is_http_error` narrows a `MongrelError` to the `Http` variant.
fn is_http_error(err: mongreldb.MongrelError) -> Bool {
  case err {
    mongreldb.Http(_) -> True
    _ -> False
  }
}

fn is_not_found(err: mongreldb.MongrelError) -> Bool {
  case err {
    mongreldb.NotFound -> True
    _ -> False
  }
}

// ── Full static-default matrix ──────────────────────────────────────────────

fn defaults_col(
  id id: Int,
  name name: String,
  default_value_json default_value_json: Option(json.Json),
  default_expr default_expr: Option(String),
) -> mongreldb.Column {
  mongreldb.ColumnWithDefaults(
    id: id,
    name: name,
    ty: "varchar",
    primary_key: False,
    nullable: True,
    enum_variants: None,
    default_value: Some("legacy"),
    default_value_json: default_value_json,
    default_expr: default_expr,
  )
}

pub fn column_to_json_full_static_default_matrix_test() {
  let string_col = defaults_col(2, "label", Some(json.string("draft")), None)
  let int_col = defaults_col(3, "qty", Some(json.int(7)), None)
  let bool_col = defaults_col(4, "active", Some(json.bool(True)), None)
  let null_col = defaults_col(5, "notes", Some(json.null()), None)
  let literal_now_col = defaults_col(6, "created", Some(json.string("now")), None)
  let expr_col = defaults_col(7, "updated", None, Some("now"))

  string.contains(render(string_col), "\"default_value\":\"draft\"") |> should.be_true
  string.contains(render(int_col), "\"default_value\":7") |> should.be_true
  string.contains(render(bool_col), "\"default_value\":true") |> should.be_true
  string.contains(render(null_col), "\"default_value\":null") |> should.be_true
  string.contains(render(literal_now_col), "\"default_value\":\"now\"") |> should.be_true

  let expr_s = render(expr_col)
  string.contains(expr_s, "\"default_expr\":\"now\"") |> should.be_true
  string.contains(expr_s, "default_value") |> should.be_false
}

pub fn column_to_json_default_expr_takes_precedence_test() {
  // When default_expr is set, the legacy/default_value_json fields are ignored.
  let col =
    mongreldb.ColumnWithDefaults(
      id: 8,
      name: "uuid_col",
      ty: "varchar",
      primary_key: False,
      nullable: True,
      enum_variants: None,
      default_value: Some("legacy"),
      default_value_json: Some(json.string("ignored")),
      default_expr: Some("uuid"),
    )
  let s = render(col)
  string.contains(s, "\"default_expr\":\"uuid\"") |> should.be_true
  string.contains(s, "default_value") |> should.be_false
}
