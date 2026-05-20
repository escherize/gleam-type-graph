# todos

Living scratchpad of next steps. Not a roadmap — just things noted as
they come up so they don't get lost.

## interaction polish

- **Tween the hover-highlight scaling.** Currently `hl-self` and
  `hl-neighbor` jump from the base font-size (11–13px) to the
  highlighted size (30–36px) instantly. Cytoscape has built-in
  transition support via `transition-property` / `transition-duration`
  / `transition-timing-function` on style entries. Wire those up so
  the grow-and-shrink animates over ~120ms with an ease-out curve.
  Same for `hl-edge`'s width and `hl-in`/`hl-out`.

## layout

- **Orbital constraints** — see [`orbital-layout.md`](orbital-layout.md).
  The primitives stay in the middle, modules orbit them.

- **Per-module local layout on first expand** — currently the global
  fcose runs (`randomize: false`) after every expand. For very dense
  modules this still nudges everyone. Run a layout scoped only to the
  expanded module's compound, with the rest locked, to keep the
  surrounding view stable.

## model

- **Every function as a node (option 1B)** — currently single-arg
  functions are edge labels, multi-arg functions are fan-in nodes.
  Mixed model has UX friction (the labels look like nodes but
  aren't clickable in the same way). The proper fix is uniformity at
  the cost of ~2x visible elements. Could ship with a `--compact`
  flag that re-collapses single-arg fns to edge labels for browsing.

## tooling

- **Search box** — type a name, jump to / highlight the matching node.

- **Save layout to disk** — once a user has dragged the graph into a
  nice shape, persist node positions (LocalStorage keyed by source
  path + commit hash) so the next open restores it.

- **SVG / PNG export** — `cytoscape-svg` plugin. One-button "send
  this diagram to a teammate".
