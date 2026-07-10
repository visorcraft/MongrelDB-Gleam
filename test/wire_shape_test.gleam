// Wire-shape conformance tests for the mongreldb Gleam client.
//
// These are pure (no daemon required): they serialize a `Column` via
// `column_to_json_string`, and assert the exact keys + values appear in the
// outgoing JSON body. They guard the ergonomic extension that adds
// `enum_variants` and `default_value` keys to the per-column payload that
// `/kit/create_table` accepts. A future regression that drops either key would
// silently break user schemas, so the wire shape is asserted here.

import gleam/option.{None, Some}
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
