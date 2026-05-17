import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import type_graph/graph.{type Edge, type TypeRef, Edge}
import type_graph/theme.{type Theme}

pub type Format {
  Mermaid
  Dot
  Json
  Text
  Html
}

/// One named diagram in a multi-view HTML page. `id` is the JS-safe key
/// used by the view-swap state machine; `title` shows in the header.
pub type View {
  View(id: String, title: String, mermaid: String)
}

pub fn parse_format(s: String) -> Result(Format, String) {
  case s {
    "mermaid" -> Ok(Mermaid)
    "dot" | "graphviz" -> Ok(Dot)
    "json" -> Ok(Json)
    "text" | "txt" -> Ok(Text)
    "html" -> Ok(Html)
    other -> Error("unknown format: " <> other)
  }
}

/// File extension to use when writing the rendered output to disk.
pub fn extension(format: Format) -> String {
  case format {
    Mermaid -> "mmd"
    Dot -> "dot"
    Json -> "json"
    Text -> "txt"
    Html -> "html"
  }
}

/// Format-agnostic dispatcher. Used for non-themed callers (tests, the
/// `--format text|dot|json|mermaid` CLI paths). HTML output falls back to
/// the default dark theme; if you have project/path metadata or a custom
/// theme, call `render_html_single` directly.
pub fn render(edges: List(Edge), format: Format) -> String {
  case format {
    Mermaid -> render_mermaid(edges, theme.dark())
    Dot -> render_dot(edges)
    Json -> render_json(edges)
    Text -> render_text(edges)
    Html ->
      render_html_single(
        "",
        "",
        edges,
        fn(_) { None },
        set.new(),
        dict.new(),
        theme.dark(),
      )
  }
}

// ---------------------------------------------------------------------------
// Node table
//
// Every renderer needs a stable node id. We sort the unique TypeRefs from the
// edge list and assign `n0`, `n1`, ...

