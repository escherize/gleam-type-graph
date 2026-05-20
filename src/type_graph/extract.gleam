import glance
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import type_graph/graph.{type Edge, type TypeRef, Edge}

/// Resolution table for a single source module — knows how `module=Some(...)`
/// and unqualified type names map back to fully-qualified module paths.
type Imports {
  Imports(
    /// Local module alias → full module path. `import app/order` adds
    /// `"order" -> "app/order"`. `import app/order as o` adds `"o" -> "app/order"`.
    module_aliases: Dict(String, String),
    /// Unqualified type → full module path it lives in. From
    /// `import app/order.{type OrderSnapshot}` and friends.
    local_types: Dict(String, String),
    /// Path of the module being analysed.
    self: String,
  )
}

/// Pull edges out of one parsed module.
/// Type ids (matching `graph.type_id/1`) of `pub` functions and types
/// that carry an `@internal` attribute. Gleam's doc generator hides
/// these from hex docs even though they're publicly callable, so the
/// link generator should skip them to avoid dead anchors.
pub fn internal_node_ids(self: String, module: glance.Module) -> List(String) {
  let internal_fns =
    list.filter_map(module.functions, fn(def) {
      case has_internal_attr(def.attributes) {
        True -> Ok("()" <> self <> "." <> def.definition.name)
        False -> Error(Nil)
      }
    })
  let internal_types =
    list.filter_map(module.custom_types, fn(def) {
      case has_internal_attr(def.attributes) {
        True -> Ok(self <> "." <> def.definition.name)
        False -> Error(Nil)
      }
    })
  let internal_aliases =
    list.filter_map(module.type_aliases, fn(def) {
      case has_internal_attr(def.attributes) {
        True -> Ok(self <> "." <> def.definition.name)
        False -> Error(Nil)
      }
    })
  list.flatten([internal_fns, internal_types, internal_aliases])
}

fn has_internal_attr(attrs: List(glance.Attribute)) -> Bool {
  list.any(attrs, fn(a) {
    let glance.Attribute(name, _) = a
    name == "internal"
  })
}

/// Type ids → formatted aliased body, for short `pub type X = Y` aliases.
/// Used by the renderer to display the body inline beneath the alias's
/// name. We skip private aliases (not in the graph), and skip ones whose
/// formatted body exceeds 80 chars so pathological aliases (deeply
/// nested generics) don't blow up node sizes.
pub fn type_alias_bodies(
  self: String,
  module: glance.Module,
) -> Dict(String, String) {
  let imports = build_imports(self, module.imports)
  module.type_aliases
  |> list.filter_map(fn(def) {
    case def.definition.publicity {
      glance.Public -> {
        let glance.TypeAlias(_, name, _, _, aliased) = def.definition
        let body = format_type(aliased, imports)
        case string.length(body) <= 80 {
          True -> Ok(#(self <> "." <> name, body))
          False -> Error(Nil)
        }
      }
      glance.Private -> Error(Nil)
    }
  })
  |> dict.from_list
}

/// Type ids of *every* `pub` function, custom type, and type alias in
/// the module — regardless of `@internal` status. Used to bulk-mark
/// nodes from a conventionally-internal module (path matches
/// `<pkg>/internal[/...]`) so they get the same visual treatment as
/// individually `@internal`-annotated nodes.
pub fn pub_node_ids(self: String, module: glance.Module) -> List(String) {
  let fns =
    list.filter_map(module.functions, fn(def) {
      case def.definition.publicity {
        glance.Public -> Ok("()" <> self <> "." <> def.definition.name)
        glance.Private -> Error(Nil)
      }
    })
  let types =
    list.filter_map(module.custom_types, fn(def) {
      case def.definition.publicity {
        glance.Public -> Ok(self <> "." <> def.definition.name)
        glance.Private -> Error(Nil)
      }
    })
  let aliases =
    list.filter_map(module.type_aliases, fn(def) {
      case def.definition.publicity {
        glance.Public -> Ok(self <> "." <> def.definition.name)
        glance.Private -> Error(Nil)
      }
    })
  list.flatten([fns, types, aliases])
}

/// Map of type-id → source line number (1-based) of the `pub fn`/`pub type`
/// declaration. `source` is the raw module text; glance's `Span.start` is a
/// byte offset into it. Used to build github source URLs as a fallback when
/// hex docs hides a node.
pub fn source_locations(
  self: String,
  module: glance.Module,
  source: String,
) -> Dict(String, Int) {
  let line_starts = build_line_starts(source)
  let function_locs =
    list.map(module.functions, fn(def) {
      let glance.Function(loc, name, _, _, _, _) = def.definition
      let glance.Span(start, _) = loc
      #("()" <> self <> "." <> name, line_at(line_starts, start))
    })
  let type_locs =
    list.map(module.custom_types, fn(def) {
      let glance.CustomType(loc, name, _, _, _, _) = def.definition
      let glance.Span(start, _) = loc
      #(self <> "." <> name, line_at(line_starts, start))
    })
  let alias_locs =
    list.map(module.type_aliases, fn(def) {
      let glance.TypeAlias(loc, name, _, _, _) = def.definition
      let glance.Span(start, _) = loc
      #(self <> "." <> name, line_at(line_starts, start))
    })
  list.flatten([function_locs, type_locs, alias_locs])
  |> dict.from_list
}

/// Sorted list of byte offsets where each line begins. Index 0 is byte 0
/// (start of line 1); index N is the byte just after the Nth `\n`.
fn build_line_starts(source: String) -> List(Int) {
  // `string.split` works on graphemes but `\n` is a single byte so the
  // count is consistent with byte offsets here. For the byte size of each
  // line, drop down to a BitArray.
  let lines = string.split(source, "\n")
  let #(starts, _) =
    list.fold(lines, #([0], 0), fn(acc, line) {
      let #(starts, pos) = acc
      let next = pos + bit_array.byte_size(bit_array.from_string(line)) + 1
      #([next, ..starts], next)
    })
  list.reverse(starts)
}

