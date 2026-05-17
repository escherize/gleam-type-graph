/// Color palette for the HTML/mermaid renderer.
///
/// Themes are immutable records of CSS hex strings, threaded through every
/// public renderer function. The CLI selects one by name (`--theme dark|light`,
/// defaulting to `dark`). New themes are just new constructor functions —
/// add the function, add a branch in `parse/1`, ship.
///
/// Semantics:
///
/// - **page chrome** (bg_page, bg_panel, bg_legend, border, text, text_dim,
///   code_bg) — purely cosmetic. Move freely without breaking meaning.
/// - **accents** (accent, accent_dim) — visual hierarchy: accent is the
///   "domain noun" color on type-rectangle borders + the project name;
///   accent_dim is the "function verb" color on fan-in borders.
/// - **diagram surfaces** (bg_cluster, bg_node_type, bg_node_fn) — the
///   filled regions inside the SVG. Cosmetic.
/// - **edge colors** (input_color, output_color, transform_color) — SEMANTIC.
///   They appear in three places that *must* stay in lockstep: the mermaid
///   `linkStyle` directive (line stroke), the SVG `<marker>` definition
///   (arrowhead/circle fill), and the inline `<svg>` legend swatch. Changing
///   one without the others produces a diagram whose legend lies.
pub type Theme {
  Theme(
    bg_page: String,
    bg_panel: String,
    bg_legend: String,
    border: String,
    text: String,
    text_dim: String,
    code_bg: String,
    accent: String,
    accent_dim: String,
    bg_cluster: String,
    bg_node_type: String,
    bg_node_fn: String,
    input_color: String,
    output_color: String,
    transform_color: String,
  )
}

/// Default theme — navy/cream/pink stolen from Gleam's hexdocs.
pub fn dark() -> Theme {
  Theme(
    bg_page: "#1e2233",
    bg_panel: "#15182a",
    bg_legend: "#1a1d2c",
    border: "#2a2f45",
    text: "#e3d8be",
    text_dim: "#8c8fa3",
    code_bg: "#11131f",
    accent: "#ffaff3",
    accent_dim: "#d099d4",
    bg_cluster: "#1e2233",
    bg_node_type: "#1a1d2c",
    bg_node_fn: "#171a29",
    input_color: "#ff9d35",
    output_color: "#98c379",
    transform_color: "#6b6e85",
  )
}

/// Light theme — white background, darker pink/orange/green for legibility.
pub fn light() -> Theme {
  Theme(
    bg_page: "#ffffff",
    bg_panel: "#fafbfc",
    bg_legend: "#f5f5f7",
    border: "#e0e0e6",
    text: "#1f1f24",
    text_dim: "#6b6b76",
    code_bg: "#f5f5f7",
    accent: "#a6033f",
    accent_dim: "#d099d4",
    bg_cluster: "#fff5fc",
    bg_node_type: "#ffffff",
    bg_node_fn: "#fff5fc",
    input_color: "#d97706",
    output_color: "#16a34a",
    transform_color: "#888888",
  )
}

pub fn parse(name: String) -> Result(Theme, String) {
  case name {
    "dark" -> Ok(dark())
    "light" -> Ok(light())
    other -> Error("unknown theme: " <> other <> " (try dark|light)")
  }
}