type NodeTable {
  NodeTable(by_ref: dict.Dict(String, #(String, TypeRef)), ordered: List(TypeRef))
}

fn build_node_table(edges: List(Edge)) -> NodeTable {
  let refs =
    edges
    |> list.flat_map(fn(e) {
      let Edge(from, to, _) = e
      [from, to]
    })
    |> list.unique
    |> list.sort(fn(a, b) { string.compare(graph.type_id(a), graph.type_id(b)) })

  let #(by_ref, _) =
    list.fold(refs, #(dict.new(), 0), fn(acc, ref) {
      let #(d, i) = acc
      let id = "n" <> int.to_string(i)
      #(dict.insert(d, graph.type_id(ref), #(id, ref)), i + 1)
    })

  NodeTable(by_ref:, ordered: refs)
}

fn lookup(table: NodeTable, ref: TypeRef) -> String {
  case dict.get(table.by_ref, graph.type_id(ref)) {
    Ok(#(id, _)) -> id
    Error(_) -> "n?"
  }
}

// ---------------------------------------------------------------------------
// Mermaid

/// Render mermaid with optional href links per node. `href_for(ref)` returns
/// `Some(<url>)` to emit `click <nid> href "<url>" "tooltip"`, or `None` to
/// leave it unlinked. Fragment URLs (e.g. `"#module_xyz"`) work nicely with
/// a `hashchange` listener for in-page navigation.
pub fn render_mermaid_with_clicks(
  edges: List(Edge),
  href_for: fn(TypeRef) -> Option(String),
  internal_ids: Set(String),
  alias_bodies: dict.Dict(String, String),
  theme: Theme,
) -> String {
  let base = do_render_mermaid(edges, None, internal_ids, alias_bodies, theme)
  append_click_lines(base, edges, href_for)
}

fn render_mermaid(edges: List(Edge), theme: Theme) -> String {
  do_render_mermaid(edges, None, set.new(), dict.new(), theme)
}

/// Like `render_mermaid`, but only the focus module gets a subgraph
/// wrapper. Other modules' types and fan-in nodes float at the top level.
/// The reader's eye lands on the focused module; the surroundings provide
/// "what this module touches" context without competing for attention.
pub fn render_mermaid_focused(
  edges: List(Edge),
  focus_module: String,
  theme: Theme,
) -> String {
  do_render_mermaid(edges, Some(focus_module), set.new(), dict.new(), theme)
}

/// Focused mermaid with optional href links per node — used for per-module
/// views inside the multi-view HTML page so type rectangles can link out
/// to hex docs.
pub fn render_mermaid_focused_with_clicks(
  edges: List(Edge),
  focus_module: String,
  href_for: fn(TypeRef) -> Option(String),
  internal_ids: Set(String),
  alias_bodies: dict.Dict(String, String),
  theme: Theme,
) -> String {
  let base =
    do_render_mermaid(
      edges,
      Some(focus_module),
      internal_ids,
      alias_bodies,
      theme,
    )
  append_click_lines(base, edges, href_for)
}

fn append_click_lines(
  base: String,
  edges: List(Edge),
  href_for: fn(TypeRef) -> Option(String),
) -> String {
  let table = build_node_table(edges)
  let click_lines =
    list.filter_map(table.ordered, fn(r) {
      case href_for(r) {
        Some(href) -> {
          // Same-page fragment links stay in this tab; absolute URLs
          // (hex docs etc.) open in a new tab.
          let target = case string.starts_with(href, "#") {
            True -> ""
            False -> " _blank"
          }
          Ok(
            "  click "
            <> lookup(table, r)
            <> " \""
            <> escape_mermaid(href)
            <> "\" \""
            <> escape_mermaid(graph.type_label_short(r))
            <> "\""
            <> target,
          )
        }
        None -> Error(Nil)
      }
    })
  case click_lines {
    [] -> base
    _ -> base <> "\n" <> string.join(click_lines, "\n")
  }
}

fn do_render_mermaid(
  edges: List(Edge),
  focus: Option(String),
  internal_ids: Set(String),
  alias_bodies: dict.Dict(String, String),
  theme: Theme,
) -> String {
  let table = build_node_table(edges)
  let header = "flowchart LR"
  // In default mode every module-owned node lives inside its module's
  // subgraph. In focused mode only the focus module gets a subgraph;
  // everything else floats at top level so the focus is uncluttered.
  let #(grouped, ungrouped) = case focus {
    None -> list.partition(table.ordered, fn(r) { node_module(r) != "" })
    Some(m) -> list.partition(table.ordered, fn(r) { node_module(r) == m })
  }
  let groups = case focus {
    None ->
      grouped
      |> list.group(node_module)
      |> dict.to_list
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    Some(m) ->
      case grouped {
        [] -> []
        _ -> [#(m, grouped)]
      }
  }
  let subgraph_lines =
    list.flat_map(groups, fn(entry) {
      let #(module, refs) = entry
      let header_line =
        "  subgraph "
        <> sanitize_id(module)
        <> "[\""
        <> escape_mermaid(module)
        <> "\"]"
      let body_lines =
        list.map(refs, fn(r) {
          "    "
          <> render_node_in_module(table, r, module, internal_ids, alias_bodies)
        })
      list.flatten([[header_line], body_lines, ["  end"]])
    })
  let ungrouped_lines =
    list.map(ungrouped, fn(r) {
      "  " <> render_node(table, r, internal_ids, alias_bodies)
    })
  let edges_with_kinds =
    list.index_map(edges, fn(e, i) {
      let Edge(from, to, label) = e
      let from_id = lookup(table, from)
      let to_id = lookup(table, to)
      case from, to {
        _, graph.FanIn(_, _, _, _) -> #(
          i,
          "input",
          "  " <> from_id <> " --o " <> to_id,
        )
        graph.FanIn(_, _, _, _), _ -> #(
          i,
          "output",
          "  " <> from_id <> " --> " <> to_id,
        )
        _, _ -> {
          let line = case label {
            "" -> "  " <> from_id <> " --> " <> to_id
            _ ->
              "  "
              <> from_id
              <> " -->|\""
              <> escape_mermaid(label)
              <> "\"| "
              <> to_id
          }
          #(i, "transform", line)
        }
      }
    })
  let edge_lines = list.map(edges_with_kinds, fn(e) { e.2 })
  let style_lines = link_style_lines(edges_with_kinds, theme)
  // Type rectangles get bigger + bolder so the nouns of the domain
  // dominate the visual weight; function rectangles shrink slightly
  // and use the dim accent border. Fills + stroke from the theme.
  // `*-internal` variants are for `@internal`-annotated nodes —
  // dashed border applied via CSS in the host page (mermaid's
  // classDef doesn't support stroke-dasharray reliably across
  // versions).
  let class_def_lines = [
    "  classDef tnode font-size:15px,font-weight:600,fill:"
      <> theme.bg_node_type
      <> ",stroke:"
      <> theme.accent
      <> ",stroke-width:1.4px,color:"
      <> theme.text,
    "  classDef tnode-internal font-size:15px,font-weight:600,fill:"
      <> theme.bg_node_type
      <> ",stroke:"
      <> theme.accent_dim
      <> ",stroke-width:1.4px,color:"
      <> theme.text_dim,
    "  classDef fnode font-size:11px,fill:"
      <> theme.bg_node_fn
      <> ",stroke:"
      <> theme.accent_dim
      <> ",stroke-width:1px,color:"
      <> theme.text,
    "  classDef fnode-internal font-size:11px,fill:"
      <> theme.bg_node_fn
      <> ",stroke:"
      <> theme.accent_dim
      <> ",stroke-width:1px,color:"
      <> theme.text_dim,
  ]
  let body =
    list.flatten([
      subgraph_lines,
      ungrouped_lines,
      edge_lines,
      style_lines,
      class_def_lines,
    ])
  string.join([header, ..body], "\n")
}