/// 1-based line number for a byte offset, given the line-starts table.
fn line_at(line_starts: List(Int), byte_offset: Int) -> Int {
  do_line_at(line_starts, byte_offset, 1, 1)
}

fn do_line_at(
  starts: List(Int),
  target: Int,
  current_line: Int,
  best: Int,
) -> Int {
  case starts {
    [] -> best
    [start, ..rest] ->
      case start <= target {
        True -> do_line_at(rest, target, current_line + 1, current_line)
        False -> best
      }
  }
}

pub fn from_module(self: String, module: glance.Module) -> List(Edge) {
  let imports = build_imports(self, module.imports)
  list.flat_map(module.functions, fn(def) {
    edges_for_function(def.definition, imports)
  })
}

fn build_imports(
  self: String,
  imports: List(glance.Definition(glance.Import)),
) -> Imports {
  list.fold(imports, Imports(dict.new(), dict.new(), self), fn(acc, def) {
    let glance.Import(_, module, alias, unq_types, _unq_values) = def.definition
    let module_aliases =
      dict.insert(acc.module_aliases, alias_name(module, alias), module)
    let local_types =
      list.fold(unq_types, acc.local_types, fn(d, ut) {
        let glance.UnqualifiedImport(name, alias) = ut
        let local_name = option.unwrap(alias, name)
        dict.insert(d, local_name, module)
      })
    Imports(module_aliases, local_types, acc.self)
  })
}

/// What name does the importing module use to refer to the imported module?
/// Either the explicit `as` alias, or the last segment of the module path.
fn alias_name(module: String, alias: Option(glance.AssignmentName)) -> String {
  case alias {
    Some(glance.Named(n)) -> n
    Some(glance.Discarded(_)) | None ->
      case string.split(module, "/") |> list.last {
        Ok(seg) -> seg
        Error(_) -> module
      }
  }
}

fn edges_for_function(fn_def: glance.Function, imports: Imports) -> List(Edge) {
  // Public functions only — private fns are implementation detail.
  case fn_def.publicity {
    glance.Private -> []
    glance.Public ->
      case fn_def.return {
        None -> []
        Some(raw_return) -> {
          let label = graph.module_short(imports.self) <> "." <> fn_def.name
          let typed_params =
            list.filter_map(fn_def.parameters, fn(p) {
              case p.type_ {
                Some(t) -> Ok(t)
                None -> Error(Nil)
              }
            })
          case typed_params {
            // No annotated params — nothing meaningful to graph.
            [] -> []
            // Single-arg: keep the simple `param -> return` edge.
            [single] -> {
              let #(in_t, out_t) = pair_unwrap(single, raw_return)
              [Edge(resolve(in_t, imports), resolve(out_t, imports), label)]
            }
            // Multi-arg: introduce a synthetic fan-in node, *unless* dedup
            // collapses the inputs to a single type — then a plain edge
            // captures the same fact more cleanly.
            many -> {
              let return_ref = resolve(strip_monadic(raw_return), imports)
              let resolved_params =
                list.map(many, fn(raw_param) {
                  let #(in_t, _) = pair_unwrap(raw_param, raw_return)
                  resolve(in_t, imports)
                })
              let input_refs = list.unique(resolved_params)
              case input_refs {
                [single] -> [Edge(single, return_ref, label)]
                _ -> {
                  // The display signature uses *raw* glance types so we can
                  // surface real function-type structure (`fn(Req) -> Resp`)
                  // and tuple shapes that the graph-level resolution
                  // collapses to bare `Fn` / `Tuple` nodes.
                  let params_signature =
                    many
                    |> list.map(fn(rp) { format_type(rp, imports) })
                    |> string.join(", ")
                  let return_signature = format_type(raw_return, imports)
                  let fan_node =
                    graph.FanIn(
                      imports.self,
                      fn_def.name,
                      params_signature,
                      return_signature,
                    )
                  let input_edges =
                    list.map(input_refs, fn(r) { Edge(r, fan_node, label) })
                  list.append(input_edges, [Edge(fan_node, return_ref, label)])
                }
              }
            }
          }
        }
      }
  }
}

