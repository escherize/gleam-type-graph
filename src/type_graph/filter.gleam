import gleam/list
import gleam/set.{type Set}
import gleam/string
import type_graph/graph.{type Edge, type TypeRef, Edge}

pub type Options {
  Options(
    /// Drop edges where input == output and both are language primitives
    /// (`String -> String`, `Int -> Int`, ...). Default: True.
    drop_primitive_self_edges: Bool,
    /// Keep only edges between types defined inside the analyzed source tree.
    /// Default: False.
    domain_only: Bool,
    /// Drop edges between generic / type-variable nodes (`a -> b`). Default: True.
    drop_generic: Bool,
    /// Module-name substrings that an edge must match (any side) to be kept.
    /// Empty list means no filter.
    include_modules: List(String),
    /// Module-name substrings that disqualify an edge (any side).
    exclude_modules: List(String),
  )
}

pub fn default_options() -> Options {
  Options(
    drop_primitive_self_edges: True,
    domain_only: False,
    drop_generic: True,
    include_modules: [],
    exclude_modules: [],
  )
}

/// Apply the configured filters and prune any fan-in clusters that lost
/// inputs or output along the way.
///
/// `analyzed_modules` is the set of fully-qualified module paths actually
/// parsed in this run. It defines what `--domain-only` considers "domain":
/// types reaching out to anything *not* in this set are treated as external.
pub fn apply(
  edges: List(Edge),
  opts: Options,
  analyzed_modules: Set(String),
) -> List(Edge) {
  edges
  |> list.filter(fn(e) { keep(e, opts, analyzed_modules) })
  |> prune_orphan_fan_ins
}

fn keep(edge: Edge, opts: Options, analyzed: Set(String)) -> Bool {
  let Edge(from, to, _) = edge
  let module_ok =
    matches_modules(edge, opts.include_modules, opts.exclude_modules)
  // Edges that touch a fan-in node describe call structure, not type flow,
  // so the type-shape filters (drop_primitive / drop_generic / domain_only)
  // don't apply — they'd surgically dismember a meaningful cluster.
  let touches_fan_in = graph.is_fan_in(from) || graph.is_fan_in(to)
  case touches_fan_in {
    True -> module_ok
    False -> {
      let primitive_ok = case opts.drop_primitive_self_edges {
        True -> !{ is_primitive(from) && from == to }
        False -> True
      }
      let generic_ok = case opts.drop_generic {
        True -> !is_generic(from) && !is_generic(to)
        False -> True
      }
      let domain_ok = case opts.domain_only {
        True -> is_domain(from, analyzed) && is_domain(to, analyzed)
        False -> True
      }
      module_ok && primitive_ok && generic_ok && domain_ok
    }
  }
}

fn is_primitive(t: TypeRef) -> Bool {
  case t {
    graph.Primitive(_, _) -> True
    _ -> False
  }
}

fn is_generic(t: TypeRef) -> Bool {
  case t {
    graph.Generic(_) -> True
    _ -> False
  }
}

/// "Domain" types are those defined inside the analyzed source tree. Anything
/// pointing to a module we didn't parse — stdlib, an external library, or a
/// primitive — is treated as external. Fan-in nodes are user code by
/// construction and always count as domain.
fn is_domain(t: TypeRef, analyzed: Set(String)) -> Bool {
  case t {
    graph.Qualified(module, _, _) -> set.contains(analyzed, module)
    graph.FanIn(_, _, _, _) -> True
    graph.Primitive(_, _)
    | graph.Generic(_)
    | graph.Tuple
    | graph.FunctionT
    | graph.Unknown(_) -> False
  }
}

fn matches_modules(
  edge: Edge,
  include: List(String),
  exclude: List(String),
) -> Bool {
  let Edge(from, to, label) = edge
  // Match against module names, the function label, AND the full type ids
  // (e.g. `wisp.Request`) so users can target by either coordinate.
  let candidates = [
    ref_module(from),
    ref_module(to),
    graph.type_id(from),
    graph.type_id(to),
    label,
  ]
  let included = case include {
    [] -> True
    patterns ->
      list.any(patterns, fn(p) {
        list.any(candidates, fn(c) { string.contains(c, p) })
      })
  }
  let excluded =
    list.any(exclude, fn(p) {
      list.any(candidates, fn(c) { string.contains(c, p) })
    })
  included && !excluded
}