fn link_style_lines(
  edges_with_kinds: List(#(Int, String, String)),
  theme: Theme,
) -> List(String) {
  let inputs =
    list.filter_map(edges_with_kinds, fn(e) {
      case e.1 {
        "input" -> Ok(int.to_string(e.0))
        _ -> Error(Nil)
      }
    })
  let outputs =
    list.filter_map(edges_with_kinds, fn(e) {
      case e.1 {
        "output" -> Ok(int.to_string(e.0))
        _ -> Error(Nil)
      }
    })
  let lines = []
  let lines = case inputs {
    [] -> lines
    _ -> [
      "  linkStyle "
        <> string.join(inputs, ",")
        <> " stroke:"
        <> theme.input_color
        <> ",stroke-width:1.5px",
      ..lines
    ]
  }
  let lines = case outputs {
    [] -> lines
    _ -> [
      "  linkStyle "
        <> string.join(outputs, ",")
        <> " stroke:"
        <> theme.output_color
        <> ",stroke-width:2px",
      ..lines
    ]
  }
  lines
}

fn node_module(r: graph.TypeRef) -> String {
  case r {
    // A collapsed bubble *is* its module — wrapping it in a same-named
    // subgraph would be redundant framing. Keep it top-level.
    graph.Qualified(_, "*") -> ""
    graph.Qualified(module, _) -> module
    graph.FanIn(module, _, _, _) -> module
    _ -> ""
  }
}

fn render_node(
  table: NodeTable,
  r: graph.TypeRef,
  internal_ids: Set(String),
  alias_bodies: dict.Dict(String, String),
) -> String {
  let label =
    mermaid_label(graph.type_label_in_module_with_break(r, "", "<br/>"))
  emit_node(lookup(table, r), label, r, internal_ids, alias_bodies)
}

fn render_node_in_module(
  table: NodeTable,
  r: graph.TypeRef,
  current_module: String,
  internal_ids: Set(String),
  alias_bodies: dict.Dict(String, String),
) -> String {
  let label =
    mermaid_label(graph.type_label_in_module_with_break(
      r,
      current_module,
      "<br/>",
    ))
  emit_node(lookup(table, r), label, r, internal_ids, alias_bodies)
}

/// Pick the rectangle shape + classDef class. Fan-ins get `fnode`; types
/// get `tnode`. `@internal`-annotated nodes get the `-internal` suffix so
/// CSS can render them with a dashed border (signal: "private API").
///
/// If the node is a type alias with a body in `alias_bodies`, the body is
/// appended to the label as a styled second line (`= fn(Int) -> Bool` etc.).
fn emit_node(
  id: String,
  label: String,
  r: graph.TypeRef,
  internal_ids: Set(String),
  alias_bodies: dict.Dict(String, String),
) -> String {
  let alias_suffix = case dict.get(alias_bodies, graph.type_id(r)) {
    Ok(body) ->
      "<br/><span class=&quot;alias-body&quot;>  = "
      <> mermaid_label(body)
      <> "</span>"
    Error(_) -> ""
  }
  let is_internal = set.contains(internal_ids, graph.type_id(r))
  let class = case graph.is_fan_in(r), is_internal {
    True, True -> "fnode-internal"
    True, False -> "fnode"
    False, True -> "tnode-internal"
    False, False -> "tnode"
  }
  id <> "[\"" <> label <> alias_suffix <> "\"]:::" <> class
}

/// Escape quotes for inside a mermaid `["..."]` label. `<br/>` line breaks
/// must pass through unescaped since mermaid renders them as breaks.
fn mermaid_label(s: String) -> String {
  string.replace(s, "\"", "&quot;")
}

/// Mermaid subgraph ids must be valid identifiers — drop anything else.
fn sanitize_id(s: String) -> String {
  string.replace(s, "/", "_") |> string.replace("-", "_")
}

fn escape_mermaid(s: String) -> String {
  string.replace(s, "\"", "&quot;")
}

// ---------------------------------------------------------------------------
// Graphviz dot

fn render_dot(edges: List(Edge)) -> String {
  let table = build_node_table(edges)
  let nodes =
    list.map(table.ordered, fn(r) {
      let id = lookup(table, r)
      let label = escape_dot(graph.type_label(r))
      case graph.is_fan_in(r) {
        True ->
          "  "
          <> id
          <> " [label=\""
          <> label
          <> "\", shape=ellipse, style=filled, fillcolor=\"#eef\"];"
        False -> "  " <> id <> " [label=\"" <> label <> "\"];"
      }
    })
  let edge_lines =
    list.map(edges, fn(e) {
      let Edge(from, to, label) = e
      // Input edges into a fan-in get an open-circle arrowhead, mirroring
      // the mermaid `--o` notation; output edges and plain edges use the
      // default arrowhead.
      let attrs = case from, to {
        _, graph.FanIn(_, _, _, _) -> " [arrowhead=odot]"
        graph.FanIn(_, _, _, _), _ -> ""
        _, _ ->
          case label {
            "" -> ""
            _ -> " [label=\"" <> escape_dot(label) <> "\"]"
          }
      }
      "  " <> lookup(table, from) <> " -> " <> lookup(table, to) <> attrs <> ";"
    })
  let body = list.append(nodes, edge_lines) |> string.join("\n")
  "digraph TypeGraph {\n  rankdir=LR;\n  node [shape=box];\n" <> body <> "\n}"
}

fn escape_dot(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
}

// ---------------------------------------------------------------------------
// JSON

fn render_json(edges: List(Edge)) -> String {
  let table = build_node_table(edges)
  let node_objs =
    list.map(table.ordered, fn(r) {
      let kind = case graph.is_fan_in(r) {
        True -> "fanin"
        False -> "type"
      }
      "    {\"id\": \""
      <> lookup(table, r)
      <> "\", \"ref\": \""
      <> escape_json(graph.type_id(r))
      <> "\", \"label\": \""
      <> escape_json(graph.type_label(r))
      <> "\", \"kind\": \""
      <> kind
      <> "\"}"
    })
    |> string.join(",\n")
  let edge_objs =
    list.map(edges, fn(e) {
      let Edge(from, to, label) = e
      let role = edge_role(e)
      "    {\"from\": \""
      <> lookup(table, from)
      <> "\", \"to\": \""
      <> lookup(table, to)
      <> "\", \"label\": \""
      <> escape_json(label)
      <> "\", \"role\": \""
      <> role
      <> "\"}"
    })
    |> string.join(",\n")
  "{\n  \"nodes\": [\n"
  <> node_objs
  <> "\n  ],\n  \"edges\": [\n"
  <> edge_objs
  <> "\n  ]\n}"
}

/// `input`  — type flowing into a fan-in node (function param)
/// `output` — type emitted by a fan-in node (function return)
/// `transform` — direct edge between two type nodes (single-arg function)
fn edge_role(edge: Edge) -> String {
  let Edge(from, to, _) = edge
  case from, to {
    _, graph.FanIn(_, _, _, _) -> "input"
    graph.FanIn(_, _, _, _), _ -> "output"
    _, _ -> "transform"
  }
}

fn escape_json(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\t", "\\t")
}

// ---------------------------------------------------------------------------
// Self-contained HTML (mermaid.js loaded from CDN)

/// `:root` CSS custom properties populated from the theme. The rest of the
/// page CSS uses `var(--bg-page)` etc., so changing themes is a question
/// of changing this block only.
fn theme_css_vars(theme: Theme) -> String {
  "    :root {
      --bg-page: " <> theme.bg_page <> ";
      --bg-panel: " <> theme.bg_panel <> ";
      --bg-header: " <> theme.bg_page <> ";
      --bg-legend: " <> theme.bg_legend <> ";
      --border: " <> theme.border <> ";
      --text: " <> theme.text <> ";
      --text-dim: " <> theme.text_dim <> ";
      --accent: " <> theme.accent <> ";
      --accent-dim: " <> theme.accent_dim <> ";
      --code-bg: " <> theme.code_bg <> ";
    }"
}

