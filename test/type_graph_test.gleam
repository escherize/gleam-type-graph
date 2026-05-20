import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/set
import gleam/string
import gleeunit
import simplifile
import type_graph/collapse
import type_graph/extract
import type_graph/filter
import type_graph/graph
import type_graph/parse
import type_graph/render
import type_graph/theme

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Golden-file fixture
//
// `test/fixtures/sample/` is a tiny Gleam project that exercises every
// behavior the renderer depends on:
//
//   - smart constructors (`String -> Id` via Result unwrap)
//   - snapshot/restore symmetry
//   - multi-arg fan-in with three distinct types (make_order)
//   - multi-arg fan-in where dedup leaves duplicates (merge)
//   - Option/Result unwrap on return
//   - List(T) -> List(S) container-preserving unwrap
//   - aliased import (`as o`)
//   - unqualified type import (`{type Order}`)
//   - private fn (excluded)
//   - generic-typed fn (filtered by `drop_generic`)
//
// If a code change deliberately alters the rendered text, delete
// `sample.text.expected` and re-run the test — it regenerates the
// fixture from current output.

// Fixtures live in `priv/` rather than `test/` because gleam tries to
// compile any `.gleam` file under `test/`.
const fixture_src = "priv/fixtures/sample/src"

const fixture_expected = "priv/fixtures/sample.text.expected"

pub fn fixture_text_render_test() {
  let actual = run_pipeline(fixture_src)
  case simplifile.read(fixture_expected) {
    Ok(expected) -> {
      let assert True = same(actual, expected)
        as render_mismatch(actual, expected)
    }
    Error(_) -> {
      let assert Ok(_) = simplifile.write(fixture_expected, actual)
      panic as { "created " <> fixture_expected <> " — review and commit" }
    }
  }
}

fn same(a: String, b: String) -> Bool {
  string.trim_end(a) == string.trim_end(b)
}

fn render_mismatch(actual: String, expected: String) -> String {
  // Persist the failing actual alongside the fixture so the user can
  // `diff sample.text.expected sample.text.expected.actual`.
  let _ = simplifile.write(fixture_expected <> ".actual", actual)
  "fixture mismatch — wrote actual to "
  <> fixture_expected
  <> ".actual\n\nexpected:\n"
  <> expected
  <> "\nactual:\n"
  <> actual
}

