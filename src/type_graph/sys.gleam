/// Platform glue. JavaScript / Node only — this project targets the
/// JS runtime so it can ship as `npx gleam-type-graph`.

import gleam/result
import simplifile

pub fn current_directory() -> Result(String, String) {
  simplifile.current_directory()
  |> result.map_error(simplifile.describe_error)
}

/// Write `content` to `<os.tmpdir()>/<filename>` and return the absolute path.
pub fn write_temp_file(filename: String, content: String) -> Result(String, String) {
  do_write_temp_file(filename, content)
}

/// Best-effort: open `path` in the host's default app (browser for .html etc).
pub fn open_in_browser(path: String) -> Result(Nil, String) {
  do_open_in_browser(path)
}

@external(javascript, "../type_graph_ffi.mjs", "writeTempFile")
fn do_write_temp_file(filename: String, content: String) -> Result(String, String)

@external(javascript, "../type_graph_ffi.mjs", "openInBrowser")
fn do_open_in_browser(path: String) -> Result(Nil, String)