fn ref_module(t: TypeRef) -> String {
  case t {
    graph.Qualified(module, _, _) -> module
    _ -> ""
  }
}

// ---------------------------------------------------------------------------
// Fan-in cluster repair
//
// Per-edge filtering can leave a fan-in cluster in three bad states:
//   - 0 inputs → orphan, drop the cluster
//   - 0 outputs → orphan, drop the cluster
//   - 1 input → not really a fan-in any more, collapse to a plain edge
// Anything ≥2 inputs with a real output stays as a fan-in cluster.

fn prune_orphan_fan_ins(edges: List(Edge)) -> List(Edge) {
  let #(in_count, out_count) = count_fan_in_edges(edges)
  let #(filtered, collapse_targets) =
    list.fold(edges, #([], []), fn(acc, e) {
      let #(kept_rev, collapse_rev) = acc
      let Edge(from, to, _label) = e
      case from, to {
        // Output edge of a cluster the prune pass has decided to collapse:
        // remember the (key, output) pair so input edges can rewrite to it.
        graph.FanIn(_, _, _, _) as f, _ ->
          case classify(in_count, out_count, fan_in_key(f)) {
            Drop -> #(kept_rev, collapse_rev)
            Collapse -> #(kept_rev, [#(fan_in_key(f), to), ..collapse_rev])
            Keep -> #([e, ..kept_rev], collapse_rev)
          }
        _, graph.FanIn(_, _, _, _) as f ->
          case classify(in_count, out_count, fan_in_key(f)) {
            Drop | Collapse -> #(kept_rev, collapse_rev)
            Keep -> #([e, ..kept_rev], collapse_rev)
          }
        _, _ -> #([e, ..kept_rev], collapse_rev)
      }
    })

  // For each collapse target, the single surviving input edge becomes a
  // direct `input -> output` edge with the function label restored.
  let collapsed =
    list.filter_map(edges, fn(e) {
      let Edge(from, to, label) = e
      case to {
        graph.FanIn(_, _, _, _) -> {
          let key = fan_in_key(to)
          case list.key_find(collapse_targets, key) {
            Ok(output) -> Ok(Edge(from, output, label))
            Error(_) -> Error(Nil)
          }
        }
        _ -> Error(Nil)
      }
    })

  list.append(list.reverse(filtered), collapsed)
}

fn fan_in_key(t: TypeRef) -> String {
  case t {
    graph.FanIn(module, name, _, _) -> module <> "." <> name
    _ -> ""
  }
}

type ClusterFate {
  Drop
  Collapse
  Keep
}

fn classify(
  in_count: Counter,
  out_count: Counter,
  label: String,
) -> ClusterFate {
  let ins = count_get(in_count, label)
  let outs = count_get(out_count, label)
  case ins, outs {
    0, _ | _, 0 -> Drop
    1, _ -> Collapse
    _, _ -> Keep
  }
}

type Counter =
  List(#(String, Int))

fn count_fan_in_edges(edges: List(Edge)) -> #(Counter, Counter) {
  list.fold(edges, #([], []), fn(acc, e) {
    let #(ins, outs) = acc
    let Edge(from, to, _) = e
    let outs = case from {
      graph.FanIn(_, _, _, _) -> count_inc(outs, fan_in_key(from))
      _ -> outs
    }
    let ins = case to {
      graph.FanIn(_, _, _, _) -> count_inc(ins, fan_in_key(to))
      _ -> ins
    }
    #(ins, outs)
  })
}

fn count_inc(c: Counter, key: String) -> Counter {
  case list.key_find(c, key) {
    Ok(n) -> list.key_set(c, key, n + 1)
    Error(_) -> [#(key, 1), ..c]
  }
}

fn count_get(c: Counter, key: String) -> Int {
  case list.key_find(c, key) {
    Ok(n) -> n
    Error(_) -> 0
  }
}
