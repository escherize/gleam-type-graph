# Orbital layout: clean force-directed graphs at stdlib scale

The cytoscape view currently uses fcose with sensible defaults
(`nodeSeparation: 150`, `idealEdgeLength: 180`, `packComponents: true`).
At small scale (the `paint` project) this looks great. At stdlib scale
(~17 modules, ~150 nodes, ~500 edges) it produces a readable but messy
hairball: the primitive types (`Int`, `String`, `BitArray`, `Fn`,
`List`, ...) cluster in the centre and every module connects to them,
so the layout pulls modules toward the centre and edges cross
heavily.

The proposal is to add **fcose relative-placement constraints** so the
layout is no longer a pure spring solver — it has structural rules
that match how the graph "wants" to be read.

## The shape we want

```
              gleam/uri          gleam/bit_array
                  \\                 /
   gleam/string  ──   PRIMITIVES   ── gleam/result
                  /                 \\
              gleam/list          gleam/option
                  ...                ...
```

A core of primitives sits in the middle of the canvas. Every module
orbits the core. The radial position of each module is roughly
proportional to how connected it is to the core (highly-connected
modules sit close, leaf modules farther out). Parameterized type
nodes (`List(Int)`, `Result(Order, Nil)`) sit on a thin ring just
outside the core — close enough that you read "List(Int) is a kind of
List", far enough that they don't crowd `List` itself.

This is the standard "core–periphery" decomposition from network
analysis, mapped onto a force layout.

## Why fcose can do this

fcose accepts a `relativePlacementConstraint` array, where each entry
declares one of:

- `{ top: nodeA, bottom: nodeB, gap: 100 }` — A always above B with at
  least gap pixels between them
- `{ left: nodeA, right: nodeB, gap: 100 }` — A always to the left of B
- `{ alignmentConstraint: { horizontal: [n1, n2, n3] } }` — listed
  nodes share a Y coordinate
- `{ alignmentConstraint: { vertical: [n1, n2, n3] } }` — share an X

Plus `fixedNodeConstraint` to pin specific nodes at specific
coordinates, and `alignmentConstraint` at the layout-options level.

These constraints are honored by the solver as hard rules. Edge
springs still pull nodes around, but only within the manifold the
constraints allow. The result: spring-like organic layout *plus*
human-imposed structure.

## Recipe

1. **Identify the primitive core.** Walk the graph; any node where
   `kind == 'tnode'` and the TypeRef is `Primitive(_, [])` or `FunctionT`
   or `Tuple` goes into the core set. For stdlib that's `Int`, `Float`,
   `String`, `Bool`, `Nil`, `BitArray`, `Fn`, `Tuple`, `List`.
2. **Pin the core's centroid at (0, 0).** Add a
   `fixedNodeConstraint` for the highest-degree primitive (typically
   `String` or `List`) and let the others align around it via a
   `circle` constraint generator.
3. **Compute module ring positions.** Sort modules by edge count to
   the core, then space them around `(cos θ, sin θ) * radius` where
   `radius = base + degree * scale`. Pass these as
   `fixedNodeConstraint` *or* as an `alignmentConstraint` group with a
   relative-placement gap from the core.
4. **Place parameterized types just outside the core.** Each
   `List(Order)`-style node gets a `relativePlacementConstraint`
   pulling it next to (a) its element type and (b) its bare-form
   cousin. This is the visual story "this is a `List` carrying
   `Order`".
5. **Inside each module compound**, fcose lays out children freely as
   today — no constraints needed; the parent's bounding box does
   the work.

## Anti-patterns

- **Don't pin everything.** Constraints stack additively; over-constrain
  and fcose fails to find a feasible layout (it'll silently produce a
  garbage one). Pin one primitive, anchor the rest with relative
  placements.
- **Don't constrain by edge count alone.** A highly-connected module
  could still be semantically peripheral. If you ever expose
  "important modules" metadata, prefer that signal.
- **Don't fix positions across runs.** Different projects have
  different primitive hubs. Compute the constraints from the parsed
  graph each time.

## Sketch of the Gleam side

```gleam
pub type LayoutHint {
  CoreNode(ref: TypeRef)
  ModuleRing(module: String, angle_step: Float, radius: Float)
  ParamSatellite(param: TypeRef, parent_bare: TypeRef)
}

pub fn hint_layout(edges: List(Edge)) -> List(LayoutHint) {
  let core = collect_primitives(edges)
  let modules = collect_modules(edges) |> sort_by_core_degree(core)
  let satellites = collect_parameterized_nodes(edges)
  ...
}
```

These hints emit as JSON alongside the existing nodes/edges blob, and
the JS reads them when assembling the fcose `layout` options.

## Cost

- ~1 day to implement and tune
- Adds ~50 lines of Gleam (hint extraction) and ~40 lines of JS
  (constraint assembly)
- Per-render cost is negligible compared to fcose's solve time

## Open questions

- Does fcose's constraint solver scale to 150 nodes plus dozens of
  constraints? Bilkent's paper benchmarks up to 1000 nodes / 50
  constraints with sub-second runtimes — comfortably within our
  bounds.
- Should constraints be opt-in via `--layout=orbital` or always on?
  Probably opt-in for the first cut; the default fcose layout works
  well enough that orbital is a "looks nicer at large scale" lever
  rather than a correctness fix.
- Interaction with expand-collapse: when a module expands, its
  children appear inside its compound. The orbital constraint still
  applies to the compound itself (the ring position), so expansion
  doesn't reshuffle the global layout — just the module's local
  contents.