/// `mermaid.initialize(...)` JS — themeVariables interpolated from the theme.
/// `security_level` is `"strict"` for multi-view (no callback eval needed
/// since we use href fragments) and `"strict"` for single-view too.
fn mermaid_init_js(theme: Theme) -> String {
  "    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: 'base',
      themeVariables: {
        background: '" <> theme.bg_panel <> "',
        mainBkg: '" <> theme.bg_panel <> "',
        primaryColor: '" <> theme.bg_node_type <> "',
        primaryBorderColor: '" <> theme.accent <> "',
        primaryTextColor: '" <> theme.text <> "',
        secondaryColor: '" <> theme.bg_node_type <> "',
        secondaryBorderColor: '" <> theme.accent_dim <> "',
        secondaryTextColor: '" <> theme.text <> "',
        tertiaryColor: '" <> theme.bg_node_type <> "',
        tertiaryBorderColor: '" <> theme.accent <> "',
        tertiaryTextColor: '" <> theme.text <> "',
        lineColor: '" <> theme.transform_color <> "',
        nodeBorder: '" <> theme.accent <> "',
        clusterBkg: '" <> theme.bg_cluster <> "',
        clusterBorder: '" <> theme.accent <> "',
        titleColor: '" <> theme.text <> "',
        edgeLabelBackground: '" <> theme.bg_legend <> "',
        nodeTextColor: '" <> theme.text <> "',
      },
      flowchart: { useMaxWidth: true, curve: 'basis' },
    });"
}

