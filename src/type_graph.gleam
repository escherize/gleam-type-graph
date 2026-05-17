import argv
import filepath
import gleam/io
import gleam/list
import gleam/dict
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import simplifile
import type_graph/collapse
import type_graph/extract
import type_graph/filter
import type_graph/graph
import type_graph/parse
import type_graph/render
import type_graph/sys
import type_graph/theme

pub fn main() -> Nil {
  let args = argv.load().arguments
  case parse_cli(args) {
    Error(msg) -> {
      io.println_error(msg)
      io.println_error("")
      io.println_error(usage())
    }
    Ok(Help) -> io.println(usage())
    Ok(Run(cfg)) -> run(cfg)
  }
}

// ---------------------------------------------------------------------------
// CLI

type CollapseMode {
  NoCollapse
  CollapseModules
}

type Config {
  Config(
    /// None = autodetect from cwd (walk up looking for gleam.toml).
    src: Option(String),
    /// User-specified format. None means "use the default for the chosen
    /// output channel" — html when --open is set, mermaid otherwise.
    format: Option(render.Format),
    /// Render the graph to a temp file and try to open it in the browser.
    open: Bool,
    /// Optional graph-level collapse before rendering.
    collapse: CollapseMode,
    /// Color palette for HTML / mermaid output.
    theme: theme.Theme,
    options: filter.Options,
  )
}

type Action {
  Help
  Run(Config)
}

fn default_config() -> Config {
  Config(
    src: None,
    format: None,
    open: False,
    collapse: NoCollapse,
    theme: theme.dark(),
    options: filter.default_options(),
  )
}

fn usage() -> String {
  "Usage: gleam-type-graph [PATH] [OPTIONS]

Build a directed graph of types and the functions that transform them.

Arguments:
  PATH                Directory to scan. If omitted, walks up from cwd
                      looking for gleam.toml and uses its src/.

Options:
  --format <FMT>      Output format: mermaid|dot|json|text|html
                      (default: html when --open, mermaid otherwise)
  --open              Render to a temp file and open in your browser
  --collapse <MODE>   Collapse the graph. Modes: modules
  --theme <NAME>      Color palette for HTML: dark (default) or light
  --include <PAT>     Module substring to include (repeatable)
  --exclude <PAT>     Module substring to exclude (repeatable)
  --domain-only       Drop edges touching stdlib / primitives
  -h, --help          Show this help"
}

fn parse_cli(args: List(String)) -> Result(Action, String) {
  do_parse_cli(args, default_config(), False)
}

