import gleam/list
import gleam/string

/// Core data types for the type graph.
///
/// A `TypeRef` is the canonical identity of a node — either a fully-qualified
/// user-defined type, a stdlib primitive, a generic variable, or unresolved.
/// An `Edge` is a transformation: input `TypeRef` → output `TypeRef`,
/// labeled with the function that performs it.
///
/// Parameterized types carry their argument list (`List(Order)`,
/// `Dict(CustomerId, Money)`). Identity rule: a `Qualified`/`Primitive`
/// whose params are *all* `Generic` collapses to its bare form, so
/// `List(a)` and `List(b)` are the same node as `List`, while
/// `List(Order)` is a distinct node from `List(Customer)`. Apply
/// `canonical/1` after constructing a TypeRef to enforce the rule.

pub type TypeRef {
  /// e.g. `Qualified("app/order", "OrderSnapshot", [])`,
  ///      `Qualified("gleam", "List", [Qualified("app/order", "Order", [])])`
  Qualified(module: String, name: String, params: List(TypeRef))
  /// e.g. `Primitive("String", [])`, `Primitive("Int", [])`,
  ///      `Primitive("Result", [Qualified("app/order", "Order", []), Primitive("Nil", [])])`.
  Primitive(name: String, params: List(TypeRef))
  /// Type variable, e.g. `a` in `fn id(x: a) -> a`
  Generic(name: String)
  /// `#(a, b, c)`
  Tuple
  /// `fn(a) -> b`
  FunctionT
  /// Could not resolve — usually a missing import alias
  Unknown(name: String)
  /// Synthetic node for a multi-arg function call. All typed params flow
  /// into it; the return type flows out.
  /// - `module` — full path of the defining module (e.g. `"app/order"`)
  /// - `name` — bare function name (e.g. `"make_order"`)
  /// - `params` — formatted param types, comma-joined in source order
  /// - `return_type` — formatted return type
  /// Display = `<short_module>.<name>(<params>) -> <return_type>`.
  FanIn(module: String, name: String, params: String, return_type: String)
}

pub type Edge {
  Edge(from: TypeRef, to: TypeRef, function: String)
}

pub type Graph {
  Graph(edges: List(Edge))
}

/// Drop the param list when every param is `Generic` — `List(a)`, `Result(a, e)`,
/// `Dict(k, v)` all collapse to their bare constructor. Anything with at least
/// one concrete (non-generic) param keeps its full parameterization, so
/// `List(Order)` stays distinct from `List(Customer)`. Apply this anywhere
/// you construct a TypeRef from a parsed type so the identity invariant
/// (used by `type_id`) holds.
pub fn canonical(t: TypeRef) -> TypeRef {
  case t {
    Qualified(m, n, ps) -> {
      let ps_canon = list.map(ps, canonical)
      case ps_canon == [] || list.all(ps_canon, is_generic_ref) {
        True -> Qualified(m, n, [])
        False -> Qualified(m, n, ps_canon)
      }
    }
    Primitive(n, ps) -> {
      let ps_canon = list.map(ps, canonical)
      case ps_canon == [] || list.all(ps_canon, is_generic_ref) {
        True -> Primitive(n, [])
        False -> Primitive(n, ps_canon)
      }
    }
    _ -> t
  }
}

fn is_generic_ref(t: TypeRef) -> Bool {
  case t {
    Generic(_) -> True
    _ -> False
  }
}

/// Stable, sortable string id for a TypeRef. Used by renderers.
pub fn type_id(t: TypeRef) -> String {
  case t {
    Qualified(module, name, []) -> module <> "." <> name
    Qualified(module, name, ps) ->
      module <> "." <> name <> "(" <> params_id(ps) <> ")"
    Primitive(name, []) -> name
    Primitive(name, ps) -> name <> "(" <> params_id(ps) <> ")"
    Generic(name) -> "'" <> name
    Tuple -> "Tuple"
    FunctionT -> "Function"
    Unknown(name) -> "?" <> name
    // The leading marker keeps fan-in ids in their own namespace, distinct
    // from any conceivable user type. The full module path disambiguates
    // same-named functions in modules that share a short name.
    FanIn(module, name, _, _) -> "()" <> module <> "." <> name
  }
}

fn params_id(ps: List(TypeRef)) -> String {
  ps |> list.map(type_id) |> string.join(",")
}

/// One-line label suitable for tooltips / single-line contexts. Fan-in
/// nodes collapse to `module_short.name()`, dropping their signature.
pub fn type_label_short(t: TypeRef) -> String {
  case t {
    FanIn(module, name, _, _) -> module_short(module) <> "." <> name <> "()"
    Qualified(module, "*", _) -> module_short(module)
    Qualified(module, name, []) -> module_short(module) <> "." <> name
    Qualified(module, name, ps) ->
      module_short(module) <> "." <> name <> "(" <> params_label(ps) <> ")"
    Primitive(name, []) -> name
    Primitive(name, ps) -> name <> "(" <> params_label(ps) <> ")"
    Generic(name) -> name
    Tuple -> "Tuple"
    FunctionT -> "Fn"
    Unknown(name) -> name <> "(?)"
  }
}

