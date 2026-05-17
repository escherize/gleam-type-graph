import filepath
import glance
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub type ParsedModule {
  ParsedModule(name: String, path: String, ast: glance.Module, source: String)
}

pub type ParseError {
  ReadFailed(path: String, reason: simplifile.FileError)
  ParseFailed(path: String, reason: glance.Error)
}

/// Walk `root` recursively, parse every `.gleam` file, return the parsed
/// modules. Each module's `name` is its path relative to `root`, with the
/// `.gleam` suffix stripped — so `<root>/foo/bar.gleam` becomes `foo/bar`.
pub fn parse_directory(
  root: String,
) -> Result(#(List(ParsedModule), List(ParseError)), simplifile.FileError) {
  use files <- result.map(simplifile.get_files(root))
  let gleam_files = list.filter(files, is_gleam_file)
  list.fold(gleam_files, #([], []), fn(acc, path) {
    let #(ok, errs) = acc
    case parse_file(path, root) {
      Ok(m) -> #([m, ..ok], errs)
      Error(e) -> #(ok, [e, ..errs])
    }
  })
}

fn is_gleam_file(path: String) -> Bool {
  string.ends_with(path, ".gleam")
}

fn parse_file(path: String, root: String) -> Result(ParsedModule, ParseError) {
  use src <- result.try(
    simplifile.read(path) |> result.map_error(ReadFailed(path, _)),
  )
  use ast <- result.map(
    glance.module(src) |> result.map_error(ParseFailed(path, _)),
  )
  ParsedModule(
    name: module_name(path, root),
    path: path,
    ast: ast,
    source: src,
  )
}

fn module_name(path: String, root: String) -> String {
  let trimmed = case string.starts_with(path, root) {
    True -> string.drop_start(path, string.length(root))
    False -> path
  }
  let trimmed = case string.starts_with(trimmed, "/") {
    True -> string.drop_start(trimmed, 1)
    False -> trimmed
  }
  let without_ext = case string.ends_with(trimmed, ".gleam") {
    True -> string.drop_end(trimmed, 6)
    False -> trimmed
  }
  // Some platforms may return paths with backslashes; normalise.
  filepath.split(without_ext) |> string.join("/")
}