/// Legend SVG swatches — inline `fill`/`stroke` attributes can't reach
/// CSS variables, so colors are interpolated directly from the theme.
fn legend_html(theme: Theme) -> String {
  "    <nav class=\"legend\" aria-label=\"legend\">
      <span class=\"legend-item\"><svg width=\"22\" height=\"10\" viewBox=\"0 0 22 10\"><rect x=\"1\" y=\"1\" width=\"20\" height=\"8\" fill=\""
    <> theme.bg_node_type
    <> "\" stroke=\""
    <> theme.accent
    <> "\" stroke-width=\"1.4\"/></svg>type</span>
      <span class=\"legend-item\"><svg width=\"22\" height=\"10\" viewBox=\"0 0 22 10\"><rect x=\"1\" y=\"1\" width=\"20\" height=\"8\" rx=\"2\" ry=\"2\" fill=\""
    <> theme.bg_node_fn
    <> "\" stroke=\""
    <> theme.accent_dim
    <> "\" stroke-width=\"1\"/></svg>function</span>
      <span class=\"legend-item\"><svg width=\"22\" height=\"10\" viewBox=\"0 0 22 10\"><rect x=\"1\" y=\"1\" width=\"20\" height=\"8\" rx=\"2\" ry=\"2\" fill=\""
    <> theme.bg_node_type
    <> "\" stroke=\""
    <> theme.accent_dim
    <> "\" stroke-width=\"1.4\" stroke-dasharray=\"3 2\"/></svg>internal</span>
      <span class=\"legend-item\"><svg width=\"32\" height=\"10\" viewBox=\"0 0 32 10\"><line x1=\"0\" y1=\"5\" x2=\"22\" y2=\"5\" stroke=\""
    <> theme.input_color
    <> "\" stroke-width=\"1.5\"/><circle cx=\"26\" cy=\"5\" r=\"3.5\" fill=\""
    <> theme.bg_panel
    <> "\" stroke=\""
    <> theme.input_color
    <> "\" stroke-width=\"1.5\"/></svg>input</span>
      <span class=\"legend-item\"><svg width=\"32\" height=\"10\" viewBox=\"0 0 32 10\"><line x1=\"0\" y1=\"5\" x2=\"24\" y2=\"5\" stroke=\""
    <> theme.output_color
    <> "\" stroke-width=\"2\"/><polygon points=\"24,1 30,5 24,9\" fill=\""
    <> theme.output_color
    <> "\"/></svg>output</span>
      <span class=\"legend-item\"><svg width=\"32\" height=\"10\" viewBox=\"0 0 32 10\"><line x1=\"0\" y1=\"5\" x2=\"24\" y2=\"5\" stroke=\""
    <> theme.transform_color
    <> "\" stroke-width=\"1.5\"/><polygon points=\"24,1 30,5 24,9\" fill=\""
    <> theme.transform_color
    <> "\"/></svg>transform</span>
    </nav>"
}

/// Page CSS shared between single-view and multi-view HTML. Everything in
/// here uses `var(--token)` references that resolve to the theme's values
/// from `theme_css_vars`.
fn shared_styles(theme: Theme) -> String {
  "    .legend { display: flex; flex-wrap: wrap; gap: 16px; padding: 8px 20px; border-bottom: 1px solid var(--border); background: var(--bg-legend); font-size: 11px; color: var(--text-dim); }
    .legend-item { display: inline-flex; align-items: center; gap: 6px; }
    .legend-item svg { display: block; }
    /* Left-align + monospace for mermaid node labels so wrapped signatures
       read like real source code. Single-line labels visually unchanged. */
    .mermaid .nodeLabel,
    .mermaid foreignObject div,
    .mermaid foreignObject span,
    .mermaid foreignObject p {
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace !important;
      text-align: left !important;
      white-space: pre;
    }
    /* Force the theme's panel/cluster colors — mermaid's `base` theme
       computes its own pinks from primaryColor that leak through when
       themeVariables alone isn't enough. */
    .mermaid g.cluster > rect,
    .mermaid g.cluster > path {
      fill: " <> theme.bg_cluster <> " !important;
      stroke: " <> theme.accent <> " !important;
      stroke-width: 1px !important;
    }
    .mermaid .cluster-label foreignObject,
    .mermaid .cluster-label .nodeLabel {
      color: " <> theme.text <> " !important;
    }
    /* Fan-in nodes get a static rounded-rectangle corner (8px) instead of
       mermaid's stadium proportional rounding. */
    .mermaid g.node.fnode rect,
    .mermaid g.node.fnode-internal rect {
      rx: 8 !important;
      ry: 8 !important;
    }
    /* `@internal` nodes (annotated as private API, hidden from hex docs)
       get a dashed border so the reader knows not to depend on them. */
    .mermaid g.node.tnode-internal rect,
    .mermaid g.node.fnode-internal rect {
      stroke-dasharray: 4 3 !important;
      opacity: 0.85;
    }
    /* Short type-alias bodies get rendered underneath the alias name in
       a dimmed, italicised line: `Reader = fn(Int) -> Result(Read, Nil)`. */
    .mermaid .alias-body {
      display: block;
      font-size: 11px;
      font-weight: 400;
      font-style: italic;
      color: var(--text-dim);
      margin-top: 2px;
    }
    /* Only nodes wrapped in an a-tag (which mermaid emits when a click
       directive exists) get the pointer cursor. Bare nodes look unclickable. */
    .mermaid .node { cursor: default; }
    .mermaid a .node { cursor: pointer; }
    .mermaid .edgePath path,
    .mermaid .flowchart-link {
      transition: stroke-width 0.12s ease, opacity 0.12s ease;
    }
    .mermaid .edgePath.hl-edge path,
    .mermaid .flowchart-link.hl-edge {
      stroke-width: 3.5px !important;
    }
    .mermaid .edgePath.hl-dim,
    .mermaid .flowchart-link.hl-dim {
      opacity: 0.15;
    }"
}

