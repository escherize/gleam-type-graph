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
  /// Cytoscape.js-rendered HTML: compound nodes for modules (click to
  /// expand/collapse), force-directed layout, hover-highlight of upstream
  /// and downstream neighbors, click-to-focus on a node's neighborhood.
  Cytoscape
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
    "cytoscape" | "cy" -> Ok(Cytoscape)
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
    Cytoscape -> "html"
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
    Cytoscape ->
      render_cytoscape_html(
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
              <> " -->|"
              <> sanitize_edge_label(label)
              <> "| "
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
    graph.Qualified(_, "*", _) -> ""
    graph.Qualified(module, _, _) -> module
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
      "<br/><span class='alias-body'>  = "
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

/// Mermaid v10 takes edge-label text between `|...|` literally — quoting it
/// makes the parser reject the line. `|` itself would terminate the label.
fn sanitize_edge_label(s: String) -> String {
  string.replace(s, "|", "/")
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
      maxEdges: 100000,
      maxTextSize: 10000000,
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
      <span class=\"legend-item\"><svg width=\"22\" height=\"10\" viewBox=\"0 0 22 10\"><ellipse cx=\"11\" cy=\"5\" rx=\"10\" ry=\"4\" fill=\""
    <> theme.bg_node_fn
    <> "\" stroke=\""
    <> theme.input_color
    <> "\" stroke-width=\"1.2\"/></svg>function</span>
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
// Cytoscape.js HTML
//
// One page, force-directed layout, compound nodes per module, click-to-focus
// neighborhood, hover to highlight upstream/downstream, click a module
// header to expand/collapse it. The Gleam side just emits JSON node/edge
// data plus a static HTML shell; cytoscape, fcose, and the expand-collapse
// plugin are pulled from a CDN.

pub fn render_cytoscape_html(
  project: String,
  source_path: String,
  edges: List(Edge),
  href_for: fn(TypeRef) -> Option(String),
  internal_ids: Set(String),
  alias_bodies: dict.Dict(String, String),
  t: Theme,
) -> String {
  // Drop edges that touch a generic type variable (`a`, `acc`, `b`, ...).
  // The default filter only removes generics from non-fan-in edges, so
  // they survive on fan-in inputs/outputs and litter the canvas with
  // floating nodes that connect everything to everything. For the
  // interactive cytoscape view, the function-signature label on the
  // fan-in already shows which params were generic — the standalone
  // node carries no information.
  let edges = list.filter(edges, fn(e) { !edge_touches_generic(e) })
  let table = build_node_table(edges)
  let modules = unique_modules(table.ordered)
  let module_nodes =
    list.map(modules, fn(m) {
      "    { data: { id: \"mod:"
      <> escape_json(m)
      <> "\", label: \""
      <> escape_json(m)
      <> "\", kind: \"module\" } }"
    })
  let type_nodes =
    list.map(table.ordered, fn(r) {
      cyto_node_json(table, r, internal_ids, alias_bodies, href_for)
    })
  let short_to_full = build_short_to_full(table.ordered)
  let edge_nodes =
    list.index_map(edges, fn(e, i) {
      cyto_edge_json(table, e, "e" <> int.to_string(i), short_to_full, href_for)
    })
  let nodes_json = string.join(list.flatten([module_nodes, type_nodes]), ",\n")
  let edges_json = string.join(edge_nodes, ",\n")
  cytoscape_html_template(project, source_path, nodes_json, edges_json, t)
}

fn edge_touches_generic(e: Edge) -> Bool {
  let Edge(from, to, _) = e
  is_generic_ref(from) || is_generic_ref(to)
}

fn is_generic_ref(r: TypeRef) -> Bool {
  case r {
    graph.Generic(_) -> True
    _ -> False
  }
}

fn unique_modules(refs: List(TypeRef)) -> List(String) {
  refs
  |> list.filter_map(fn(r) {
    case r {
      graph.Qualified(m, _, _) -> Ok(m)
      graph.FanIn(m, _, _, _) -> Ok(m)
      _ -> Error(Nil)
    }
  })
  |> list.unique
  |> list.sort(string.compare)
}

fn cyto_node_json(
  table: NodeTable,
  r: TypeRef,
  internal_ids: Set(String),
  alias_bodies: dict.Dict(String, String),
  href_for: fn(TypeRef) -> Option(String),
) -> String {
  let id = lookup(table, r)
  let parent_field = case r {
    graph.Qualified(m, _, _) -> ", parent: \"mod:" <> escape_json(m) <> "\""
    graph.FanIn(m, _, _, _) -> ", parent: \"mod:" <> escape_json(m) <> "\""
    _ -> ""
  }
  let label = case r {
    graph.Qualified(m, _, _) -> graph.type_label_in_module(r, m)
    graph.FanIn(m, _, _, _) -> graph.type_label_in_module(r, m)
    _ -> graph.type_label(r)
  }
  let is_internal = set.contains(internal_ids, graph.type_id(r))
  let kind = case graph.is_fan_in(r), is_internal {
    True, True -> "fnode-internal"
    True, False -> "fnode"
    False, True -> "tnode-internal"
    False, False -> "tnode"
  }
  let alias_field = case dict.get(alias_bodies, graph.type_id(r)) {
    Ok(body) -> ", alias: \"= " <> escape_json(body) <> "\""
    Error(_) -> ""
  }
  let href_field = case href_for(r) {
    Some(url) -> ", href: \"" <> escape_json(url) <> "\""
    None -> ""
  }
  "    { data: { id: \""
  <> escape_json(id)
  <> "\", label: "
  <> json_string_literal(label)
  <> ", kind: \""
  <> kind
  <> "\""
  <> parent_field
  <> alias_field
  <> href_field
  <> " } }"
}

fn cyto_edge_json(
  table: NodeTable,
  e: Edge,
  eid: String,
  short_to_full: dict.Dict(String, String),
  href_for: fn(TypeRef) -> Option(String),
) -> String {
  let Edge(from, to, label) = e
  let kind = edge_role(e)
  let label_field = case kind, label {
    "transform", lbl if lbl != "" ->
      ", label: \"" <> escape_json(lbl) <> "\""
    _, _ -> ""
  }
  // Single-arg functions are rendered as labelled edges. Attach the
  // function's source href to the edge data so the JS can open the
  // hex docs / github source when the user clicks the edge label.
  let href_field = case kind, label {
    "transform", lbl if lbl != "" ->
      case edge_href_for(lbl, short_to_full, href_for) {
        Some(url) -> ", href: \"" <> escape_json(url) <> "\""
        None -> ""
      }
    _, _ -> ""
  }
  "    { data: { id: \""
  <> eid
  <> "\", source: \""
  <> escape_json(lookup(table, from))
  <> "\", target: \""
  <> escape_json(lookup(table, to))
  <> "\", kind: \""
  <> kind
  <> "\""
  <> label_field
  <> href_field
  <> " } }"
}

/// Parse a `<short-module>.<fn_name>` edge label and look up the
/// full module path from the analysed-modules table. Then construct
/// a synthetic FanIn TypeRef and ask `href_for` for its source URL.
fn edge_href_for(
  label: String,
  short_to_full: dict.Dict(String, String),
  href_for: fn(TypeRef) -> Option(String),
) -> Option(String) {
  case string.split_once(label, ".") {
    Error(_) -> None
    Ok(#(short, name)) ->
      case dict.get(short_to_full, short) {
        Error(_) -> None
        Ok(full) -> href_for(graph.FanIn(full, name, "", ""))
      }
  }
}

/// Lookup table: short module name → first full module path with that
/// suffix. Used to resolve `bytes_tree.from_string_tree` on an edge
/// back to the actual `gleam/bytes_tree` module that owns the function.
fn build_short_to_full(refs: List(TypeRef)) -> dict.Dict(String, String) {
  refs
  |> list.filter_map(fn(r) {
    case r {
      graph.Qualified(m, _, _) -> Ok(#(graph.module_short(m), m))
      graph.FanIn(m, _, _, _) -> Ok(#(graph.module_short(m), m))
      _ -> Error(Nil)
    }
  })
  |> dict.from_list
}

/// Emit a multi-line label as a JSON string literal. `graph.type_label`
/// uses `\n` for wrapped fan-in signatures; cytoscape's `text-wrap: wrap`
/// honours `\n` so we keep them verbatim.
fn json_string_literal(s: String) -> String {
  "\"" <> escape_json(s) <> "\""
}

fn cytoscape_html_template(
  project: String,
  source_path: String,
  nodes_json: String,
  edges_json: String,
  t: Theme,
) -> String {
  "<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <title>" <> escape_html(project) <> " — type graph</title>
  <style>
" <> theme_css_vars(t) <> "
    html, body { height: 100%; }
    body { margin: 0; display: flex; flex-direction: column;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: var(--bg-page); color: var(--text); }
    header { padding: 14px 20px; border-bottom: 1px solid var(--border); background: var(--bg-header); }
    header .meta { display: flex; flex-direction: column; gap: 2px; }
    header .project { margin: 0; font-size: 20px; font-weight: 700; color: var(--accent); letter-spacing: -0.01em; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    header .path { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; color: var(--text-dim); }
" <> shared_styles(t) <> "
    main { flex: 1; min-height: 0; position: relative; }
    /* Cursor states: canvas is grabbable (pan); switches to `grabbing`
       while a drag/pan is in progress and to `pointer` when hovering an
       interactable node — matched here with classes toggled from JS. */
    /* `z-index: 0` on #cy creates a stacking context that contains
       cytoscape's inner canvases. Without it, the canvases (which
       cytoscape gives positive z-indices to) leak into the global
       stacking order and float above the toolbar / hint / focus-info
       overlays, making the buttons unclickable. */
    #cy { position: absolute; inset: 0; background: var(--bg-panel); cursor: grab; z-index: 0; }
    #cy.cy-grabbing { cursor: grabbing; }
    #cy.cy-pointing { cursor: pointer; }
    .toolbar {
      position: absolute; top: 12px; right: 12px; display: flex; gap: 8px;
      z-index: 10;
    }
    .toolbar button {
      background: var(--bg-panel); color: var(--text); border: 1px solid var(--border);
      border-radius: 4px; padding: 6px 10px; font-size: 12px; cursor: pointer;
      font-family: inherit;
    }
    .toolbar button:hover { border-color: var(--accent); color: var(--accent); }
    .hint {
      position: absolute; bottom: 10px; left: 12px; font-size: 11px;
      color: var(--text-dim); pointer-events: none; user-select: none;
      background: rgba(21,24,42,0.85); padding: 6px 10px; border-radius: 4px;
      border: 1px solid var(--border);
      z-index: 10;
    }
    .focus-info {
      position: absolute; top: 12px; left: 12px; font-size: 12px;
      color: var(--text); background: var(--bg-panel);
      border: 1px solid var(--accent); border-radius: 4px;
      padding: 6px 10px; display: none;
      z-index: 10;
    }
    .focus-info.active { display: block; }
    .focus-info code { color: var(--accent); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    /* Sticky right-click menu: appears at the cursor on cxttap and
       stays until the user picks or clicks away. */
    .ctx-menu {
      position: fixed; z-index: 100; min-width: 160px;
      background: var(--bg-panel); border: 1px solid var(--accent);
      border-radius: 6px; box-shadow: 0 6px 24px rgba(0,0,0,0.45);
      padding: 4px; display: none;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    }
    .ctx-menu button {
      display: block; width: 100%; text-align: left;
      background: transparent; color: var(--text);
      border: none; padding: 6px 10px; font-size: 13px;
      border-radius: 4px; cursor: pointer; font-family: inherit;
    }
    .ctx-menu button:hover { background: var(--accent); color: var(--bg-panel); }
  </style>
</head>
<body>
  <header>
    <div class=\"meta\">
      <h1 class=\"project\">" <> escape_html(project) <> "</h1>
      <code class=\"path\" title=\"" <> escape_html(source_path) <> "\">" <> escape_html(source_path) <> "</code>
    </div>
  </header>
" <> legend_html(t) <> "
  <main>
    <div id=\"cy\"></div>
    <div class=\"toolbar\">
      <button id=\"btn-collapse-all\">collapse all modules</button>
      <button id=\"btn-expand-all\">expand all modules</button>
      <button id=\"btn-fit\">fit</button>
      <button id=\"btn-freeze\" data-on=\"true\">freeze drag</button>
    </div>
    <div class=\"focus-info\" id=\"focus-info\"></div>
    <div class=\"hint\">
      hover to highlight neighbors · click a <b>type</b> to focus its neighborhood ·
      click a <b>function</b> to open its source · click a <b>collapsed module</b> to expand ·
      right-click anything for its source · click background to reset
    </div>
  </main>
  <script src=\"https://cdn.jsdelivr.net/npm/cytoscape@3.30.0/dist/cytoscape.min.js\"></script>
  <script src=\"https://cdn.jsdelivr.net/npm/layout-base@2.0.1/layout-base.js\"></script>
  <script src=\"https://cdn.jsdelivr.net/npm/cose-base@2.2.0/cose-base.js\"></script>
  <script src=\"https://cdn.jsdelivr.net/npm/cytoscape-fcose@2.2.0/cytoscape-fcose.js\"></script>
  <script src=\"https://cdn.jsdelivr.net/npm/cytoscape-expand-collapse@4.1.1/cytoscape-expand-collapse.js\"></script>
  <script>
    const NODES = [
" <> nodes_json <> "
    ];
    const EDGES = [
" <> edges_json <> "
    ];
    const T = " <> theme_json(t) <> ";

    const cy = cytoscape({
      container: document.getElementById('cy'),
      elements: { nodes: NODES, edges: EDGES },
      wheelSensitivity: 0.2,
      style: [
        // Module nodes — base style. The expanded form (handled by
        // the `:parent` override below) and the collapsed form
        // (`.cy-expand-collapse-collapsed-node`) need to be visually
        // unmistakable from each other and from regular type/function
        // nodes, otherwise the user can't tell at a glance \"is this a
        // module I should click to expand, or a noun I should click to
        // focus?\"
        { selector: 'node[kind=\"module\"]', style: {
            'shape': 'tag',
            'background-color': T.bg_cluster,
            'border-color': T.accent,
            'border-width': 2,
            'label': 'data(label)',
            'color': T.accent,
            'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
            'font-size': 16,
            'font-weight': 700,
            'padding': 14,
            'text-valign': 'center',
            'text-halign': 'center',
            'width': 'label',
            'height': 'label',
            // Long module paths (`gleam/dynamic/decode`) blow out the tag
            // horizontally if left unwrapped. Cap label width and let
            // cytoscape break on `/` and whitespace.
            'text-wrap': 'wrap',
            'text-max-width': 140,
            // `tag` shape draws a chevron on the right side; budget extra
            // horizontal room so the label doesn't crash into it.
            'text-margin-x': -8,
        }},
        // Collapsed module: tag shape, larger, with a `▸ ` chevron baked
        // into the label by the post-collapse code. Stronger border and
        // background so it reads as \"a thing you can pop open\" rather
        // than \"another typed node.\"
        { selector: 'node.cy-expand-collapse-collapsed-node', style: {
            'shape': 'tag',
            'background-color': T.bg_node_type,
            'background-opacity': 1,
            'border-color': T.accent,
            'border-width': 3,
            'font-size': 18,
            'font-weight': 700,
            'padding': 18,
            'width': 'label',
            'height': 'label',
            'text-wrap': 'wrap',
            'text-max-width': 160,
            'text-margin-x': -10,
        }},
        // When the module is expanded, it becomes a compound (`:parent`).
        // We drop the tag shape (compounds can only be rectangles), pin
        // the label to the top, and soften the background so contained
        // children stay legible.
        { selector: ':parent', style: {
            'shape': 'round-rectangle',
            'background-opacity': 0.45,
            'border-width': 1,
            'border-style': 'dashed',
            'font-size': 12,
            'font-weight': 600,
            'padding': 18,
            'text-valign': 'top',
            'text-margin-y': -6,
            'color': T.text,
        }},
        // Types — the named domain nouns. Solid `round-rectangle` with
        // a strong accent border and bold label — visually \"heavy\"
        // because nouns are what you navigate by.
        { selector: 'node[kind=\"tnode\"]', style: {
            'shape': 'round-rectangle',
            'background-color': T.bg_node_type,
            'border-color': T.accent, 'border-width': 1.4,
            'label': 'data(label)',
            'color': T.text,
            'text-valign': 'center', 'text-halign': 'center',
            'text-wrap': 'wrap', 'text-max-width': 220,
            'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
            'font-size': 13, 'font-weight': 600,
            'padding': 8,
            'width': 'label', 'height': 'label',
        }},
        // Function fan-ins — the verbs. Barrel shape + warm (amber)
        // border so they're clearly a different category from the
        // cool-pink types at a glance. Italic text reinforces
        // \"this is an action.\"
        { selector: 'node[kind=\"fnode\"]', style: {
            'shape': 'barrel',
            'background-color': T.bg_node_fn,
            'border-color': T.input_color,
            'border-width': 1.2,
            'label': 'data(label)',
            'color': T.text,
            'text-valign': 'center', 'text-halign': 'center',
            'text-wrap': 'wrap', 'text-max-width': 280,
            'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
            'font-size': 11,
            'font-style': 'italic',
            'padding': 10,
            'width': 'label', 'height': 'label',
        }},
        // @internal variants — same shapes, dashed border, dim text.
        { selector: 'node[kind=\"tnode-internal\"]', style: {
            'shape': 'round-rectangle',
            'background-color': T.bg_node_type,
            'border-color': T.accent_dim, 'border-width': 1.4,
            'border-style': 'dashed',
            'label': 'data(label)',
            'color': T.text_dim,
            'text-valign': 'center', 'text-halign': 'center',
            'text-wrap': 'wrap', 'text-max-width': 220,
            'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
            'font-size': 13, 'font-weight': 600,
            'padding': 8,
            'width': 'label', 'height': 'label',
        }},
        { selector: 'node[kind=\"fnode-internal\"]', style: {
            'shape': 'barrel',
            'background-color': T.bg_node_fn,
            'border-color': T.input_color,
            'border-width': 1.2,
            'border-style': 'dashed',
            'label': 'data(label)',
            'color': T.text_dim,
            'text-valign': 'center', 'text-halign': 'center',
            'text-wrap': 'wrap', 'text-max-width': 280,
            'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
            'font-size': 11,
            'font-style': 'italic',
            'padding': 10,
            'width': 'label', 'height': 'label',
        }},
        // Edges — base style for every edge (including the meta-edges the
        // expand-collapse plugin synthesises between collapsed compounds).
        { selector: 'edge', style: {
            'width': 1.2,
            'line-color': T.transform_color,
            'target-arrow-color': T.transform_color,
            'target-arrow-shape': 'triangle',
            'curve-style': 'bezier',
            'arrow-scale': 0.8,
        }},
        // Only edges that actually carry a `label` field can ever get text
        // rendered — mapping `data(label)` onto edges without that field
        // triggers cytoscape warnings and (under expand-collapse) a
        // re-style crash. `min-zoomed-font-size` does the show-when-readable
        // trick: at the overview zoom level the effective font size falls
        // below 9px and cytoscape hides the labels automatically, so the
        // graph reads as shapes; zoom in on a region and every label
        // appears once the text is big enough to actually read. Hover
        // overrides below set `text-opacity: 1` so highlighted edges
        // always show their labels regardless of zoom.
        { selector: 'edge[label]', style: {
            'label': 'data(label)',
            'min-zoomed-font-size': 9,
            'text-rotation': 'autorotate',
            'text-margin-y': -8,
            'font-size': 10,
            'color': T.text_dim,
            'text-background-color': T.bg_panel,
            'text-background-opacity': 0.85,
            'text-background-padding': 2,
            'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
        }},
        { selector: 'edge[kind=\"input\"]', style: {
            'line-color': T.input_color,
            'target-arrow-shape': 'circle',
            'target-arrow-color': T.input_color,
            'width': 1.4,
        }},
        { selector: 'edge[kind=\"output\"]', style: {
            'line-color': T.output_color,
            'target-arrow-color': T.output_color,
            'width': 1.6,
        }},
        // Highlight / dim classes — applied dynamically.
        { selector: '.dim', style: { 'opacity': 0.28 } },
        { selector: '.hl', style: { 'opacity': 1 } },
        { selector: 'node.hl-self', style: {
            'border-color': T.accent, 'border-width': 3,
        }},
        { selector: 'edge.hl-in', style: { 'width': 3, 'line-color': T.input_color, 'target-arrow-color': T.input_color, 'text-opacity': 1, 'color': T.text } },
        { selector: 'edge.hl-out', style: { 'width': 3, 'line-color': T.output_color, 'target-arrow-color': T.output_color, 'text-opacity': 1, 'color': T.text } },
        // When the user has clicked-to-focus a node, every edge in its
        // neighborhood gets `hl-focus` so its label is readable.
        { selector: 'edge.hl-focus[label]', style: { 'text-opacity': 1, 'color': T.text } },
        // Hovering the edge itself: thicken it, reveal its label.
        { selector: 'edge.hl-edge', style: {
            'width': 3,
            'line-color': T.accent,
            'target-arrow-color': T.accent,
            'text-opacity': 1,
            'color': T.text,
        }},
        // Hover highlight: every node that's being lit up — the
        // hovered node itself or any of its neighbors / the endpoints
        // of a hovered edge — triples in apparent size so it pops out
        // of the surrounding context. Cytoscape sizes nodes from their
        // label (`width:'label'`), so jacking the font-size auto-scales
        // the whole node box.
        { selector: 'node[kind=\"tnode\"].hl-self, node[kind=\"tnode-internal\"].hl-self, node[kind=\"tnode\"].hl-neighbor, node[kind=\"tnode-internal\"].hl-neighbor', style: {
            'font-size': 36,
            'border-width': 3,
            'padding': 14,
        }},
        { selector: 'node[kind=\"fnode\"].hl-self, node[kind=\"fnode-internal\"].hl-self, node[kind=\"fnode\"].hl-neighbor, node[kind=\"fnode-internal\"].hl-neighbor', style: {
            'font-size': 30,
            'border-width': 3,
            'padding': 16,
        }},
      ],
      layout: {
        name: 'fcose',
        quality: 'proof',
        randomize: false,
        animate: false,
        nodeSeparation: 150,
        idealEdgeLength: 180,
        nodeRepulsion: 8000,
        packComponents: true,
        tile: true,
        gravityRangeCompound: 1.5,
        gravityCompound: 1.0,
      },
    });

    // expand-collapse: double-click a module to fold/unfold it. The
    // post-collapse/expand layout uses `randomize: false` so fcose
    // starts from existing positions and only nudges things to make
    // room — a fully fresh random layout shuffles every module on
    // every expand.
    cy.expandCollapse({
      layoutBy: { name: 'fcose', randomize: false, animate: false, fit: false,
                  nodeSeparation: 150, idealEdgeLength: 180, nodeRepulsion: 8000,
                  quality: 'default' },
      fisheye: false,
      animate: true,
      animationDuration: 200,
      undoable: false,
      cueEnabled: false,
    });
    const ec = cy.expandCollapse('get');

    // When a module collapses, prefix its label with `▸ ` so the chevron
    // makes \"this is something you click to open\" unmistakable. Strip
    // the chevron back off when it expands again.
    const CHEVRON = '▸ ';
    function markCollapsed(n) {
      const lbl = n.data('label');
      if (lbl && !lbl.startsWith(CHEVRON)) n.data('label', CHEVRON + lbl);
    }
    function unmarkCollapsed(n) {
      const lbl = n.data('label');
      if (lbl && lbl.startsWith(CHEVRON)) n.data('label', lbl.slice(CHEVRON.length));
    }
    cy.on('expandcollapse.aftercollapse', 'node', (evt) => markCollapsed(evt.target));
    cy.on('expandcollapse.afterexpand', 'node', (evt) => unmarkCollapsed(evt.target));

    // Start with every module collapsed — far less visual load on first
    // view. The user expands the modules they care about. Defer until
    // after the initial layout settles, otherwise expand-collapse can
    // crash trying to restyle elements that cytoscape is still creating.
    requestAnimationFrame(() => {
      try { ec.collapseAll(); }
      catch (e) { console.warn('collapseAll failed, leaving expanded:', e); }
      // Always fit, even if collapseAll threw — otherwise an
      // expand-collapse hiccup leaves the user staring at an off-
      // viewport graph.
      cy.fit(null, 60);
    });
    cy.on('dbltap', ':parent', (evt) => {
      const t = evt.target;
      if (ec.isCollapsible(t)) ec.collapse(t);
      else if (ec.isExpandable(t)) ec.expand(t);
    });

    // Hover: highlight 1-hop predecessors (input edges) and successors
    // (output edges) AND the neighbor nodes themselves. Dim everything
    // else.
    //
    // `keep` includes:
    //   - the hovered node + its closed neighborhood (neighbors + edges)
    //   - every ancestor compound of any kept node — cytoscape's
    //     opacity cascades from a compound to its children, so if a
    //     neighbor's module is dim, the neighbor renders dim too.
    cy.on('mouseover', 'node', (evt) => {
      const n = evt.target;
      if (n.isParent()) return;
      const hood = n.closedNeighborhood();
      const keep = hood.union(hood.ancestors());
      cy.elements().not(keep).addClass('dim');
      n.addClass('hl-self');
      hood.nodes().not(n).addClass('hl-neighbor');
      n.incomers('edge').addClass('hl-in');
      n.outgoers('edge').addClass('hl-out');
    });
    cy.on('mouseout', 'node', () => {
      cy.elements().removeClass('dim hl-self hl-neighbor hl-in hl-out');
    });

    // Undo stack for view changes. We snapshot the *visibility* state
    // of every element (which are hidden, which are shown) plus the
    // current focus level/node before any narrowing action runs.
    // `Ctrl+Z` / `Cmd+Z` and the toolbar 'undo' button pop the most
    // recent snapshot. Cap the stack so a long browsing session
    // doesn't leak memory.
    const UNDO_MAX = 30;
    const undoStack = [];
    function snapshotView() {
      const hidden = [];
      cy.nodes().forEach((n) => { if (n.style('display') === 'none') hidden.push(n.id()); });
      return { hidden, focusedId: focused ? focused.id() : null, focusLevel };
    }
    function pushUndo() {
      undoStack.push(snapshotView());
      while (undoStack.length > UNDO_MAX) undoStack.shift();
    }
    function restoreView(snap) {
      const hiddenSet = new Set(snap.hidden);
      cy.nodes().forEach((n) => {
        n.style('display', hiddenSet.has(n.id()) ? 'none' : 'element');
      });
      if (snap.focusedId) {
        focused = cy.getElementById(snap.focusedId);
        focusLevel = snap.focusLevel;
        cy.elements('edge').removeClass('hl-focus');
        const keep = computeKeep(focused);
        keep.edges().addClass('hl-focus');
        const lbl = (focused.data('label') || focused.id()).split('\\n')[0];
        const hint = focusLevel === 2
          ? ' — all neighbors (click again to reset)'
          : ' (click again to include hidden neighbors)';
        focusInfo.innerHTML = 'focused on <code>' + lbl + '</code>' + hint;
        focusInfo.classList.add('active');
      } else {
        focused = null;
        focusLevel = 0;
        cy.elements('edge').removeClass('hl-focus');
        focusInfo.classList.remove('active');
      }
    }
    function undo() {
      if (undoStack.length === 0) return;
      restoreView(undoStack.pop());
    }
    document.addEventListener('keydown', (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === 'z') { e.preventDefault(); undo(); }
    });

    // Click a node = focus mode, with two narrowing levels:
    //
    //   Level 1 (first click): hide every currently-visible element
    //   that isn't in this node's neighborhood. Already-hidden nodes
    //   stay hidden, so this narrows in *within* the current view.
    //
    //   Level 2 (click the same node again): same as level 1 *plus*
    //   resurrect any previously-hidden neighbors. Useful when you've
    //   manually hidden things and want to bring them back to see the
    //   node's full surroundings.
    //
    //   Level 3 (third click): unfocus.
    //
    // For an expanded module compound, the \"neighborhood\" is the
    // union of the module + all its children + every node any child
    // is connected to — answering \"who does this module talk to?\"
    let focused = null;
    let focusLevel = 0;
    const focusInfo = document.getElementById('focus-info');
    function computeKeep(node) {
      if (node.isParent()) {
        const inside = node.union(node.descendants());
        return inside.union(node.descendants().closedNeighborhood());
      }
      return node.closedNeighborhood();
    }
    function focusOn(node, resurrect) {
      focused = node;
      const keep = computeKeep(node);
      cy.elements().difference(keep).style('display', 'none');
      if (resurrect) keep.style('display', 'element');
      cy.elements('edge').removeClass('hl-focus');
      keep.edges().addClass('hl-focus');
      cy.fit(keep.filter(el => el.visible()), 40);
      const lbl = (node.data('label') || node.id()).split('\\n')[0];
      const hint = resurrect
        ? ' — all neighbors (click again to reset)'
        : ' (click again to include hidden neighbors)';
      focusInfo.innerHTML = 'focused on <code>' + lbl + '</code>' + hint;
      focusInfo.classList.add('active');
    }
    function unfocus() {
      focused = null;
      focusLevel = 0;
      cy.elements().style('display', 'element');
      cy.elements('edge').removeClass('hl-focus');
      focusInfo.classList.remove('active');
      cy.fit(null, 40);
    }
    cy.on('tap', 'node', (evt) => {
      const n = evt.target;
      // Tapping a collapsed compound expands it — focusing on a collapsed
      // module just shows meta-edges to other modules, hiding every type
      // and function inside, which is the opposite of what the user
      // wants. Expanding reveals the contents; a follow-up tap on the
      // expanded compound focuses on its full neighborhood.
      if (ec.isExpandable(n)) { ec.expand(n); return; }
      // Functions are verbs — tapping one is an action: jump to its
      // hex docs / github source.
      const kind = n.data('kind');
      if (kind === 'fnode' || kind === 'fnode-internal') {
        const href = n.data('href');
        if (href) window.open(href, '_blank');
        return;
      }
      // Type nodes (nouns) and expanded module compounds focus, with
      // repeated taps on the same node cycling through narrowing levels.
      pushUndo();
      if (focused && focused.same(n)) {
        if (focusLevel === 1) {
          focusLevel = 2;
          focusOn(n, true);
        } else {
          unfocus();
        }
      } else {
        focusLevel = 1;
        focusOn(n, false);
      }
    });
    cy.on('tap', (evt) => {
      if (evt.target === cy && focused) { pushUndo(); unfocus(); }
    });

    // Click a labelled edge (= a single-arg function) to open its
    // source. These edges represent functions like
    // `bytes_tree.from_string_tree(StringTree) -> BytesTree` that
    // aren't fan-in nodes but are still callable code.
    cy.on('tap', 'edge', (evt) => {
      const href = evt.target.data('href');
      if (href) window.open(href, '_blank');
    });
    // Hover an edge: same dim-everything-else treatment as hovering
    // a node, but the \"keep\" set is the edge + its source + target
    // (and their ancestor compounds, so dimming a parent doesn't
    // cascade down to the endpoints). The edge itself gets `hl-edge`
    // so the label appears and the line thickens.
    cy.on('mouseover', 'edge', (evt) => {
      const e = evt.target;
      if (e.data('href')) cyEl.classList.add('cy-pointing');
      const endpoints = e.source().union(e.target());
      const keep = endpoints.union(e).union(endpoints.ancestors());
      cy.elements().not(keep).addClass('dim');
      endpoints.addClass('hl-neighbor');
      e.addClass('hl-edge');
    });
    cy.on('mouseout', 'edge', () => {
      cyEl.classList.remove('cy-pointing');
      cy.elements().removeClass('dim hl-neighbor hl-edge');
    });

    // Right-click context menu. Sticky HTML menu — appears on right-
    // click, stays until the user picks an option or clicks elsewhere.
    // The radial cxtmenu plugin closes on mouse-release, which surprised
    // anyone who right-clicks and lifts off before dragging to a slice.
    const ctxMenu = document.createElement('div');
    ctxMenu.className = 'ctx-menu';
    ctxMenu.style.display = 'none';
    document.body.appendChild(ctxMenu);
    function showCtxMenu(node, x, y) {
      const items = [];
      items.push({ label: 'focus neighbors', fn: () => focusOn(node) });
      if (ec.isExpandable(node)) {
        items.push({ label: 'expand module', fn: () => ec.expand(node) });
      } else if (ec.isCollapsible(node)) {
        items.push({ label: 'collapse module', fn: () => ec.collapse(node) });
      }
      const href = node.data('href');
      if (href) items.push({ label: 'open source ↗', fn: () => window.open(href, '_blank') });
      items.push({ label: 'hide', fn: () => { pushUndo(); node.style('display', 'none'); } });
      ctxMenu.innerHTML = '';
      items.forEach((it) => {
        const b = document.createElement('button');
        b.textContent = it.label;
        b.addEventListener('click', () => { hideCtxMenu(); it.fn(); });
        ctxMenu.appendChild(b);
      });
      // Clamp inside the viewport so the menu doesn't fall off-screen.
      const vw = window.innerWidth, vh = window.innerHeight;
      ctxMenu.style.display = 'block';
      const w = ctxMenu.offsetWidth, h = ctxMenu.offsetHeight;
      ctxMenu.style.left = Math.min(x, vw - w - 4) + 'px';
      ctxMenu.style.top = Math.min(y, vh - h - 4) + 'px';
    }
    function hideCtxMenu() { ctxMenu.style.display = 'none'; }
    cy.on('cxttap', 'node', (evt) => {
      const pos = evt.originalEvent;
      showCtxMenu(evt.target, pos.clientX, pos.clientY);
    });
    // Any click outside the menu (including taps on the canvas or
    // another node) dismisses it.
    document.addEventListener('mousedown', (e) => {
      if (!ctxMenu.contains(e.target)) hideCtxMenu();
    });
    cy.on('tap pan zoom', hideCtxMenu);

    // Magnetic drag: when the user drags a node, every connected
    // neighbor drifts by a fraction of the drag delta — as if the
    // edges were elastic. `PULL = 0.4` of the delta for direct
    // neighbors, `PULL_2 = 0.15` for neighbors-of-neighbors so the
    // influence softly fades. Compound modules and locked nodes are
    // ignored.
    const PULL = 0.4;
    const PULL_2 = 0.15;
    let magneticDrag = true; // toggled by the freeze button
    let dragAnchor = null;
    cy.on('grab', 'node', (evt) => {
      const n = evt.target;
      if (!magneticDrag) { dragAnchor = null; return; }
      if (n.isParent()) { dragAnchor = null; return; }
      dragAnchor = { id: n.id(), x: n.position('x'), y: n.position('y') };
    });
    cy.on('drag', 'node', (evt) => {
      const n = evt.target;
      if (!dragAnchor || dragAnchor.id !== n.id()) return;
      const cur = n.position();
      const dx = cur.x - dragAnchor.x;
      const dy = cur.y - dragAnchor.y;
      dragAnchor = { id: n.id(), x: cur.x, y: cur.y };
      const neighbors = n.openNeighborhood('node')
        .filter(m => !m.locked() && !m.isParent() && !m.same(n));
      neighbors.forEach(m => {
        const p = m.position();
        m.position({ x: p.x + dx * PULL, y: p.y + dy * PULL });
      });
      const second = neighbors.openNeighborhood('node')
        .difference(neighbors).difference(n)
        .filter(m => !m.locked() && !m.isParent());
      second.forEach(m => {
        const p = m.position();
        m.position({ x: p.x + dx * PULL_2, y: p.y + dy * PULL_2 });
      });
    });
    cy.on('free', 'node', () => { dragAnchor = null; });

    // Cursor management: classes on #cy override the base `grab` cursor.
    // `cy-pointing` shows the finger only over nodes whose left-click
    // actually does something — a type node (focus), a function node with
    // an href (opens source), or a collapsed module (expand). Function
    // nodes without an href, or expanded compounds, keep the open-hand
    // cursor because the only thing you can do with them is drag.
    // `cy-grabbing` shows the closed hand while panning or dragging.
    const cyEl = document.getElementById('cy');
    function isInteractable(n) {
      // Collapsed module → click to expand. Expanded module → click to
      // focus on its neighborhood. Either way it's clickable.
      if (ec.isExpandable(n)) return true;
      if (n.isParent()) return true;
      const kind = n.data('kind');
      if (kind === 'tnode' || kind === 'tnode-internal') return true;
      if ((kind === 'fnode' || kind === 'fnode-internal') && n.data('href')) return true;
      return false;
    }
    cy.on('mouseover', 'node', (evt) => {
      if (isInteractable(evt.target)) cyEl.classList.add('cy-pointing');
    });
    cy.on('mouseout', 'node', () => cyEl.classList.remove('cy-pointing'));
    cy.on('grabon', 'node', () => cyEl.classList.add('cy-grabbing'));
    cy.on('freeon', 'node', () => cyEl.classList.remove('cy-grabbing'));
    cyEl.addEventListener('mousedown', () => cyEl.classList.add('cy-grabbing'));
    window.addEventListener('mouseup', () => cyEl.classList.remove('cy-grabbing'));

    document.getElementById('btn-collapse-all').addEventListener('click', () => {
      ec.collapseAll();
    });
    document.getElementById('btn-expand-all').addEventListener('click', () => {
      ec.expandAll();
    });
    document.getElementById('btn-fit').addEventListener('click', () => {
      if (focused) cy.fit(focused.closedNeighborhood(), 40);
      else cy.fit(null, 40);
    });
    document.getElementById('btn-freeze').addEventListener('click', (e) => {
      magneticDrag = !magneticDrag;
      e.target.textContent = magneticDrag ? 'freeze drag' : 'unfreeze drag';
      e.target.dataset.on = magneticDrag ? 'true' : 'false';
    });
  </script>
</body>
</html>"
}

/// Theme record → small JS object so the cytoscape stylesheet can reference
/// the same palette as the rest of the page.
fn theme_json(t: Theme) -> String {
  "{ "
  <> "bg_panel: \"" <> t.bg_panel <> "\", "
  <> "bg_cluster: \"" <> t.bg_cluster <> "\", "
  <> "bg_node_type: \"" <> t.bg_node_type <> "\", "
  <> "bg_node_fn: \"" <> t.bg_node_fn <> "\", "
  <> "accent: \"" <> t.accent <> "\", "
  <> "accent_dim: \"" <> t.accent_dim <> "\", "
  <> "text: \"" <> t.text <> "\", "
  <> "text_dim: \"" <> t.text_dim <> "\", "
  <> "transform_color: \"" <> t.transform_color <> "\", "
  <> "input_color: \"" <> t.input_color <> "\", "
  <> "output_color: \"" <> t.output_color <> "\""
  <> " }"
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
