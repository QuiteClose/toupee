# Toupee

*Seamless HTML templates, zero magic.*

A build-time template engine in Zig. Templates are plain HTML with `<t-*>` elements for inheritance, slots, loops, conditionals, and transforms. No custom delimiters, no embedded language, no runtime. Feed it templates and data, get HTML back.

## A Little Off-the-Top

```html
<t-extend template="base.html">
<t-define name="content">
  <h1><t-var name="site.title" /></h1>
  <t-for post in posts sort="date" order="desc" limit="5" as loop>
  <article>
    <h2><a t-var:href="post.url"><t-var name="post.title" /></a></h2>
    <p><t-var name="post.summary" transform="truncate:120" /></p>
    <t-for tag in post.tags>
    <span class="tag"><t-var name="tag" /></span>
    </t-for>
  </article>
  <t-else />
  <p>No posts yet.</p>
  </t-for>
</t-define>
</t-extend>
```

That's a real template. Inheritance, nested loops, attribute binding, transforms, for-else -- all valid HTML.

## Short Back & Sides

Template:

```html
<t-for item in fruits>
<li><t-var name="item.name" /> (<t-var name="item.color" transform="lower" />)</li>
</t-for>
```

Zig:

```zig
const toupee = @import("toupee");

var ctx: toupee.Context = .{};
try ctx.putData(allocator, "fruits", .{ .list = &.{
    .{ .map = /* { name: "Apple", color: "RED" } */ },
    .{ .map = /* { name: "Lime", color: "GREEN" } */ },
} });

const html = try toupee.render(allocator, template, &ctx, &resolver, .{});
```

Output:

```html
<li>Apple (red)</li>
<li>Lime (green)</li>
```

## Why Toupee?

- **Templates should look like HTML.** If your template isn't valid HTML structure, your tooling can't help you. Toupee uses custom elements (`<t-var>`, `<t-for>`, `<t-if>`) that sit naturally alongside real markup.

- **Parsing and rendering are separate.** Parse once into a flat IR, cache it, render many times with different data. The IR is a `[]Node` tagged union slice -- contiguous memory, no pointer chasing, no GC.

- **No embedded language.** Templates don't execute arbitrary code. Transforms handle formatting; conditionals handle branching; loops handle iteration. That's the whole language.

- **Errors should help.** Source excerpts with line numbers, caret highlighting, typo suggestions via Levenshtein distance, and include stack traces. When something goes wrong, the error tells you where and why.

## Features

- **Template inheritance** -- `<t-extend>` with named `<t-slot>`/`<t-define>` pairs and defaults
- **Components** -- `<t-include>` with attributes, body slots, and nested defines
- **Variables** -- `<t-var>` (escaped) and `<t-raw>` (unescaped) with dot-path resolution
- **Attribute binding** -- `<a t-var:href="post.url">` binds variables to HTML attributes
- **Conditionals** -- `<t-if>` with `equals`, `contains`, `starts-with`, `ends-with`, `matches` (glob)
- **Loops** -- `<t-for>` with sort, filter, limit/offset, `loop.first`/`loop.last`/`loop.length`, for-else
- **Transforms** -- `upper`, `slugify`, `truncate:N`, `escape`, `url_encode`, `join`, `split`, and more (pipe-chained)
- **Capture** -- `<t-let>` renders content into a scoped variable
- **Strict mode** -- errors on undefined variables (default on, opt out per render)

## Quick Start

```zig
const toupee = @import("toupee");

// Engine caches parsed templates and manages transforms
var engine = try toupee.Engine.init(allocator);
defer engine.deinit();

// Pre-parse and cache
try engine.addTemplate("page.html", page_source);
try engine.addTemplate("base.html", base_source);

// Set up data
var ctx: toupee.Context = .{};
try ctx.putData(allocator, "title", .{ .string = "Hello" });
defer ctx.deinit(allocator);

// Templates available via include/extend resolve through the Resolver
var resolver: toupee.Resolver = .{};
try resolver.put(allocator, "base.html", base_source);
defer resolver.deinit(allocator);

// Render
const html = try engine.renderTemplate(allocator, "page.html", &ctx, &resolver, .{});
defer allocator.free(html);
```

Or skip the Engine for one-shot rendering:

```zig
const html = try toupee.render(allocator, source, &ctx, &resolver, .{});
```

## Build and Test

```
zig build test    # over 400 tests (integration + unit)
zig build bench   # parse/render benchmarks (ReleaseFast)
zig build fuzz    # fuzz testing for parser and renderer
```

## Documentation

- **[Template Author Guide](docs/guide/)** -- getting started, variables, control flow, composition, transforms, patterns
- **[Library API Reference](docs/api/)** -- Engine, Context, errors, integration
- **[Contributor Guide](docs/contributing/)** -- architecture, adding elements/transforms, testing, code style
- **[Element Reference](docs/reference.dj)** -- complete element and transform reference