/// Apply MVP unwrap rules to a (param, return) pair:
/// - Strip Result/Option from each side.
/// - If both ended up as List(T), unwrap one container layer (container-preserving).
fn pair_unwrap(
  param: glance.Type,
  return: glance.Type,
) -> #(glance.Type, glance.Type) {
  let p = strip_monadic(param)
  let r = strip_monadic(return)
  case p, r {
    glance.NamedType(_, "List", None, [inner_p]),
      glance.NamedType(_, "List", None, [inner_r])
    -> #(strip_monadic(inner_p), strip_monadic(inner_r))
    _, _ -> #(p, r)
  }
}

fn strip_monadic(t: glance.Type) -> glance.Type {
  case t {
    glance.NamedType(_, "Result", None, [ok, _]) -> strip_monadic(ok)
    glance.NamedType(_, "Option", None, [inner]) -> strip_monadic(inner)
    other -> other
  }
}

/// Format a `glance.Type` for inclusion in a fan-in node's signature label.
/// Unlike `resolve`, this preserves structure: `fn(Request) -> Response`
/// stays as a function type, `#(Int, String)` stays as a tuple, parameterised
/// generics like `List(Order)` keep their parameters.
fn format_type(t: glance.Type, imports: Imports) -> String {
  case t {
    glance.NamedType(_, name, module_opt, []) ->
      graph.type_label(resolve_named(name, module_opt, imports, []))
    glance.NamedType(_, name, module_opt, params) -> {
      // Render the head with no params via `resolve_named` (so `type_label`
      // doesn't double-format the parameterised form), then format each
      // glance param recursively. This preserves type variables (`a`, `b`)
      // and nested structure (`fn(a) -> b`, `#(Int, String)`) in the
      // signature label — `resolve` would canonicalise/flatten them.
      let head = graph.type_label(resolve_named(name, module_opt, imports, []))
      let inner =
        params
        |> list.map(fn(p) { format_type(p, imports) })
        |> string.join(", ")
      head <> "(" <> inner <> ")"
    }
    glance.TupleType(_, elements) -> {
      let inner =
        elements
        |> list.map(fn(e) { format_type(e, imports) })
        |> string.join(", ")
      "#(" <> inner <> ")"
    }
    glance.FunctionType(_, parameters, return) -> {
      let inner =
        parameters
        |> list.map(fn(p) { format_type(p, imports) })
        |> string.join(", ")
      "fn(" <> inner <> ") -> " <> format_type(return, imports)
    }
    glance.VariableType(_, name) -> name
    glance.HoleType(_, name) -> name
  }
}

fn resolve(t: glance.Type, imports: Imports) -> TypeRef {
  case t {
    glance.NamedType(_, name, module_opt, params) -> {
      let resolved_params = list.map(params, fn(p) { resolve(p, imports) })
      let base = resolve_named(name, module_opt, imports, resolved_params)
      // Canonicalise: a `List(a)`-shaped type collapses to bare `List`,
      // while `List(Order)` keeps its parameterisation. This is the rule
      // that lets generics share a single node and concrete containers
      // become distinct nouns of the domain.
      graph.canonical(base)
    }
    glance.TupleType(_, _) -> graph.Tuple
    glance.FunctionType(_, _, _) -> graph.FunctionT
    glance.VariableType(_, name) -> graph.Generic(name)
    glance.HoleType(_, name) -> graph.Generic(name)
  }
}

fn resolve_named(
  name: String,
  module_opt: Option(String),
  imports: Imports,
  params: List(TypeRef),
) -> TypeRef {
  case module_opt {
    Some(m) ->
      case dict.get(imports.module_aliases, m) {
        Ok(full) -> graph.Qualified(full, name, params)
        Error(_) -> graph.Unknown(m <> "." <> name)
      }
    None -> {
      case is_builtin(name) {
        True -> graph.Primitive(name, params)
        False ->
          case dict.get(imports.local_types, name) {
            Ok(full) -> graph.Qualified(full, name, params)
            Error(_) -> graph.Qualified(imports.self, name, params)
          }
      }
    }
  }
}

/// Names that are valid as bare identifiers in any Gleam module without
/// an import — true language primitives plus the auto-imported stdlib types.
fn is_builtin(name: String) -> Bool {
  case name {
    "String"
    | "Int"
    | "Float"
    | "Bool"
    | "Nil"
    | "BitArray"
    | "Result"
    | "Option"
    | "List" -> True
    _ -> False
  }
}
