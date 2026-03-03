# Toupee

A build-time HTML template engine written in Zig. Toupee processes custom `t-` prefixed elements to produce clean HTML output — template inheritance, slots, conditionals, loops, and transforms with no runtime dependency.

Designed to be embedded in static site generators. The caller provides templates, context data, and a resolver; toupee renders them.

## Usage

```zig
const toupee = @import("toupee");

var resolver: toupee.Resolver = .{};
try resolver.put(allocator, "base.html", base_template);

var ctx: toupee.Context = .{};
try ctx.putVar(allocator, "page.title", "Hello World");
try ctx.putSlot(allocator, "", page_body);

const html = try toupee.render(allocator, template, &ctx, &resolver);
defer allocator.free(html);
```

## Features

- **Template inheritance** — `<t-extend>` chains with named slots and defaults
- **Component inclusion** — `<t-include>` with attribute passing and body slots
- **Variables** — `<t-var>` (escaped) and `<t-raw>` (unescaped) with default fallbacks
- **Attribute binding** — `t-var:href="url"` binds variables to HTML attributes
- **Control flow** — `<t-if>`/`<t-elif>`/`<t-else>` with exists, equals, not-equals, not-exists
- **Iteration** — `<t-for>` with sort, order, limit, offset, and loop metadata
- **Transforms** — `upper`, `lower`, `capitalize`, `trim`, `slugify`, `truncate`, `replace`, `default` (pipe-chained)
- **Capture** — `<t-let>` renders content into a variable
- **Comments** — `<t-comment>` strips content from output
- **Pretty-printer** — optional `renderFormatted()` with 2-space indentation

## Quick reference

```html
<!-- Inheritance -->
<t-extend template="base.html">
<t-define name="title">My Page</t-define>
<t-define name="">
  <p>Page body goes in the anonymous slot.</p>
</t-define>

<!-- Variables -->
<h1><t-var name="page.title" /></h1>
<t-var name="missing">default content</t-var>
<t-var name="title" transform="slugify" />

<!-- Attribute binding -->
<a t-var:href="post.url"><t-var name="post.title" /></a>

<!-- Components -->
<t-include template="card.html" variant="featured">
  <t-define name="title"><t-var name="card.title" /></t-define>
  <p>Card body</p>
</t-include>

<!-- Conditionals -->
<t-if var="show_sidebar">
  <aside>Sidebar</aside>
<t-else />
  <div>No sidebar</div>
</t-if>

<!-- Loops -->
<t-for post in posts sort="date" order="desc" limit="5" as loop>
  <article>
    <span><t-var name="loop.number" /></span>
    <h2><t-var name="post.title" /></h2>
  </article>
</t-for>
```

## Context model

The caller populates a `Context` with four namespaces:

| Namespace | Type | Accessed via |
| --- | --- | --- |
| `vars` | string → string | `t-var`, `t-raw`, `t-if var=` |
| `attrs` | string → string | `t-attr`, `t-if attr=` |
| `slots` | string → string | `t-slot`, `t-if slot=` |
| `collections` | string → Entry[] | `t-for` |

All values are flat strings. Entry fields are accessed via dot notation in the loop item prefix (e.g. `post.title`).

## Build and test

```
zig build test    # 144 tests across 14 test suites + inline unit tests
zig build         # build library
```

## Documentation

- [Element reference](docs/reference.dj) — complete element and transform reference
- [Getting started](docs/getting-started.dj) — tutorial walkthrough
- [Architecture](docs/architecture.dj) — module design and extension guide
- [AGENTS.md](AGENTS.md) — AI agent context

## License

MIT
