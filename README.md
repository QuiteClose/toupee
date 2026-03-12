# Toupee

[![CI](https://github.com/QuiteClose/toupee/actions/workflows/ci.yml/badge.svg)](https://github.com/QuiteClose/toupee/actions/workflows/ci.yml)

*Seamless HTML templates, zero magic.*

A template engine in Zig for static sites and live servers. Templates are plain HTML with `<t-*>` elements for inheritance, slots, loops, conditionals, and transforms. No custom delimiters, no embedded language. Feed it templates and data, get HTML back.

## A Little Off-the-Top

```html
<t-extend template="base.html">
<t-define name="content">
  <h1><t-var name="salon.name" /></h1>
  <t-for style in styles sort="name" limit="5" as loop>
  <article>
    <h2><a t-var:href="style.url"><t-var name="style.name" /></a></h2>
    <p><t-var name="style.description" transform="truncate:120" /></p>
    <t-for technique in style.techniques>
    <span class="tag"><t-var name="technique" /></span>
    </t-for>
  </article>
  <t-else />
  <p>No styles listed yet.</p>
  </t-for>
</t-define>
</t-extend>
```

That's a real template. Inheritance, nested loops, attribute binding, transforms, for-else -- all valid HTML.

## Short Back & Sides

Template:

```html
<t-for product in products>
<li><t-var name="product.name" /> (<t-var name="product.hold" transform="lower" />)</li>
</t-for>
```

Zig:

```zig
const toupee = @import("toupee");

var ctx = toupee.Context.init(allocator);
defer ctx.deinit();
try ctx.put("products", .{ .list = &.{
    .{ .map = /* { name: "Pomade", hold: "STRONG" } */ },
    .{ .map = /* { name: "Mousse", hold: "LIGHT" } */ },
} });

var resolver: toupee.Resolver = .{};
const html = try toupee.render(allocator, template, &ctx, resolver.loader(), .{});
```

Output:

```html
<li>Pomade (strong)</li>
<li>Mousse (light)</li>
```

## Why Toupee?

- **Templates should look like HTML.** If your template isn't valid HTML structure, your tooling can't help you. Toupee uses custom elements (`<t-var>`, `<t-for>`, `<t-if>`) that sit naturally alongside real markup.

- **Parsing and rendering are separate.** Parse once into a flat IR, cache it, render many times with different data. The IR is a `[]Node` tagged union slice -- contiguous memory, no pointer chasing, no GC.

- **No embedded language.** Templates don't execute arbitrary code. Transforms handle formatting; conditionals handle branching; loops handle iteration. That's the whole language.

- **Errors should help.** Source excerpts with line numbers, caret highlighting, typo suggestions via Levenshtein distance, and include stack traces. When something goes wrong, the error tells you where and why.

## Features

- **Template inheritance** -- `<t-extend>` with named `<t-slot>`/`<t-define>` pairs and defaults
- **Components** -- `<t-include>` with attributes, body slots, and nested defines
- **Scope isolation** -- `<t-include isolated context="post, site">` passes only named data to components
- **Variables** -- `<t-var>` (escaped) and `<t-raw>` (unescaped) with dot-path resolution
- **Attribute binding** -- `<a t-var:href="post.url">` binds variables to HTML attributes
- **Conditionals** -- `<t-if>` with `equals`, `contains`, `starts-with`, `ends-with`, `matches` (glob)
- **Loops** -- `<t-for>` with sort, filter, limit/offset, `loop.first`/`loop.last`/`loop.length`, for-else
- **Transforms** -- `upper`, `slugify`, `truncate:N`, `escape`, `js_escape`, `url_encode`, `join`, `split`, `int`, `float`, `decimal:N`, `bool`, `date:format`, and more (pipe-chained)
- **Auto-coercion** -- integers, floats, and booleans render as strings automatically; no manual conversion needed
- **Capture** -- `<t-let>` renders content into a scoped variable
- **Strict mode** -- errors on undefined variables (default on, opt out per render)
- **Startup validation** -- `Engine.validate()` catches missing templates before serving traffic
- **Thread-safe rendering** -- immutable Engine for concurrent render calls
- **Writer API** -- render directly to any `std.io.Writer` with true top-level streaming
- **Loader abstraction** -- `Resolver` (in-memory), `FileSystemLoader`, `ChainLoader` (try loaders in order)
- **Directory loading** -- `Engine.loadFromDirectory()` scans a directory and caches all matching templates
- **Dot-path context building** -- `Context.putAt("page.meta.title", value)` creates intermediate maps automatically
- **Cache management** -- `removeTemplate()`, `clearTemplates()` for dev-mode hot-reload

## Quick Start

### Static site generation

```zig
const toupee = @import("toupee");

var engine = try toupee.Engine.init(allocator);
defer engine.deinit();

// Load all .html templates from a directory at once
try engine.loadFromDirectory("templates", ".html");

var ctx = toupee.Context.init(allocator);
defer ctx.deinit();
// Build nested context from dot-separated paths
try ctx.putAt("site.title", .{ .string = "The Toupee Room" });
try ctx.putAt("site.author", .{ .string = "QuiteClose" });
try ctx.put("year", .{ .string = "2026" });

var resolver: toupee.Resolver = .{};
const html = try engine.renderTemplate(allocator, "page.html", &ctx, resolver.loader(), .{});
defer allocator.free(html);
```

### Live server (HTMX fragments)

```zig
// Setup phase (at server startup)
var engine = try toupee.Engine.init(allocator);
try engine.addTemplate("client-status.html",
    \\<div id="status"><t-var name="client" /> is <t-var name="status" /></div>
);

// Validate all templates before serving
var resolver: toupee.Resolver = .{};
const diags = try engine.validate(allocator, resolver.loader());
defer allocator.free(diags);

// Serve phase (per-request, thread-safe)
var ctx = toupee.Context.init(allocator);
defer ctx.deinit();
try ctx.put("client", .{ .string = "Marcel" });
try ctx.put("status", .{ .string = "seated" });

try engine.renderTemplateToWriter(allocator, "client-status.html", &ctx, resolver.loader(), .{}, response.writer());
```

Or skip the Engine for one-shot rendering:

```zig
var resolver: toupee.Resolver = .{};
const html = try toupee.render(allocator, source, &ctx, resolver.loader(), .{});
```

## Build and Test

```
zig build test    # over 470 tests (integration + unit)
zig build bench   # parse/render benchmarks (ReleaseFast)
zig build fuzz    # fuzz testing for parser and renderer
```

## Documentation

- **[Template Author Guide](docs/guide/)** -- getting started, variables, control flow, composition, transforms, patterns, tutorial
- **[Library API Reference](docs/api/)** -- Engine, Context, errors, integration
- **[Contributor Guide](docs/contributing/)** -- architecture, adding elements/transforms, testing, code style
- **[Element Reference](docs/reference.dj)** -- complete element and transform reference
