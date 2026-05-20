/// Graph-level transforms that change a node's identity (as opposed to
/// `filter`, which only removes edges).
import gleam/dict
import gleam/list
import type_graph/graph.{type Edge, type TypeRef, Edge}

/// Replace every type and fan-in node with a single per-module bubble,
/// dedup edges, drop self-edges. Edge labels are stripped — at this zoom
/// level the only reliably-meaningful signal is *topology* (which module
/// feeds which). Counts and function names are noise.
pub fn modules(edges: List(Edge)) -> List(Edge) {
  edges
  |> list.map(fn(e) {
    let Edge(from, to, _label) = e
    Edge(collapse_ref(from), collapse_ref(to), "")
  })
  |> list.filter(fn(e) {
    let Edge(from, to, _) = e
    from != to
  })
  |> dedup_by_endpoints
}

/// Keep one edge per (from, to) pair. Without labels, `list.unique` would
/// already dedup, but this is explicit and avoids depending on derived
/// equality semantics.
fn dedup_by_endpoints(edges: List(Edge)) -> List(Edge) {
  edges
  |> list.fold(dict.new(), fn(acc, e) {
    let Edge(from, to, _) = e
    let key = graph.type_id(from) <> "->" <> graph.type_id(to)
    case dict.has_key(acc, key) {
      True -> acc
      False -> dict.insert(acc, key, e)
    }
  })
  |> dict.values
}

/// Replace a node identity with its module bubble. Non-module nodes
/// (primitives, generics, etc.) pass through unchanged so the overview still
/// shows their relationships to user-defined modules.
fn collapse_ref(t: TypeRef) -> TypeRef {
  case t {
    graph.Qualified(module, _, _) -> graph.Qualified(module, "*", [])
    graph.FanIn(module, _, _, _) -> graph.Qualified(module, "*", [])
    other -> other
  }
}