/// Short human label for diagrams — drops the package prefix from
/// `app/order.OrderSnapshot` so it renders as `order.OrderSnapshot`.
/// Fan-in nodes get a `()` suffix so they read as a function call.
/// Collapsed module bubbles (`name == "*"`) display as just the short
/// module name.
pub fn type_label(t: TypeRef) -> String {
  case t {
    Qualified(module, "*", _) -> module_short(module)
    Qualified(module, name, []) -> module_short(module) <> "." <> name
    Qualified(module, name, ps) ->
      module_short(module) <> "." <> name <> "(" <> params_label(ps) <> ")"
    Primitive(name, []) -> name
    Primitive(name, ps) -> name <> "(" <> params_label(ps) <> ")"
    Generic(name) -> name
    Tuple -> "Tuple"
    FunctionT -> "Fn"
    Unknown(name) -> name <> "(?)"
    FanIn(module, name, params, return_type) ->
      compose_fan_in_label(
        module_short(module) <> "." <> name,
        params,
        return_type,
        "\n",
      )
  }
}

fn params_label(ps: List(TypeRef)) -> String {
  ps |> list.map(type_label) |> string.join(", ")
}

/// Like `type_label` but formatted for display *inside* a subgraph for the
/// node's own module — drops the redundant `module_short.` prefix.
/// Falls back to the regular label for non-fan-in nodes or when the
/// surrounding module doesn't match.
pub fn type_label_in_module(t: TypeRef, current_module: String) -> String {
  case t {
    Qualified(module, name, []) if module == current_module -> name
    Qualified(module, name, ps) if module == current_module ->
      name <> "(" <> params_label_in_module(ps, current_module) <> ")"
    FanIn(module, name, params, return_type) if module == current_module ->
      compose_fan_in_label(name, params, return_type, "\n")
    _ -> type_label(t)
  }
}

fn params_label_in_module(ps: List(TypeRef), m: String) -> String {
  ps |> list.map(fn(p) { type_label_in_module(p, m) }) |> string.join(", ")
}

/// Same as `type_label_in_module` but inserts the given `line_break` between
/// wrapped sections — pass `"<br/>"` for mermaid labels, `"\n"` for plain
/// text. If the assembled label fits on one line, no wrapping happens.
///
/// `Qualified` types whose module matches the current subgraph also drop
/// their `module_short.` prefix — inside the `wisp` subgraph, `wisp.Body`
/// reads as just `Body`.
pub fn type_label_in_module_with_break(
  t: TypeRef,
  current_module: String,
  line_break: String,
) -> String {
  case t {
    Qualified(module, name, []) if module == current_module -> name
    Qualified(module, name, ps) if module == current_module ->
      name <> "(" <> params_label_in_module(ps, current_module) <> ")"
    FanIn(module, name, params, return_type) if module == current_module ->
      compose_fan_in_label(name, params, return_type, line_break)
    FanIn(module, name, params, return_type) ->
      compose_fan_in_label(
        module_short(module) <> "." <> name,
        params,
        return_type,
        line_break,
      )
    _ -> type_label(t)
  }
}

/// Maximum width before wrapping a fan-in label across lines.
const wrap_threshold = 60

/// Compose `name(params) -> return_type`. If the total length exceeds
/// `wrap_threshold`, break each top-level comma-separated param onto its
/// own indented line. `line_break` lets the caller choose between `"\n"`
/// (text/dot/json renderers) and `"<br/>"` (mermaid labels).
fn compose_fan_in_label(
  name: String,
  params: String,
  return_type: String,
  line_break: String,
) -> String {
  let one_line =
    name <> "(" <> params <> ") -> " <> return_type
  case string.length(one_line) <= wrap_threshold {
    True -> one_line
    False -> {
      let pieces = split_top_level_commas(params)
      let indented =
        pieces
        |> list.map(fn(p) { "  " <> string.trim(p) <> "," })
        |> string.join(line_break)
      name
      <> "("
      <> line_break
      <> indented
      <> line_break
      <> ") -> "
      <> return_type
    }
  }
}

/// Split a comma-separated parameter list, ignoring commas inside
/// parentheses or `#(...)` tuples — so `Result(a, e)` stays as one piece.
fn split_top_level_commas(s: String) -> List(String) {
  do_split(string.to_graphemes(s), 0, "", [])
  |> list.reverse
}

fn do_split(
  chars: List(String),
  depth: Int,
  current: String,
  acc: List(String),
) -> List(String) {
  case chars {
    [] ->
      case current {
        "" -> acc
        _ -> [current, ..acc]
      }
    [c, ..rest] ->
      case c, depth {
        "(", _ -> do_split(rest, depth + 1, current <> c, acc)
        ")", _ -> do_split(rest, depth - 1, current <> c, acc)
        ",", 0 -> do_split(rest, depth, "", [current, ..acc])
        _, _ -> do_split(rest, depth, current <> c, acc)
      }
  }
}

pub fn is_fan_in(t: TypeRef) -> Bool {
  case t {
    FanIn(_, _, _, _) -> True
    _ -> False
  }
}

/// Return the full module path of a fan-in node, or `""` for non-fan-ins.
/// Used by the mermaid renderer to group nodes into subgraphs.
pub fn fan_in_module(t: TypeRef) -> String {
  case t {
    FanIn(module, _, _, _) -> module
    _ -> ""
  }
}

/// Last path segment of a slash-delimited module name.
/// `"app/order" -> "order"`, `"order" -> "order"`.
pub fn module_short(module: String) -> String {
  case string.split(module, "/") |> list.last {
    Ok(seg) -> seg
    Error(_) -> module
  }
}
