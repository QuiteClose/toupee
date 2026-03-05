# Toupee

HTML template engine in Zig. Processes `<t-*>` custom elements to produce clean HTML. Designed as an embeddable library for both static site generators and live web servers (HTMX fragments, scope isolation, startup validation, thread-safe rendering, writer API).

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
   Renderer.render()  ← takes Context + Loader
        │
   output ([]const u8 or Writer)
```

The IR is a flat `[]Node` tagged union slice (not a tree). Nesting is expressed through child slices into the same array. All node memory is arena-allocated; freeing the arena frees all nodes.

### Two-phase ownership model

The Engine follows a two-phase usage pattern:

- **Setup phase** (mutable `*Engine`): `addTemplate`, `removeTemplate`, `clearTemplates`, `registerTransform`. These mutate `cache` and `registry` and must not be called concurrently.
- **Serve phase** (immutable `*const Engine`): `renderTemplate`, `renderTemplateToWriter`, `renderTemplateFormatted`, `render`, `renderToWriter`, `renderFormatted`, `renderFormattedToWriter`, `validate`. These take `*const Engine` and are safe for concurrent use -- each call allocates its own arena and passes State by value.

## Module Map

| File | Responsibility |
| --- | --- |
| `root.zig` | Public API: `Engine` (template cache, transform registry, rendering, validation, writer API), convenience `render()`, type re-exports |
| `Parser.zig` | Template source → `[]Node` IR. Single-pass recursive descent. Populates `ErrorDetail` at all error sites. |
| `Renderer.zig` | `[]Node` IR + Context → output string or writer. `render()` buffers fully; `renderToWriter()` streams top-level nodes. |
| `Node.zig` | IR type definitions: tagged union + supporting structs (includes `ContextBinding` for scope isolation) |
| `Context.zig` | `Context`, `Loader`, `Resolver`, `ErrorDetail`, `IncludeEntry`, `RenderError` |
| `FileSystemLoader.zig` | `FileSystemLoader`: loads template sources from a filesystem directory |
| `ChainLoader.zig` | `ChainLoader`: tries multiple `Loader`s in sequence, returns first match |
| `Value.zig` | `Value` tagged union (`string`, `boolean`, `integer`, `list`, `map`, `nil`), dot-path resolution |
| `diagnostic.zig` | `Diagnostic` (validation results), `setError` (shared error-reporting for Parser and Renderer), `extractSourceLine`, `computeCaretLen`, `levenshtein` |
| `transform.zig` | `Registry`, `TransformFn`, built-in transforms (including `js_escape` for JavaScript string contexts) |
| `html.zig` | Tag parsing, attribute extraction, HTML escaping |
| `indent.zig` | Indentation propagation, common-indent stripping |
| `format.zig` | Post-render HTML pretty-printer (2-space indent) |
| `test_runner.zig` | `.test` file parser/runner with ErrorDetail assertions |
| `bench.zig` | Performance benchmarks (parse, render, cached, pipeline) |
| `fuzz.zig` | Fuzz targets for Parser and Renderer |
| `main.zig` | CLI stub (not yet implemented) |

## Public API (`root.zig`)

### Engine (configured usage)

```zig
var engine = try toupee.Engine.init(allocator);
defer engine.deinit();

// Setup phase
try engine.addTemplate("page.html", source);
try engine.registerTransform("date", dateFn);

// Validate before serving
var resolver: toupee.Resolver = .{};
const diags = try engine.validate(allocator, resolver.loader());
defer allocator.free(diags);