/// JS that runs after `mermaid.run()` resolves. Walks each rendered SVG,
/// builds a node-id → connected-edges adjacency table from mermaid's class
/// names (`LS-<from>` for start, `LE-<to>` for end), then wires mouseenter
/// / mouseleave handlers on every node group.
fn hover_setup_js() -> String {
  "
    function setupHover(root) {
      const edges = Array.from(root.querySelectorAll('.edgePath, .flowchart-link'));
      if (edges.length === 0) return;
      const byNode = {};
      const note = (id, e) => { (byNode[id] = byNode[id] || []).push(e); };
      edges.forEach(e => {
        Array.from(e.classList).forEach(c => {
          let m = c.match(/^LS[-_](.+)$/); if (m) note(m[1], e);
          m = c.match(/^LE[-_](.+)$/); if (m) note(m[1], e);
        });
      });
      Array.from(root.querySelectorAll('.node')).forEach(node => {
        const m = (node.id || '').match(/^flowchart-(.+)-\\d+$/);
        const origId = m ? m[1] : node.id;
        const related = new Set(byNode[origId] || []);
        node.addEventListener('mouseenter', () => {
          edges.forEach(e => {
            e.classList.add(related.has(e) ? 'hl-edge' : 'hl-dim');
          });
        });
        node.addEventListener('mouseleave', () => {
          edges.forEach(e => e.classList.remove('hl-edge', 'hl-dim'));
        });
      });
    }
    function setupAllHovers() {
      document.querySelectorAll('.mermaid').forEach(setupHover);
    }
"
}

