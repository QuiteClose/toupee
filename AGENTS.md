# Toupee

Build-time HTML template engine in Zig. Processes `<t-*>` custom elements to produce clean HTML. Designed as an embeddable library for static site generators.

**Brand:** "HTML templates, zero magic."

## Architecture

Two-phase pipeline: parse template source into a flat `[]Node` IR, then render the IR against a data context.

```
template source ([]const u8)
        │
   Parser.parse()
        │
   []Node (IR)        ← immutable, cacheable
        │
   Renderer.render()  ← takes Context + Resolver
        │
   output ([]const u8)
```

The IR is a flat `[]Node` tagged union slice (not a tree). Nesting is expressed through child slices into the same array. All node memory is arena-allocated; freeing the arena frees all nodes.

## Module Map

| File | Lines | Responsibility |
| --- | --- | --- |
| `root.zig` | 228 | Public API: `Engine`, `render()`, `renderFormatted()`, `RenderResult`, type re-exports |
| `Parser.zig` | 1073 | Template source → `[]Node` IR. Single-pass recursive descent. |
| `Renderer.zig` | 899 | `[]Node` IR + Context → output string. Visitor over the node array. |
| `Node.zig` | 365 | IR type definitions: 13-variant tagged union + supporting structs |
| `Context.zig` | 213 | `Context`, `Resolver`, `ErrorDetail`, `IncludeEntry`, `RenderError` |
| `Value.zig` | 305 | `Value` tagged union (`string`, `boolean`, `integer`, `list`, `map`, `nil`), dot-path resolution |
| `transform.zig` | 389 | `Registry`, `TransformFn`, 20 built-in transforms |
| `html.zig` | 131 | Tag parsing, attribute extraction, HTML escaping |
| `indent.zig` | 227 | Indentation propagation, common-indent stripping |
| `format.zig` | 145 | Post-render HTML pretty-printer (2-space indent) |
| `test_runner.zig` | 401 | `.test` file parser/runner with ErrorDetail assertions |
| `bench.zig` | 145 | Performance benchmarks (parse, render, cached, pipeline) |
| `fuzz.zig` | 54 | Fuzz targets for Parser and Renderer |
| `main.zig` | 6 | CLI stub (not yet implemented) |

## Public API (`root.zig`)

### Engine (configured usage)

```zig
var engine = try toupee.Engine.init(allocator);
defer engine.deinit();

try engine.addTemplate("page.html", source);    // parse + cache IR
try engine.registerTransform("date", dateFn);    // custom transform

const result = try engine.renderTemplate(allocator, "page.html", &ctx, &resolver, .{});
defer allocator.free(result);
```

### Convenience (one-shot usage)

```zig
const result = try toupee.render(allocator, source, &ctx, &resolver, .{});
defer allocator.free(result);
```

### Options

| Field | Type | Default | Purpose |
| --- | --- | --- | --- |
| `template_name` | `[]const u8` | `"<input>"` | Name shown in error messages |
| `template_source` | `[]const u8` | `""` | Source for error excerpts |
| `registry` | `?*const Registry` | `null` | Transform registry (auto-set by Engine) |
| `strict` | `bool` | `true` | Error on undefined variables without defaults |
| `debug` | `bool` | `false` | Enable `<t-debug />` context dumps |
| `max_depth` | `usize` | `50` | Maximum include/extend nesting depth |

### RenderResult (owned output)

```zig
const result = try engine.renderOwned(allocator, source, &ctx, &resolver, .{});
defer result.deinit();
// result.output is the rendered string
```

## Template Elements (13 total)