fn do_parse_cli(
  args: List(String),
  cfg: Config,
  saw_path: Bool,
) -> Result(Action, String) {
  case args {
    [] -> Ok(Run(cfg))
    ["-h", ..] | ["--help", ..] -> Ok(Help)
    ["--domain-only", ..rest] -> {
      let opts = filter.Options(..cfg.options, domain_only: True)
      do_parse_cli(rest, Config(..cfg, options: opts), saw_path)
    }
    ["--open", ..rest] ->
      do_parse_cli(rest, Config(..cfg, open: True), saw_path)
    [arg, ..rest] -> {
      case split_eq(arg) {
        Ok(#(flag, value)) -> handle_flag(flag, value, rest, cfg, saw_path)
        Error(_) ->
          case arg {
            "--format" -> consume_value(arg, rest, cfg, saw_path, set_format)
            "--collapse" ->
              consume_value(arg, rest, cfg, saw_path, set_collapse)
            "--theme" -> consume_value(arg, rest, cfg, saw_path, set_theme)
            "--include" ->
              consume_value(arg, rest, cfg, saw_path, fn(c, v) {
                Ok(
                  Config(
                    ..c,
                    options: filter.Options(
                      ..c.options,
                      include_modules: [v, ..c.options.include_modules],
                    ),
                  ),
                )
              })
            "--exclude" ->
              consume_value(arg, rest, cfg, saw_path, fn(c, v) {
                Ok(
                  Config(
                    ..c,
                    options: filter.Options(
                      ..c.options,
                      exclude_modules: [v, ..c.options.exclude_modules],
                    ),
                  ),
                )
              })
            _ ->
              case string.starts_with(arg, "--") {
                True -> Error("unknown flag: " <> arg)
                False ->
                  case saw_path {
                    True -> Error("unexpected positional argument: " <> arg)
                    False ->
                      do_parse_cli(rest, Config(..cfg, src: Some(arg)), True)
                  }
              }
          }
      }
    }
  }
}

fn handle_flag(
  flag: String,
  value: String,
  rest: List(String),
  cfg: Config,
  saw_path: Bool,
) -> Result(Action, String) {
  case flag {
    "--format" ->
      case set_format(cfg, value) {
        Ok(cfg) -> do_parse_cli(rest, cfg, saw_path)
        Error(e) -> Error(e)
      }
    "--collapse" ->
      case set_collapse(cfg, value) {
        Ok(cfg) -> do_parse_cli(rest, cfg, saw_path)
        Error(e) -> Error(e)
      }
    "--theme" ->
      case set_theme(cfg, value) {
        Ok(cfg) -> do_parse_cli(rest, cfg, saw_path)
        Error(e) -> Error(e)
      }
    "--include" -> {
      let opts =
        filter.Options(
          ..cfg.options,
          include_modules: [value, ..cfg.options.include_modules],
        )
      do_parse_cli(rest, Config(..cfg, options: opts), saw_path)
    }
    "--exclude" -> {
      let opts =
        filter.Options(
          ..cfg.options,
          exclude_modules: [value, ..cfg.options.exclude_modules],
        )
      do_parse_cli(rest, Config(..cfg, options: opts), saw_path)
    }
    _ -> Error("unknown flag: " <> flag)
  }
}

fn set_format(cfg: Config, v: String) -> Result(Config, String) {
  use fmt <- result.map(render.parse_format(v))
  Config(..cfg, format: Some(fmt))
}

fn set_collapse(cfg: Config, v: String) -> Result(Config, String) {
  case v {
    "modules" -> Ok(Config(..cfg, collapse: CollapseModules))
    "none" | "" -> Ok(Config(..cfg, collapse: NoCollapse))
    other -> Error("unknown collapse mode: " <> other)
  }
}

fn set_theme(cfg: Config, v: String) -> Result(Config, String) {
  use t <- result.map(theme.parse(v))
  Config(..cfg, theme: t)
}

fn consume_value(
  flag: String,
  rest: List(String),
  cfg: Config,
  saw_path: Bool,
  apply: fn(Config, String) -> Result(Config, String),
) -> Result(Action, String) {
  case rest {
    [v, ..tail] ->
      case apply(cfg, v) {
        Ok(c) -> do_parse_cli(tail, c, saw_path)
        Error(e) -> Error(e)
      }
    [] -> Error(flag <> " expects a value")
  }
}

fn split_eq(arg: String) -> Result(#(String, String), Nil) {
  case string.starts_with(arg, "--") {
    False -> Error(Nil)
    True ->
      case string.split_once(arg, "=") {
        Ok(#(k, v)) -> Ok(#(k, v))
        Error(_) -> Error(Nil)
      }
  }
}

// ---------------------------------------------------------------------------
// Pipeline

fn run(cfg: Config) -> Nil {
  let format = option.unwrap(cfg.format, default_format(cfg))
  case resolve_src(cfg.src) {
    Error(msg) -> io.println_error(msg)
    Ok(src) ->
      case parse.parse_directory(src) {
        Error(err) ->
          io.println_error(
            "failed to read " <> src <> ": " <> simplifile.describe_error(err),
          )
        Ok(#(modules, errors)) -> {
          list.each(errors, fn(e) {
            io.println_error("warning: " <> describe_parse_error(e))
          })
          let edges =
            list.flat_map(modules, fn(m) { extract.from_module(m.name, m.ast) })
          let analyzed_modules =
            modules |> list.map(fn(m) { m.name }) |> set.from_list
          // A node is "internal" (for both link routing and visual styling)
          // if it falls into either bucket:
          //   - explicitly annotated `@internal`
          //   - sitting inside a conventionally-internal module path
          //     (`<pkg>/internal` or `<pkg>/internal/...`)
          // Both produce dead hex anchors and benefit from the github
          // source fallback + dashed-border rendering.
          let attr_internal_ids =
            modules
            |> list.flat_map(fn(m) {
              extract.internal_node_ids(m.name, m.ast)
            })
            |> set.from_list
          let module_internal_ids =
            modules
            |> list.filter(fn(m) { is_likely_internal(m.name) })
            |> list.flat_map(fn(m) { extract.pub_node_ids(m.name, m.ast) })
            |> set.from_list
          // `internal_ids` = either bucket; used for hex-skip + dashed
          // styling. `attr_internal_ids` (subset) is used only to decide
          // whether the github link should be a 2-line range covering
          // the @internal annotation line above.
          let internal_ids = set.union(attr_internal_ids, module_internal_ids)
          // Source line numbers per node, for the github-source fallback
          // when hex hides a node.
          let source_locs =
            list.fold(modules, dict.new(), fn(acc, m) {
              dict.merge(
                acc,
                extract.source_locations(m.name, m.ast, m.source),
              )
            })
          // Short type-alias bodies, displayed inline under the alias name.
          let alias_bodies =
            list.fold(modules, dict.new(), fn(acc, m) {
              dict.merge(acc, extract.type_alias_bodies(m.name, m.ast))
            })
          let repo = read_repo(src)
          let filtered = filter.apply(edges, cfg.options, analyzed_modules)
          let kept = case cfg.collapse {
            NoCollapse -> filtered
            CollapseModules -> collapse.modules(filtered)
          }
          case kept {
            [] -> {
              let summary = case edges {
                [] -> "no public functions with typed signatures found"
                _ -> "filters dropped every edge — try relaxing them"
              }
              io.println_error("nothing to render: " <> summary)
            }
            _ -> {
              let project = derive_project_name(src)
              case cfg.collapse, format {
                CollapseModules, render.Html -> {
                  let html =
                    build_multi_view_html(
                      project,
                      src,
                      kept,
                      filtered,
                      analyzed_modules,
                      internal_ids,
                      attr_internal_ids,
                      source_locs,
                      alias_bodies,
                      repo,
                      cfg.theme,
                    )
                  deliver_or_print(html, format, cfg.open)
                }
                _, render.Html -> {
                  let href_for =
                    link_href(
                      project,
                      analyzed_modules,
                      internal_ids,
                      attr_internal_ids,
                      source_locs,
                      repo,
                      False,
                    )
                  let html =
                    render.render_html_single(
                      project,
                      src,
                      kept,
                      href_for,
                      internal_ids,
                      alias_bodies,
                      cfg.theme,
                    )
                  deliver_or_print(html, format, cfg.open)
                }
                _, _ -> {
                  let output = render.render(kept, format)
                  deliver_or_print(output, format, cfg.open)
                }
              }
            }
          }
        }
      }
  }
}

fn default_format(cfg: Config) -> render.Format {
  case cfg.open {
    True -> render.Html
    False -> render.Mermaid
  }
}

fn deliver_or_print(output: String, format: render.Format, open: Bool) -> Nil {
  case open {
    True -> deliver_open(output, format)
    False -> io.println(output)
  }
}

/// Build a multi-view HTML page: a collapsed overview with click handlers
/// on each module bubble, plus one focused view per module containing that
/// module's neighborhood (its types + fan-in nodes + edges in/out).
fn build_multi_view_html(
  project: String,
  source_path: String,
  collapsed_edges: List(graph.Edge),
  full_edges: List(graph.Edge),
  analyzed: set.Set(String),
  internal_ids: set.Set(String),
  attr_internal_ids: set.Set(String),
  source_locs: dict.Dict(String, Int),
  alias_bodies: dict.Dict(String, String),
  repo: Option(GithubRepo),
  current_theme: theme.Theme,
) -> String {
  let modules = analyzed |> set.to_list |> list.sort(string.compare)
  let overview_href =
    link_href(
      project,
      analyzed,
      internal_ids,
      attr_internal_ids,
      source_locs,
      repo,
      True,
    )
  let focused_href =
    link_href(
      project,
      analyzed,
      internal_ids,
      attr_internal_ids,
      source_locs,
      repo,
      False,
    )
  let overview =
    render.View(
      id: "overview",
      title: "Overview",
      mermaid: render.render_mermaid_with_clicks(
        collapsed_edges,
        overview_href,
        internal_ids,
        alias_bodies,
        current_theme,
      ),
    )
  let module_views =
    list.map(modules, fn(m) {
      let module_edges =
        list.filter(full_edges, fn(e) { edge_touches_module(e, m) })
      render.View(
        id: view_id_for(m),
        title: m,
        mermaid: render.render_mermaid_focused_with_clicks(
          module_edges,
          m,
          focused_href,
          internal_ids,
          alias_bodies,
          current_theme,
        ),
      )
    })
  render.render_html_views(
    project,
    source_path,
    [overview, ..module_views],
    "overview",
    current_theme,
  )
}

pub type GithubRepo {
  GithubRepo(user: String, repo: String)
}

/// Build the click-href callback for mermaid nodes.
///
/// Decision order per node:
///
/// 1. Collapsed module bubble (`Qualified(_, "*")`) with drill-in enabled
///    → `#module_<id>` fragment (in-page navigation).
/// 2. Node in an analyzed module that *is* documented on hex (module path
///    isn't conventionally internal, function/type isn't `@internal`) →
///    `https://hexdocs.pm/<project>/<module>.html#<name>`.
/// 3. Same as 2 but hex would 404 (internal module or `@internal` node)
///    AND we have a github repo for the package AND a source line for
///    the node → `https://github.com/<user>/<repo>/blob/main/src/<module>.gleam#L<line>`.
///    For `@internal` nodes we link to `#L<line-1>-L<line>` so the
///    reader sees the annotation line above the signature.
/// 4. Anything else (external types, primitives, generics) → no link.
fn link_href(
  project: String,
  analyzed: set.Set(String),
  internal_ids: set.Set(String),
  attr_internal_ids: set.Set(String),
  source_locs: dict.Dict(String, Int),
  repo: Option(GithubRepo),
  enable_module_drill_in: Bool,
) -> fn(graph.TypeRef) -> Option(String) {
  fn(ref: graph.TypeRef) -> Option(String) {
    case ref {
      graph.Qualified(module, "*") ->
        case enable_module_drill_in && set.contains(analyzed, module) {
          True -> Some("#" <> view_id_for(module))
          False -> None
        }
      graph.Qualified(module, name) ->
        link_for_named(
          project,
          analyzed,
          internal_ids,
          attr_internal_ids,
          source_locs,
          repo,
          module,
          name,
          ref,
        )
      graph.FanIn(module, name, _, _) ->
        link_for_named(
          project,
          analyzed,
          internal_ids,
          attr_internal_ids,
          source_locs,
          repo,
          module,
          name,
          ref,
        )
      _ -> None
    }
  }
}

fn link_for_named(
  project: String,
  analyzed: set.Set(String),
  internal_ids: set.Set(String),
  attr_internal_ids: set.Set(String),
  source_locs: dict.Dict(String, Int),
  repo: Option(GithubRepo),
  module: String,
  name: String,
  ref: graph.TypeRef,
) -> Option(String) {
  let in_analyzed = set.contains(analyzed, module)
  let is_internal = set.contains(internal_ids, graph.type_id(ref))
  // For github link line ranges: only `@internal`-annotated nodes get the
  // `L<n-1>-L<n>` form (because line n-1 actually has the @internal
  // annotation). Path-only-internal nodes use plain `L<n>` — line n-1
  // could be anything (blank line, end of a previous function).
  let has_attr_internal = set.contains(attr_internal_ids, graph.type_id(ref))
  let hex_ok = project != "" && in_analyzed && !is_internal
  case hex_ok {
    True -> Some(hex_url(project, module, name))
    False ->
      case in_analyzed && is_internal {
        True ->
          github_source_url(repo, source_locs, ref, module, has_attr_internal)
        False -> None
      }
  }
}

fn github_source_url(
  repo: Option(GithubRepo),
  source_locs: dict.Dict(String, Int),
  ref: graph.TypeRef,
  module: String,
  is_internal_annotated: Bool,
) -> Option(String) {
  case repo, dict.get(source_locs, graph.type_id(ref)) {
    Some(GithubRepo(user, repo_name)), Ok(line) -> {
      // For `@internal`-annotated nodes the annotation lives one line above
      // the `pub fn` / `pub type`. Range the link so the reader sees both.
      let frag = case is_internal_annotated && line > 1 {
        True ->
          "L" <> int.to_string(line - 1) <> "-L" <> int.to_string(line)
        False -> "L" <> int.to_string(line)
      }
      Some(
        "https://github.com/"
        <> user
        <> "/"
        <> repo_name
        <> "/blob/main/src/"
        <> module
        <> ".gleam#"
        <> frag,
      )
    }
    _, _ -> None
  }
}

/// Convention: modules whose path contains `/internal/` or ends in
/// `/internal` are private. Gleam's doc generator hides them from hex docs,
/// so linking to them produces a 404. This is heuristic — the authoritative
/// list lives in the package's `gleam.toml` under `[documentation]
/// internal_modules = [...]`, but parsing toml from the analyzed package
/// isn't currently in scope. See worklog.md for the deferred precise fix.
fn is_likely_internal(module: String) -> Bool {
  string.contains(module, "/internal/")
  || string.ends_with(module, "/internal")
}

fn hex_url(package: String, module: String, name: String) -> String {
  "https://hexdocs.pm/" <> package <> "/" <> module <> ".html#" <> name
}

/// Read the analyzed package's `gleam.toml` and extract its github
/// repository declaration. Returns `None` when there is no gleam.toml,
/// it's unreadable, or it doesn't declare a github repo. We do a
/// targeted string scan rather than a real toml parse — gleam_stdlib
/// doesn't ship a toml lib and `repository = { ... }` is one stable
/// one-line form in practice.
fn read_repo(src_dir: String) -> Option(GithubRepo) {
  let toml_path = case find_project_root(src_dir) {
    Some(root) -> Some(filepath.join(root, "gleam.toml"))
    None ->
      // fall back: src_dir parent
      Some(filepath.join(filepath.directory_name(src_dir), "gleam.toml"))
  }
  case toml_path {
    Some(path) ->
      case simplifile.read(path) {
        Ok(contents) -> parse_repo_line(contents)
        Error(_) -> None
      }
    None -> None
  }
}

fn parse_repo_line(toml: String) -> Option(GithubRepo) {
  // Find the `repository` line and pull `user`/`repo` strings out of it.
  let lines = string.split(toml, "\n")
  let repo_line =
    list.find(lines, fn(line) {
      string.starts_with(string.trim_start(line), "repository")
        && string.contains(line, "github")
    })
  case repo_line {
    Ok(line) -> {
      // Split on `,` so each key/value sits in its own piece. Otherwise
      // a substring match for `"repo"` collides with `"repository"` at
      // the start of the line.
      let pieces = string.split(line, ",")
      case piece_value(pieces, "user"), piece_value(pieces, "repo") {
        Some(user), Some(repo) -> Some(GithubRepo(user, repo))
        _, _ -> None
      }
    }
    Error(_) -> None
  }
}

/// Find the first piece whose key (token before `=`, trimmed) equals
/// `key`, then extract its quoted value.
fn piece_value(pieces: List(String), key: String) -> Option(String) {
  let found =
    list.find(pieces, fn(p) {
      case string.split(string.trim(p), "=") {
        [k, ..] -> string.trim(k) == key
        _ -> False
      }
    })
  case found {
    Ok(piece) -> extract_quoted(piece)
    Error(_) -> None
  }
}

fn extract_quoted(s: String) -> Option(String) {
  case string.split_once(s, "\"") {
    Ok(#(_, after_quote)) ->
      case string.split_once(after_quote, "\"") {
        Ok(#(value, _)) -> Some(value)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

/// Friendly project name from a source path: strip a trailing `/src` and
/// take the last segment. So `/foo/bar/lustre/src` → `"lustre"`,
/// `./src` (cwd autodetect) reduces to the project dir name.
fn derive_project_name(src: String) -> String {
  let trimmed = case string.ends_with(src, "/src") {
    True -> string.drop_end(src, 4)
    False -> case string.ends_with(src, "/src/") {
      True -> string.drop_end(src, 5)
      False -> src
    }
  }
  let segments = filepath.split(trimmed)
  case list.last(segments) {
    Ok(seg) if seg != "" && seg != "." && seg != "/" -> seg
    _ -> trimmed
  }
}

fn view_id_for(module: String) -> String {
  "module_"
  <> string.replace(module, "/", "_")
  |> string.replace("-", "_")
}

fn edge_touches_module(e: graph.Edge, module: String) -> Bool {
  let graph.Edge(from, to, _) = e
  ref_in_module(from, module) || ref_in_module(to, module)
}

fn ref_in_module(t: graph.TypeRef, module: String) -> Bool {
  case t {
    graph.Qualified(m, _) -> m == module
    graph.FanIn(m, _, _, _) -> m == module
    _ -> False
  }
}

fn deliver_open(content: String, format: render.Format) -> Nil {
  let filename = "type-graph." <> render.extension(format)
  case sys.write_temp_file(filename, content) {
    Error(msg) -> io.println_error("failed to write temp file: " <> msg)
    Ok(path) -> {
      io.println_error("Opening " <> path)
      case sys.open_in_browser(path) {
        Ok(_) -> Nil
        Error(msg) -> {
          io.println_error("could not open browser: " <> msg)
          io.println_error("file is at: " <> path)
        }
      }
    }
  }
}

/// Resolve the directory we should scan.
///
/// - If the user passed a path, use it.
/// - Otherwise walk up from cwd looking for a `gleam.toml`; use its `src/`.
/// - Otherwise fall back to `./src` and let the read fail with a clear error.
fn resolve_src(arg: Option(String)) -> Result(String, String) {
  case arg {
    Some(path) -> Ok(path)
    None ->
      case sys.current_directory() {
        Error(_) -> Ok("src")
        Ok(cwd) ->
          case find_project_root(cwd) {
            Some(root) -> Ok(filepath.join(root, "src"))
            None -> Ok("src")
          }
      }
  }
}

fn find_project_root(dir: String) -> Option(String) {
  case simplifile.is_file(filepath.join(dir, "gleam.toml")) {
    Ok(True) -> Some(dir)
    _ -> {
      let parent = filepath.directory_name(dir)
      case parent == dir || parent == "" {
        True -> None
        False -> find_project_root(parent)
      }
    }
  }
}

fn describe_parse_error(err: parse.ParseError) -> String {
  case err {
    parse.ReadFailed(path, reason) ->
      "could not read " <> path <> ": " <> simplifile.describe_error(reason)
    parse.ParseFailed(path, _) -> "could not parse " <> path
  }
}
