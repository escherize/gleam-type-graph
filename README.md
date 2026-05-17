# gleam-type-graph

Statically extract a directed graph of **types** and **the functions that
transform them** from a Gleam codebase.

- **Nodes** = types (`Order`, `OrderSnapshot`, `Json`, `String`, ...)
- **Edges** = functions that turn one type into another (`order.snapshot`,
  `json.to_string`, ...)

Read the resulting graph as: *to convert an `X` into a `Y`, here's the path
of functions to compose.*

## Quick start

```sh
cd /your/gleam/project
npx gleam-type-graph --open
```

That's it. From inside any Gleam project (or any subdirectory of one), this
walks up to find your `gleam.toml`, scans `src/`, renders an interactive
mermaid diagram, and opens it in your browser.

No `gleam` toolchain required on your machine — the tool ships pre-compiled
to JavaScript.

## Other invocations

```sh
# Mermaid to stdout (good for piping into a markdown file)
npx gleam-type-graph

# Sorted plain-text edge list, easiest to grep / diff
npx gleam-type-graph --format text

# Drop edges between stdlib / primitive types — show just the domain core
npx gleam-type-graph --domain-only --open

# Graphviz dot (for `dot -Tpng -o graph.png`)
npx gleam-type-graph --format=dot > graph.dot
dot -Tpng graph.dot -o graph.png

# JSON for downstream tooling
npx gleam-type-graph --format=json > graph.json

# Point at a specific src/ tree
npx gleam-type-graph /some/other/project/src --open
```

## Example output

Given a project with `Order`, `OrderSnapshot`, `Money`, `CustomerId`, and a
JSON encoder:

```sh
$ npx gleam-type-graph --format text
Int                  --[money.from_cents]--> money.Money
String               --[customer.new_id]--> customer.CustomerId
String               --[order.new_id]--> order.OrderId
money.Money          --[money.to_cents]--> Int
money.Money          --[money.to_json]--> json.Json
order.Order          --[order.order_to_json]--> json.Json
order.Order          --[order.snapshot]--> order.OrderSnapshot
order.OrderSnapshot  --[order.restore]--> order.Order
```

Two seconds of reading and you know:

- `String → OrderId` and `String → CustomerId` are smart constructors
- `Order ↔ OrderSnapshot` is a symmetric snapshot/restore pair
- The path to put an `Order` on disk is
  `Order → snapshot → OrderSnapshot → order_to_json → Json → ...`

With `--domain-only` the same project collapses to just the user-defined
core:

```sh
$ npx gleam-type-graph --format text --domain-only
order.Order          --[order.snapshot]--> order.OrderSnapshot
order.OrderSnapshot  --[order.restore]--> order.Order
```

When a function takes multiple typed parameters — say
`make_order(c: CustomerId, id: OrderId, total: Money) -> Order` — the
output groups the inputs to make the *and*-relation visible:

```
{customer.CustomerId, money.Money, order.OrderId} --[order.make_order]--> order.Order
```

In mermaid / dot this renders as a single fan-in node that all inputs flow
into and the return type flows out of, so a reader can see at a glance that
all three inputs are required.

## CLI

```
Usage: gleam-type-graph [PATH] [OPTIONS]

Arguments:
  PATH                Directory to scan. If omitted, walks up from cwd
                      looking for gleam.toml and uses its src/.

Options:
  --format <FMT>      Output format: mermaid|dot|json|text|html
                      (default: html when --open, mermaid otherwise)
  --open              Render to a temp file and open in your browser
  --include <PAT>     Module substring to include (repeatable)
  --exclude <PAT>     Module substring to exclude (repeatable)
  --domain-only       Drop edges touching stdlib / primitives
  -h, --help          Show this help
```

`--include` and `--exclude` match the substring against either endpoint
module *or* the function label, so `--include order` keeps every edge
involving the `order` module on either side.

## How edges are derived

For a single-arg public function `module.fn(p: T) -> R`:

- One edge `T → R`, labelled `module.fn`

For a multi-arg public function `module.fn(p1: T1, p2: T2, ...) -> R`:

- A synthetic *fan-in node* `module.fn()` is introduced (rendered as a
  stadium in mermaid, an ellipse in dot, `{...}` braces in text).
- Each typed parameter type flows *into* the fan-in node; the return type
  flows *out*. Reads as: "you need T1 **and** T2 **and** ... to produce R."
- Duplicate input types are deduped, so `merge(Order, Order, String) -> Order`
  shows `{Order, String}` flowing into the fan-in, with Order also flowing
  out as a self-cycle.

Across both cases:

- `Result(T, E)` returns are unwrapped to `T` (the success path is the
  transformation; the error type is metadata)
- `Option(T)` returns are unwrapped to `T`
- `List(T) → List(S)` is unwrapped to `T → S` (container-preserving)

Type references are resolved through the module's import table:

- `import app/order.{type OrderSnapshot}` — `OrderSnapshot` resolves to
  `app/order.OrderSnapshot`
- `import app/order as o` — `o.OrderSnapshot` resolves to
  `app/order.OrderSnapshot`
- `import app/order` — `order.OrderSnapshot` resolves the same way

Unresolvable qualified references show up as `Unknown(module.Type)` rather
than crashing the run.

## Limitations (MVP scope)

- Only `src/` is parsed. `test/` and `build/packages/<dep>/src/` aren't
  crawled yet.
- Only public functions are included.
- Type aliases are treated as opaque — `pub type UserId = String` shows up
  as `UserId`, not `String`.
- Generic types collapse to their base name — `List(Order)` and
  `List(OrderSnapshot)` aren't distinguished beyond the container-preserving
  rule.

These are tracked as stretch goals in `../type_graph_tool.md`.

## Development

```sh
gleam build                                # Compile (requires Gleam ≥ 1.x)
gleam test                                 # Run tests (none yet)
./bin/gleam-type-graph.mjs ./src           # Run the local binary
npm pack && npx ./gleam-type-graph-*.tgz   # Smoke-test the npm package
```

The pipeline is small enough to read top-to-bottom:

```
src/type_graph.gleam              # CLI + pipeline
src/type_graph/parse.gleam        # walk src/, parse with `glance`
src/type_graph/extract.gleam      # AST → edges, with import resolution
src/type_graph/filter.gleam       # primitive / stdlib / pattern filters
src/type_graph/render.gleam       # mermaid | dot | json | text | html
src/type_graph/sys.gleam          # tmp file + open-in-browser
src/type_graph_ffi.mjs            # JS FFI for sys
bin/gleam-type-graph.mjs          # npm bin shim
```

## License

MIT.
