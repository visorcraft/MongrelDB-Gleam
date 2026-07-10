// Test entry point for gleeunit. Gleam's `gleam test` runs the module named
// after the package (`mongreldb_test`), whose `main` boots the gleeunit runner.
// gleeunit auto-discovers every `*_test.gleam` module in `test/` and runs the
// `*_test()` functions inside it.
import gleeunit

pub fn main() {
  gleeunit.main()
}