// Serve phase (thread-safe)
const result = try engine.renderTemplate(allocator, "page.html", &ctx, resolver.loader(), .{});
defer allocator.free(result);
```

### Convenience (one-shot usage)

```zig
var resolver: toupee.Resolver = .{};
const result = try toupee.render(allocator, source, &ctx, resolver.loader(), .{});
defer allocator.free(result);
```

### Engine methods

**Setup phase** (mutable `*Engine`, not thread-safe):

| Method | Purpose |
| --- | --- |
| `addTemplate(name, source)` | Parse and cache a template (replaces existing); dupes both name and source |
| `loadFromDirectory(base_path, extension)` | Recursively scan a directory and cache all matching files; sorted for deterministic order |
| `removeTemplate(name)` | Remove a cached template (no-op if not found) |
| `clearTemplates()` | Remove all cached templates |
| `registerTransform(name, fn)` | Register a custom transform function |

**Serve phase** (immutable `*const Engine`, thread-safe):

| Method | Purpose |
| --- | --- |
| `renderTemplate(a, name, ctx, loader, opts)` | Render a cached template |
| `renderTemplateFormatted(a, name, ctx, loader, opts)` | Render cached template with pretty-printing |
| `renderTemplateToWriter(a, name, ctx, loader, opts, writer)` | Render cached template, streaming to a writer |
| `render(a, source, ctx, loader, opts)` | Parse and render raw source |
| `renderFormatted(a, source, ctx, loader, opts)` | Parse and render with pretty-printing |
| `renderToWriter(a, source, ctx, loader, opts, writer)` | Parse and render, streaming to a writer |
| `renderFormattedToWriter(a, source, ctx, loader, opts, writer)` | Parse, render, pretty-print to a writer |
| `validate(a, loader)` | Check all cached templates for missing includes/extends |
| `renderOwned(a, source, ctx, loader, opts)` | Render returning a `RenderResult` |
| `renderTemplateOwned(a, name, ctx, loader, opts)` | Render cached returning a `RenderResult` |

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
var resolver: toupee.Resolver = .{};
const result = try engine.renderOwned(allocator, source, &ctx, resolver.loader(), .{});
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
| `<t-include template="x.html" />` | Include a component. Supports attributes, `<t-define>` children, `isolated`, and `context`. |
| `<t-attr name="x" />` | Output an include attribute value |
| `<t-comment>ignored</t-comment>` | Stripped from output |
| `<t-debug />` | Context dump (only when `debug: true` in Options) |

### Scope isolation for includes

Isolated includes receive only explicitly passed data, preventing accidental data leakage:

```html
<!-- Style card receives only style.* from parent context -->
<t-include template="style-card.html" isolated context="style" author="QuiteClose" />

<!-- Renamed paths to avoid collision -->
<t-include template="profile.html" isolated context="style.client as writer, review.client as reviewer" />

<!-- Fully isolated: only attrs and slots, no context -->
<t-include template="badge.html" isolated label="New" />
```

The `context` attribute is a comma-separated list of data paths. Each entry is either `path` (inserted under its leaf segment) or `path as name` (inserted under the specified name). The `as` keyword is consistent with `<t-for item in collection as loop>`.

### Attribute bindings

```html
<a t-var:href="style.url">view</a>   <!-- binds variable to HTML attribute -->
<div t-attr:class="variant">        <!-- binds include attribute to HTML attribute -->
```

### Loop metadata (via `as` keyword)

```html
<t-for style in styles as loop>
  <t-var name="loop.index" />   <!-- 0-based -->
  <t-var name="loop.number" />  <!-- 1-based -->
  <t-var name="loop.length" />  <!-- total count -->
  <t-if var="loop.first">      <!-- exists only on first item -->
  <t-if var="loop.last">       <!-- exists only on last item -->