/// JS post-pass that recolors mermaid's arrowhead / circle markers to
/// match the line stroke. Mermaid's `linkStyle stroke:...` only paints
/// the path itself; the marker (referenced from a shared `<defs>` block
/// via `marker-end="url(#...)"`) keeps its default gray. We walk each
/// edge, read its stroke, lazily clone the referenced marker into a
/// color-specific variant, and re-point the edge's marker-end at it.
///
/// Theme colors are interpolated into the JS as constants so the same
/// pass works in dark and light modes.
fn arrowhead_recolor_js(theme: Theme) -> String {
  "
    const ARROW_INPUT  = '" <> theme.input_color <> "';
    const ARROW_OUTPUT = '" <> theme.output_color <> "';
    function classifyStroke(s) {
      if (!s) return null;
      const lo = s.toLowerCase();
      if (lo.indexOf(ARROW_INPUT.toLowerCase()) !== -1) return 'input';
      if (lo.indexOf(ARROW_OUTPUT.toLowerCase()) !== -1) return 'output';
      return null;
    }
    function colorArrowheads(root) {
      const cache = {};
      const paths = root.querySelectorAll('.edgePath > path, path.flowchart-link');
      paths.forEach(path => {
        const style = path.getAttribute('style') || '';
        const strokeMatch = style.match(/stroke:\\s*([^;]+)/i);
        const stroke = strokeMatch ? strokeMatch[1].trim() : '';
        const kind = classifyStroke(stroke);
        if (!kind) return;
        const markerEnd = path.getAttribute('marker-end') || '';
        const idMatch = markerEnd.match(/url\\(#([^)]+)\\)/);
        if (!idMatch) return;
        const origId = idMatch[1];
        const cacheKey = origId + '|' + kind;
        let cloneId = cache[cacheKey];
        if (!cloneId) {
          const orig = root.getElementById(origId) || document.getElementById(origId);
          if (!orig) return;
          cloneId = origId + '-' + kind;
          if (!document.getElementById(cloneId)) {
            const clone = orig.cloneNode(true);
            clone.setAttribute('id', cloneId);
            clone.querySelectorAll('path, circle, line, polygon').forEach(el => {
              el.setAttribute('fill', stroke);
              el.setAttribute('stroke', stroke);
            });
            orig.parentNode.appendChild(clone);
          }
          cache[cacheKey] = cloneId;
        }
        path.setAttribute('marker-end', 'url(#' + cloneId + ')');
      });
    }
    function colorAllArrowheads() {
      document.querySelectorAll('.mermaid').forEach(colorArrowheads);
    }
"
}

/// Single-view HTML, with project/path header metadata. `href_for` lets
/// the caller attach hex-docs (or other) links to specific nodes;
/// `internal_ids` marks `@internal` nodes for distinct styling;
/// `alias_bodies` lets short `pub type X = Y` aliases display `Y` inline
/// beneath the alias name.
pub fn render_html_single(
  project: String,
  source_path: String,
  edges: List(Edge),
  href_for: fn(TypeRef) -> Option(String),
  internal_ids: Set(String),
  alias_bodies: dict.Dict(String, String),
  theme: Theme,
) -> String {
  let mermaid_src =
    render_mermaid_with_clicks(
      edges,
      href_for,
      internal_ids,
      alias_bodies,
      theme,
    )
    |> escape_html
  let title = case project {
    "" -> "Type Graph"
    _ -> escape_html(project) <> " — type graph"
  }
  let header = case project, source_path {
    "", "" -> "  <header><h1 class=\"view-label\">Type Graph</h1></header>"
    _, _ ->
      "  <header>
    <div class=\"meta\">
      <h1 class=\"project\">" <> escape_html(project) <> "</h1>
      <code class=\"path\" title=\"" <> escape_html(source_path) <> "\">" <> escape_html(source_path) <> "</code>
    </div>
  </header>"
  }
  "<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <title>" <> title <> "</title>
  <style>
" <> theme_css_vars(theme) <> "
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: var(--bg-page); color: var(--text); }
    header { padding: 14px 20px; border-bottom: 1px solid var(--border); background: var(--bg-header); }
    header .meta { display: flex; flex-direction: column; gap: 2px; }
    header .project { margin: 0; font-size: 20px; font-weight: 700; color: var(--accent); letter-spacing: -0.01em; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    header .path { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; color: var(--text-dim); }
    header .view-label { margin: 0; font-size: 14px; font-weight: 500; color: var(--text-dim); letter-spacing: 0.04em; text-transform: uppercase; }
" <> shared_styles(theme) <> "
    main { padding: 20px; }
    .mermaid { background: var(--bg-panel); border: 1px solid var(--border); border-radius: 6px; padding: 24px; overflow: auto; }
    details { margin-top: 16px; }
    summary { cursor: pointer; color: var(--text-dim); font-size: 13px; padding: 4px 0; }
    pre { background: var(--code-bg); color: var(--text); padding: 12px; border-radius: 4px; overflow-x: auto; font-size: 12px; border: 1px solid var(--border); }
  </style>
</head>
<body>
" <> header <> "
" <> legend_html(theme) <> "
  <main>
    <pre class=\"mermaid\">
" <> mermaid_src <> "
    </pre>
    <details>
      <summary>Source</summary>
      <pre>" <> mermaid_src <> "</pre>
    </details>
  </main>
  <script src=\"https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js\"></script>
  <script>
" <> hover_setup_js() <> "
" <> arrowhead_recolor_js(theme) <> "
" <> mermaid_init_js(theme) <> "
    mermaid.run({ querySelector: '.mermaid' }).then(() => {
      setupAllHovers();
      colorAllArrowheads();
    });
  </script>
</body>
</html>"
}

/// Multi-view HTML — embeds every `View`'s mermaid source, shows the one
/// whose id matches `default`, and provides a `selectView(id)` JS function
/// for click-driven swapping. A "back to overview" button is wired to swap
/// to view id `"overview"` if present.
///
/// `project` shows big in the header and in the browser tab title so
/// multiple open tabs are distinguishable. `source_path` shows below it
/// (small, dim) for full disambiguation.
pub fn render_html_views(
  project: String,
  source_path: String,
  views: List(View),
  default: String,
  theme: Theme,
) -> String {
  // All views render visible first so mermaid can compute layout for each.
  // The boot script hides non-default ones after `mermaid.run()` resolves.
  let view_blocks =
    list.map(views, fn(v) {
      "    <pre class=\"mermaid view\" data-view=\""
      <> v.id
      <> "\">\n"
      <> escape_html(v.mermaid)
      <> "\n    </pre>"
    })
  let title_map =
    views
    |> list.map(fn(v) {
      "    \""
      <> escape_js(v.id)
      <> "\": \""
      <> escape_js(v.title)
      <> "\""
    })
    |> string.join(",\n")
  "<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <title>" <> escape_html(project) <> " — type graph</title>
  <style>
" <> theme_css_vars(theme) <> "
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: var(--bg-page); color: var(--text); }
    header { padding: 14px 20px; border-bottom: 1px solid var(--border); background: var(--bg-header); display: flex; align-items: center; gap: 16px; }
    header .meta { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
    header .project { margin: 0; font-size: 20px; font-weight: 700; color: var(--accent); letter-spacing: -0.01em; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    header .path { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; color: var(--text-dim); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    header .spacer { flex: 1; }
    header .view-label { font-size: 12px; color: var(--text-dim); letter-spacing: 0.04em; text-transform: uppercase; }
    header button { font-size: 12px; padding: 4px 10px; cursor: pointer; border: 1px solid var(--border); background: var(--bg-panel); color: var(--text); border-radius: 3px; }
    header button:hover { border-color: var(--accent); color: var(--accent); }
    header button[hidden] { display: none; }
" <> shared_styles(theme) <> "
    /* Hide `main` until mermaid finishes rendering. The diagrams need to be
       laid out (otherwise mermaid skips them), but the user shouldn't see
       all N views stacked vertically for the brief render window. */
    main { padding: 20px; opacity: 0; transition: opacity 0.1s ease-in; }
    main.ready { opacity: 1; }
    .view { background: var(--bg-panel); border: 1px solid var(--border); border-radius: 6px; padding: 24px; overflow: auto; }
    .view[hidden] { display: none; }
    .hint { color: var(--text-dim); font-size: 11px; margin-top: 8px; }
  </style>
</head>
<body>
  <header>
    <div class=\"meta\">
      <h1 class=\"project\">" <> escape_html(project) <> "</h1>
      <code class=\"path\" title=\"" <> escape_html(source_path) <> "\">" <> escape_html(source_path) <> "</code>
    </div>
    <div class=\"spacer\"></div>
    <span class=\"view-label\" id=\"title\">Overview</span>
    <button id=\"back\" hidden>← overview</button>
  </header>
" <> legend_html(theme) <> "
  <main>
" <> string.join(view_blocks, "\n") <> "
    <p class=\"hint\">Click a module bubble to drill in.</p>
  </main>
  <script>
    const TITLES = {
" <> title_map <> "
    };
    const DEFAULT_VIEW = '" <> escape_js(default) <> "';
    function selectView(id) {
      if (!TITLES.hasOwnProperty(id)) id = DEFAULT_VIEW;
      document.querySelectorAll('.view').forEach(el => {
        el.hidden = el.dataset.view !== id;
      });
      document.getElementById('back').hidden = id === DEFAULT_VIEW;
      document.getElementById('title').textContent = TITLES[id] || id;
    }
    function viewFromHash() {
      const id = (location.hash || '').replace(/^#/, '');
      return id || DEFAULT_VIEW;
    }
    window.addEventListener('hashchange', () => selectView(viewFromHash()));
    document.getElementById('back').addEventListener('click', (e) => {
      e.preventDefault();
      history.pushState(null, '', location.pathname + location.search);
      selectView(DEFAULT_VIEW);
    });
  </script>
  <!-- UMD bundle (sets window.mermaid) — works in stricter embedding
       contexts than the ESM build, which can fail when the host page
       blocks module imports (gist preview, some sandbox iframes). -->
  <script src=\"https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js\"></script>
  <script>
" <> hover_setup_js() <> "
" <> arrowhead_recolor_js(theme) <> "
" <> mermaid_init_js(theme) <> "
    // Render every view first (mermaid needs visible layout for SVG
    // positions), then collapse to whichever view the URL hash names
    // and reveal `main` so the user never sees the stacked-views flash.
    function revealMain() {
      document.querySelector('main').classList.add('ready');
    }
    // Safety net: if mermaid silently hangs or one diagram errors out and
    // breaks the promise chain, reveal anyway after 3s so the page
    // doesn't render permanently blank.
    setTimeout(revealMain, 3000);
    mermaid.run({ querySelector: '.mermaid' }).then(() => {
      setupAllHovers();
      colorAllArrowheads();
      selectView(viewFromHash());
      revealMain();
    }).catch(err => {
      console.error('mermaid.run failed:', err);
      // Still try to do the hide-non-default pass — selectView is just
      // DOM manipulation, doesn't depend on mermaid SVG.
      selectView(viewFromHash());
      revealMain();
    });
  </script>
</body>
</html>"
}

fn escape_js(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
}

fn escape_html(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
}

// ---------------------------------------------------------------------------
// Plain text
//
// Fan-in clusters collapse into a single line:
//   `{CustomerId, OrderId, Money} --[order.make_order]--> Order`
// Single-arg edges stay flat:
//   `Order --[order.snapshot]--> OrderSnapshot`

type FanInGroup {
  FanInGroup(inputs: List(TypeRef), output: Option(TypeRef), label: String)
}

fn render_text(edges: List(Edge)) -> String {
  let #(simple, around_fan_in) =
    list.partition(edges, fn(e) {
      let Edge(from, to, _) = e
      !graph.is_fan_in(from) && !graph.is_fan_in(to)
    })

  let groups = list.fold(around_fan_in, dict.new(), accumulate_fan_in)

  let group_lines = dict.values(groups) |> list.map(format_fan_in_group)
  let simple_lines =
    list.map(simple, fn(e) {
      let Edge(from, to, label) = e
      let arrow = case label {
        "" -> " --> "
        _ -> " --[" <> label <> "]--> "
      }
      graph.type_label(from) <> arrow <> graph.type_label(to)
    })

  list.append(simple_lines, group_lines)
  |> list.sort(string.compare)
  |> string.join("\n")
}

fn accumulate_fan_in(
  acc: dict.Dict(String, FanInGroup),
  edge: Edge,
) -> dict.Dict(String, FanInGroup) {
  let Edge(from, to, label) = edge
  let group =
    dict.get(acc, label)
    |> result_unwrap(FanInGroup([], None, label))
  let updated = case from, to {
    _, graph.FanIn(_, _, _, _) ->
      FanInGroup([from, ..group.inputs], group.output, label)
    graph.FanIn(_, _, _, _), _ ->
      FanInGroup(group.inputs, Some(to), label)
    _, _ -> group
  }
  dict.insert(acc, label, updated)
}

fn result_unwrap(r: Result(a, b), default: a) -> a {
  case r {
    Ok(v) -> v
    Error(_) -> default
  }
}

fn format_fan_in_group(g: FanInGroup) -> String {
  let inputs_str =
    g.inputs
    |> list.map(graph.type_label)
    |> list.sort(string.compare)
    |> string.join(", ")
  let out = case g.output {
    Some(o) -> graph.type_label(o)
    None -> "?"
  }
  "{" <> inputs_str <> "} --[" <> g.label <> "]--> " <> out
}
