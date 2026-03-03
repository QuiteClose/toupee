# Toupee

Build-time HTML template engine in Zig. Processes `t-` prefixed custom elements to produce clean HTML. Designed as an embeddable library for static site generators.

## Module map

| File | Responsibility |
| --- | --- |
| `root.zig` | Public API: `render()`, `renderFormatted()`, type re-exports |
| `Context.zig` | `Entry`, `Context`, `Resolver`, `ErrorDetail`, `RenderError` |
| `Engine.zig` | Core dispatch loop, extend chain, `t-` prefix constant |
| `vars.zig` | `t-var`, `t-raw`, `t-let`, attribute binding (`t-var:`, `t-attr:`) |
| `compose.zig` | `t-slot`, `t-include`, `t-define`, include body parsing |
| `control.zig` | `t-if`/`t-elif`/`t-else`, `t-for`, condition evaluation |
| `transform.zig` | 8 transforms: upper, lower, capitalize, trim, slugify, truncate, replace, default |
| `html.zig` | Tag parsing, attribute extraction, HTML escaping |
| `indent.zig` | Indentation propagation, common-indent stripping |
| `format.zig` | Post-render HTML pretty-printer (2-space indent) |
| `test_runner.zig` | `.test` file parser and runner |

## Element reference

- `<t-extend template="name">` + `<t-define name="slot">` — template inheritance
- `<t-slot name="x" />` or `<t-slot>default</t-slot>` — insertion points
- `<t-var name="x" />` — escaped variable (errors if missing, unless default body/transform)
- `<t-raw name="x" />` — unescaped variable
- `<t-let name="x">content</t-let>` — capture rendered content
- `<t-include template="x" attr="val" />` — component inclusion
- `<t-attr name="x" />` — access include attribute
- `<a t-var:href="url">` — bind variable to HTML attribute
- `<div t-attr:class="variant">` — bind include attribute to HTML attribute
- `<t-if var="x" equals="val">` — conditional (also: `not-equals`, `not-exists`, `attr=`, `slot=`)
- `<t-elif var="y" />` / `<t-else />` — branches (self-closing separators)
- `<t-for item in collection sort="f" order="desc" limit="N" offset="N" as loop>` — iteration
- `<t-comment>` — stripped from output

## Context model

Four flat string maps: `vars`, `attrs`, `slots`, `collections` (Entry[]). No nesting — `page.title` is a flat key. Entry fields accessed as `prefix.field` in loops.

## Existence semantics

`<t-if var="x">` — true if present, even if empty string. `not-exists` — true only when genuinely absent.

## Test format

External `.test` files in `test/`, loaded at runtime. HTML comment delimiters:

```
<!-- test: name -->
<!-- in:file.html -->     (optional extra templates)
<!-- in -->                (main template)
<!-- context -->           (JSON: {"vars": {}, "collections": {}})
<!-- out -->               (expected output)
<!-- error: ErrorName -->  (expected error, instead of out)
```

144 test cases across 14 suites, plus inline unit tests. Run with `zig build test`.

## Build

```
zig build test    # all tests
zig build         # library
```