| Element | Purpose |
| --- | --- |
| `<t-var name="x" />` | Output variable (HTML-escaped). Block form provides default: `<t-var name="x">fallback</t-var>` |
| `<t-raw name="x" />` | Output variable (unescaped). Same block form for defaults. |
| `<t-if var="x">` | Conditional. Checks existence by default. Supports `equals`, `not-equals`, `not-exists`, `contains`, `starts-with`, `ends-with`, `matches` (glob). Also `attr="x"`, `slot="x"`. |
| `<t-elif var="y" />` | Branch separator within `<t-if>` (self-closing) |
| `<t-else />` | Else separator within `<t-if>` or `<t-for>` (self-closing) |
| `<t-for item in collection>` | Loop. Supports `sort`, `order`, `limit`, `offset`, `as alias`. For-else: `<t-for ...>...<t-else />empty</t-for>` |
| `<t-let name="x">content</t-let>` | Capture rendered content into a variable |
| `<t-extend template="base.html">` | Template inheritance. Contains `<t-define>` children. |
| `<t-slot name="x" />` | Insertion point in parent template. Block form for defaults. |
| `<t-define name="x">content</t-define>` | Fill a slot (inside `<t-extend>` or `<t-include>`) |
| `<t-include template="x.html" />` | Include a component. Supports attributes and `<t-define>` children. |
| `<t-attr name="x" />` | Output an include attribute value |
| `<t-comment>ignored</t-comment>` | Stripped from output |
| `<t-debug />` | Context dump (only when `debug: true` in Options) |

### Attribute bindings

```html
<a t-var:href="url">link</a>        <!-- binds variable to HTML attribute -->
<div t-attr:class="variant">        <!-- binds include attribute to HTML attribute -->
```

### Loop metadata (via `as` keyword)

```html
<t-for post in posts as loop>
  <t-var name="loop.index" />   <!-- 0-based -->
  <t-var name="loop.number" />  <!-- 1-based -->
  <t-var name="loop.length" />  <!-- total count -->
  <t-if var="loop.first">      <!-- exists only on first item -->
  <t-if var="loop.last">       <!-- exists only on last item -->
</t-for>
```

### Transforms (20 built-in)

Applied via `transform` attribute with pipe chaining:

```html
<t-var name="title" transform="upper|truncate:50" />
```

**String:** `upper`, `lower`, `capitalize`, `trim`, `slugify`, `truncate:N`, `replace:find:replacement`, `default:fallback`
**HTML/URL:** `escape`, `url_encode`, `url_decode`
**Collection:** `join:separator`, `split:separator`, `first:N`, `last:N`
**Numeric:** `length`, `abs`, `floor`, `ceil`
**Date:** `date` (placeholder pass-through)

Custom transforms registered via `Engine.registerTransform()`. Signature: `*const fn (Allocator, []const u8, []const []const u8) RenderError![]u8`.

## Data Model

`Context` has two scopes:

- `data: Value.Map` — nested data tree (variables). Accessed via dot-path resolution (`page.title` → `data["page"]["title"]`).
- `slots: StringArrayHashMap([]const u8)` — rendered template fragments for slot filling.

`Value` is a tagged union: `string`, `boolean`, `integer`, `list`, `map`, `nil`. Variables resolve to `Value` via dot-path splitting on `.`.

`Resolver` maps template names to source strings for `<t-include>` and `<t-extend>`.

### Existence semantics

`<t-if var="x">` checks *existence*, not truthiness. A variable set to `false`, `0`, or empty string still satisfies the condition. Use `<t-if var="x" not-exists>` for absence checks.

Exception: `loop.first` and `loop.last` use existence semantics — they are only present on the first/last iteration.

## Error Reporting

`ErrorDetail` provides rich error context:

- Line/column computed from source position
- Source line excerpt with caret highlighting
- Template name and include stack trace
- Typo suggestion via Levenshtein distance (for `UndefinedVariable`)
- `Kind` enum: `undefined_variable`, `template_not_found`, `circular_reference`, `malformed_element`, `duplicate_slot`

Error detail is populated by the Renderer (not the Parser). Parser errors (`MalformedElement`, `DuplicateSlotDefinition`) surface as bare errors without `ErrorDetail` fields.

## Test Format

External `.test` files in `test/`, loaded at runtime by `test_runner.zig`. HTML comment delimiters:

```
<!-- test: descriptive name -->
<!-- in:header.html -->        (optional named template for includes)
<!-- in -->                     (main template source)
<!-- context -->                (JSON: {"data": {...}, "templates": {...}})
<!-- out -->                    (expected rendered output)
<!-- error -->                  (expected error type, instead of out)
<!-- error-line: N -->          (assert ErrorDetail line)
<!-- error-column: N -->        (assert ErrorDetail column)
<!-- error-kind: name -->       (assert ErrorDetail.Kind)
<!-- error-message: text -->    (assert substring in error message)
```

Context JSON: `"data"` for variables (nested maps/lists/strings), `"templates"` for named templates available via include/extend.

**296 integration test cases** across 15 `.test` files, plus **158 unit tests** across source modules. Total: **454 tests**.

## Build Commands

```
zig build test    # all tests (unit + integration)
zig build fuzz    # fuzz testing (Parser + Renderer)
zig build bench   # benchmarks (ReleaseFast)
zig build         # library + CLI stub
```

### Benchmark reference (ReleaseFast, 10-post template)

| Operation | Time |
| --- | --- |
| Parse | ~33μs |
| Render | ~69μs |
| Cached render | ~70μs |
| Full pipeline | ~135μs |

## Code Style

- **40-line function limit.** Extract helpers if a function grows beyond this.
- **camelCase** for functions, **PascalCase** for types, **snake_case** for fields/constants/enum values.
- All configurable values in blocks exposed as custom properties with defaults.
- Error handling: populate `ErrorDetail` via `setRichError()` before returning errors. Include `source_pos` in all node types that can produce errors.
- Comments explain non-obvious intent only. No narrating what code does.
- Imports: standard library first, then project modules.

## Documentation

All documentation is in Djot format (`.dj`):

**Template Author Guide** (`docs/guide/`): `getting-started.dj`, `variables.dj`, `composition.dj`, `control-flow.dj`, `transforms.dj`, `patterns.dj`

**Library API Reference** (`docs/api/`): `engine.dj`, `context.dj`, `errors.dj`, `integration.dj`

**Contributor Guide** (`docs/contributing/`): `architecture.dj`, `adding-elements.dj`, `adding-transforms.dj`, `testing.dj`, `code-style.dj`

**Reference** (`docs/`): `reference.dj`, `getting-started.dj`, `architecture.dj`, `deep-dive.dj`

## Relationship to Wig

Toupee is the template engine component of the Wig static site generator. The website at quiteclose.github.io is the proof-of-concept for both. Toupee is designed as an embeddable library — Wig is one consumer, but Toupee can be used independently by any Zig project that needs HTML templating.

The website repo (`quiteclose.github.io/`) contains an earlier prototype of the template engine in `src/template.zig` using `x-` prefix elements. That prototype will be replaced by Toupee (`t-` prefix) when Wig is built as a standalone tool.

## Design Decisions

- **Prefix `t-` is permanent.** Configurable prefix rejected — fixed prefix keeps templates portable and implementation simple.
- **IR is flat `[]Node`**, not a tree. Zig favours contiguous data. Child nesting through sub-slices.
- **Existence semantics for conditionals.** `<t-if var="x">` checks presence, not truthiness. Boolean `false` still exists.
- **Strict mode default.** Undefined variables without defaults cause errors. Opt out with `strict: false`.
- **No expression evaluator.** Transforms and conditionals cover the SSG use case.
- **No macros.** `<t-include>` with attributes and slots is the composition mechanism.
- **No sandboxing.** Build-time only; templates are developer-authored.
- **No browser support.** Toupee is a build tool.
- **No async.** Build-time rendering has no async data sources.
- **`loop.first`/`loop.last` use conditional presence** (only set on first/last iteration) rather than boolean values, so they work naturally with existence-based `<t-if>`.
- **For-else `<t-else />` inside `<t-for>`** correctly tracks both `<t-if>` and `<t-for>` nesting depth to avoid false matches.
- **Glob matching** for `matches` comparisons uses `*` (any sequence) and `?` (one character). Not regex.