fn run_pipeline(src_dir: String) -> String {
  let assert Ok(#(modules, _errors)) = parse.parse_directory(src_dir)
  let edges =
    list.flat_map(modules, fn(m) { extract.from_module(m.name, m.ast) })
  let analyzed = modules |> list.map(fn(m) { m.name }) |> set.from_list
  let kept = filter.apply(edges, filter.default_options(), analyzed)
  render.render(kept, render.Text)
}

fn run_pipeline_mermaid(src_dir: String) -> String {
  let assert Ok(#(modules, _errors)) = parse.parse_directory(src_dir)
  let edges =
    list.flat_map(modules, fn(m) { extract.from_module(m.name, m.ast) })
  let analyzed = modules |> list.map(fn(m) { m.name }) |> set.from_list
  let kept = filter.apply(edges, filter.default_options(), analyzed)
  render.render(kept, render.Mermaid)
}

// ---------------------------------------------------------------------------
// Unit tests for the pure-function helpers most prone to silent regression.

pub fn fan_in_label_stays_one_line_when_short_test() {
  let fn_node = graph.FanIn("app/x", "f", "Int, String", "Bool")
  let assert "x.f(Int, String) -> Bool" = graph.type_label(fn_node)
}

pub fn fan_in_label_wraps_long_params_at_top_level_commas_test() {
  // Long enough to trip the 60-char wrap threshold. The splitter must
  // respect nested parens — `Result(a, e)` is one item, not two.
  let fn_node =
    graph.FanIn(
      "app/x",
      "process_inputs",
      "Result(a, e), Int, List(b), String, Float, BitArray",
      "Bool",
    )
  let label = graph.type_label(fn_node)
  // Wrapped output keeps `Result(a, e)` together on its own indented line.
  let assert True = string.contains(label, "  Result(a, e),")
  let assert True = string.contains(label, "  Int,")
  let assert True = string.contains(label, "  List(b),")
  // The return arrow lives on the closing-paren line.
  let assert True = string.contains(label, ") -> Bool")
}

pub fn type_label_drops_module_inside_subgraph_test() {
  let qual = graph.Qualified("app/order", "Order", [])
  let assert "order.Order" = graph.type_label(qual)
  let assert "Order" = graph.type_label_in_module(qual, "app/order")
  let assert "order.Order" = graph.type_label_in_module(qual, "app/customer")
}

pub fn fan_in_in_own_module_drops_prefix_test() {
  let fn_node = graph.FanIn("app/order", "make", "CustomerId, Money", "Order")
  let assert "order.make(CustomerId, Money) -> Order" = graph.type_label(fn_node)
  let assert "make(CustomerId, Money) -> Order" =
    graph.type_label_in_module(fn_node, "app/order")
}

// Regression for mermaid v10 parse errors triggered when rendering large
// real-world projects (e.g. `gleam_stdlib`):
//
//   1. Edge labels were emitted as `-->|"label"|`. Mermaid v10's flowchart
//      grammar rejects quoted text between `|...|` ("Expecting EDGE_TEXT,
//      got STR"). Must be `-->|label|` with `|` stripped from the text.
//
//   2. Type-alias bodies were inlined as a `<span class=&quot;alias-body&quot;>`
//      inside a `["..."]` mermaid node label. Mermaid v10 doesn't decode
//      `&quot;` as a quote-escape — it terminates the label early, garbling
//      every following line. Switched to single-quoted attribute, which
//      doesn't collide with the label's `"` delimiters.

pub fn mermaid_edge_labels_are_unquoted_test() {
  let mermaid = run_pipeline_mermaid(fixture_src)
  // No edge in the rendered output should use the quoted-label form.
  let assert False = string.contains(mermaid, "-->|\"")
  // And the fixture has at least one labelled transform edge, so the
  // unquoted form must show up — otherwise we're testing the absence of
  // something that never existed.
  let assert True = string.contains(mermaid, "-->|")
}

pub fn mermaid_alias_body_does_not_break_label_quoting_test() {
  // Hand-construct a single edge whose source is a type with an alias body.
  // The alias-body code path only fires when the type's id is present in
  // `alias_bodies`, so we wire that explicitly rather than relying on the
  // fixture (which has no aliases today).
  let alias_ref = graph.Qualified("app/m", "Handle", [])
  let target = graph.Qualified("app/m", "String", [])
  let edges = [graph.Edge(alias_ref, target, "m.unwrap")]
  let alias_bodies = dict.from_list([#("app/m.Handle", "String")])
  let out =
    render.render_mermaid_with_clicks(
      edges,
      fn(_) { None },
      set.new(),
      alias_bodies,
      theme.dark(),
    )
  // The alias body is present (so we know the code path ran)…
  let assert True = string.contains(out, "alias-body")
  // …but its `class=` attribute must not use `&quot;`, which mermaid v10
  // would treat as label termination.
  let assert False = string.contains(out, "class=&quot;")
}

pub fn module_collapse_dedups_and_strips_self_edges_test() {
  // Two app/order types feeding into one app/customer fan-in should produce
  // a single deduped edge `app/order -> app/customer`. The self-edge
  // `app/order -> app/order` is dropped.
  let edges = [
    graph.Edge(
      graph.Qualified("app/order", "OrderId", []),
      graph.Qualified("app/customer", "CustomerId", []),
      "customer.bind",
    ),
    graph.Edge(
      graph.Qualified("app/order", "Order", []),
      graph.Qualified("app/customer", "CustomerId", []),
      "customer.attach",
    ),
    graph.Edge(
      graph.Qualified("app/order", "Order", []),
      graph.Qualified("app/order", "OrderSnapshot", []),
      "order.snapshot",
    ),
  ]
  let result = collapse.modules(edges)
  let assert 1 = list.length(result)
  case result {
    [graph.Edge(from, to, _)] -> {
      let assert graph.Qualified("app/order", "*", _) = from
      let assert graph.Qualified("app/customer", "*", _) = to
    }
    _ -> panic as "expected exactly one collapsed edge"
  }
}