</t-for>
```

### Transforms (built-in)

Applied via `transform` attribute with pipe chaining:

```html
<t-var name="title" transform="upper|truncate:50" />
```

**String:** `upper`, `lower`, `capitalize`, `trim`, `slugify`, `truncate:N`, `replace:find:replacement`, `default:fallback`
**HTML/URL/JS:** `escape`, `url_encode`, `url_decode`, `js_escape`
**Collection:** `join:separator`, `split:separator`, `first:N`, `last:N`
**Numeric:** `length`, `abs`, `floor`, `ceil`
**Date:** `date` (placeholder pass-through)

Custom transforms registered via `Engine.registerTransform()`. Signature: `*const fn (Allocator, []const u8, []const []const u8) RenderError![]u8`.

## Data Model

`Context` has two scopes:

- `data: Value.Map` — nested data tree (variables). Accessed via dot-path resolution (`page.title` → `data["page"]["title"]`). Caller-owned; the Renderer copies data on entry to child contexts, so the original is safe to reuse across render calls.
- `slots: StringArrayHashMap([]const u8)` — rendered template fragments for slot filling.

`Context` provides two methods for inserting data:

- `put(a, key, value)` — inserts at a top-level key.
- `putAt(a, path, value)` — inserts at a dot-separated path (e.g. `"page.meta.title"`), creating intermediate maps as needed. Returns `error.PathConflict` if an intermediate key exists but is not a `.map`. This is the primary method for building context from structured data (frontmatter, config, collections).

`Value` is a tagged union: `string`, `boolean`, `integer`, `list`, `map`, `nil`. Variables resolve to `Value` via dot-path splitting on `.`.

`Loader` is a runtime-polymorphic interface (fat-pointer pattern) for template source resolution. Three implementations:

- `Resolver.loader()` -- wraps the in-memory `Resolver` map (zero-copy)
- `FileSystemLoader` -- reads templates from a base directory on the filesystem
- `ChainLoader` -- tries multiple loaders in order, returns the first match

`Resolver` remains available for in-memory template storage and is the simplest way to get started.

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

Error detail is populated by both the Parser (for `MalformedElement`, `DuplicateSlotDefinition`) and the Renderer (for runtime errors). The `diagnostic.zig` module provides shared error-reporting utilities (`setError`, `extractSourceLine`, `computeCaretLen`, `levenshtein`) used by both.

### Startup validation

`Engine.validate()` walks all cached templates and reports problems before serving traffic:

- Missing `<t-include>` targets (not in cache or loader)
- Missing `<t-extend>` targets (not in cache or loader)

Returns `[]const Diagnostic` with template name, kind (err/warning), and message.

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

Over 400 tests across integration `.test` files and unit tests in source modules.

## Build Commands

```
zig build test    # all tests (unit + integration)
zig build fuzz    # fuzz testing (Parser + Renderer)
zig build bench   # benchmarks (ReleaseFast)
zig build         # library + CLI stub
```

### Benchmark reference (ReleaseFast, 10-style template)

| Operation | Time |
| --- | --- |
| Parse | ~33μs |
| Render | ~69μs |
| Cached render | ~70μs |
| Full pipeline | ~135μs |

## Code Style

- **Readability-first function length.** Function length is a soft signal, not a hard limit. The test is comprehension: can a new reader follow the function without scrolling back and forth? A 45-line function that reads clearly is better than a 30-line function that calls a single-use helper elsewhere.
- **camelCase** for functions, **PascalCase** for types, **snake_case** for fields/constants/enum values.
- All configurable values in blocks exposed as custom properties with defaults.
- Error handling: populate `ErrorDetail` via `diagnostic.setError()` before returning errors. Include `source_pos` in all node types that can produce errors.
- Comments explain non-obvious intent only. No narrating what code does.
- Imports: standard library first, then project modules.

## Documentation

All documentation is in Djot format (`.dj`):

**Template Author Guide** (`docs/guide/`): `getting-started.dj`, `variables.dj`, `composition.dj`, `control-flow.dj`, `transforms.dj`, `patterns.dj`, `tutorial.dj`

**Library API Reference** (`docs/api/`): `engine.dj`, `context.dj`, `errors.dj`, `integration.dj`

**Contributor Guide** (`docs/contributing/`): `architecture.dj`, `adding-elements.dj`, `adding-transforms.dj`, `testing.dj`, `code-style.dj`

**Reference** (`docs/`): `reference.dj`, `getting-started.dj`

## Relationship to Wig

Toupee is the template engine component of the Wig static site generator. The website at quiteclose.github.io is the proof-of-concept for both. Toupee is designed as an embeddable library — Wig is one consumer, but Toupee can be used independently by any Zig project that needs HTML templating.

The website repo (`quiteclose.github.io/`) contains an earlier prototype of the template engine in `src/template.zig` using `x-` prefix elements. That prototype will be replaced by Toupee (`t-` prefix) when Wig is built as a standalone tool.

## Design Decisions

- **Prefix `t-` is permanent.** Configurable prefix rejected — fixed prefix keeps templates portable and implementation simple.
- **IR is flat `[]Node`**, not a tree. Zig favours contiguous data. Child nesting through sub-slices.
- **Existence semantics for conditionals.** `<t-if var="x">` checks presence, not truthiness. Boolean `false` still exists.
- **Strict mode default.** Undefined variables without defaults cause errors. Opt out with `strict: false`.
- **No expression evaluator.** Transforms and conditionals cover the use case.
- **No macros.** `<t-include>` with attributes and slots is the composition mechanism.
- **Scope isolation.** `<t-include isolated context="...">` provides explicit data passing for safe component composition. The `context` attribute uses `as` for renaming, consistent with `<t-for ... as alias>`.
- **Two-phase threading model.** Setup phase (mutable) then serve phase (immutable, concurrent). No locking needed because the Engine is immutable during rendering.
- **Writer API streams top-level nodes.** `renderToWriter()` iterates top-level nodes and writes each directly: text nodes go straight to the writer without allocation, complex nodes are rendered individually and flushed. Nested rendering (includes, slots, let bindings) still buffers internally. This avoids duplicating the `renderNodes` switch logic while reducing peak memory for large templates.
- **`js_escape` transform.** For safely embedding values in JavaScript string literals, common in HTMX patterns.
- **No browser support.** Toupee is a server-side tool.
- **No async.** Rendering has no async data sources.
- **`loop.first`/`loop.last` use conditional presence** (only set on first/last iteration) rather than boolean values, so they work naturally with existence-based `<t-if>`.
- **For-else `<t-else />` inside `<t-for>`** correctly tracks both `<t-if>` and `<t-for>` nesting depth to avoid false matches.
- **Glob matching** for `matches` comparisons uses `*` (any sequence) and `?` (one character). Not regex.
- **Engine owns template names.** `addTemplate` dupes both the name and the source, so callers need not keep them alive. This enables `loadFromDirectory` to pass transient walker paths safely.
- **`Context.deinit` recursively frees nested maps.** Maps created by `putAt` are owned by the Context and cleaned up automatically.
