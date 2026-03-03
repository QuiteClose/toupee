const std = @import("std");
const Allocator = std.mem.Allocator;
const Ctx = @import("Context.zig");
const Context = Ctx.Context;
const RenderError = Ctx.RenderError;
const html = @import("html.zig");
const transform = @import("transform.zig");

const Engine = @import("Engine.zig");

/// Render a `<t-var>` or `<t-raw>` element.
/// `escape` controls whether the output is HTML-escaped (true for t-var, false for t-raw).
/// Returns the new position in `input` after consuming the element.
pub fn renderVarOrRaw(
    a: Allocator,
    input: []const u8,
    start: usize,
    ctx: *Context,
    resolver: *const Ctx.Resolver,
    depth: usize,
    out: *std.ArrayList(u8),
    escape: bool,
) RenderError!usize {
    const rest = input[start..];
    const tag_end = html.findTagEnd(rest) orelse {
        Engine.setErrorDetail(ctx, input, start, "unclosed tag");
        return error.MalformedElement;
    };
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
    const tag = rest[0 .. tag_end + 1];
    const close_tag: []const u8 = if (escape) Engine.closeTag("var") else Engine.closeTag("raw");

    const name = html.extractAttrValue(tag, "name") orelse {
        Engine.setErrorDetail(ctx, input, start, "missing 'name' attribute on t-var/t-raw");
        return error.MalformedElement;
    };
    const transform_spec = html.extractAttrValue(tag, "transform");

    var consumed: usize = tag_end + 1;
    var default_body: ?[]const u8 = null;

    if (!is_self_closing) {
        const content_start = tag_end + 1;
        const close = std.mem.indexOf(u8, rest[content_start..], close_tag) orelse {
            Engine.setErrorDetail(ctx, input, start, "unclosed t-var/t-raw element");
            return error.MalformedElement;
        };
        default_body = rest[content_start .. content_start + close];
        consumed = content_start + close + close_tag.len;
    }

    var value: []const u8 = "";
    var value_allocated = false;

    if (ctx.getVar(name)) |v| {
        value = v;
    } else if (default_body) |body| {
        value = try Engine.renderContent(a, body, ctx, resolver, depth);
        value_allocated = true;
    } else if (transform_spec != null and transform.hasDefaultTransform(transform_spec.?)) {
        // default transform will provide the value
    } else {
        Engine.setErrorDetail(ctx, input, start, name);
        return error.UndefinedVariable;
    }
    defer if (value_allocated) a.free(value);

    if (transform_spec) |ts| {
        const transformed = try transform.applyTransforms(a, value, ts);
        defer a.free(transformed);
        if (escape) {
            try html.appendEscaped(a, out, transformed);
        } else {
            try out.appendSlice(a, transformed);
        }
    } else if (value_allocated) {
        try out.appendSlice(a, value);
    } else if (escape) {
        try html.appendEscaped(a, out, value);
    } else {
        try out.appendSlice(a, value);
    }

    return start + consumed;
}

/// Render a `<t-let>` element: render body, capture into vars.
pub fn renderLet(
    a: Allocator,
    input: []const u8,
    start: usize,
    ctx: *Context,
    resolver: *const Ctx.Resolver,
    depth: usize,
    let_allocs: *std.ArrayList([]const u8),
) RenderError!usize {
    const rest = input[start..];
    const tag_end = html.findTagEnd(rest) orelse {
        Engine.setErrorDetail(ctx, input, start, "unclosed t-let tag");
        return error.MalformedElement;
    };
    const tag = rest[0 .. tag_end + 1];
    const let_name = html.extractAttrValue(tag, "name") orelse {
        Engine.setErrorDetail(ctx, input, start, "missing 'name' attribute on t-let");
        return error.MalformedElement;
    };
    const transform_spec = html.extractAttrValue(tag, "transform");

    const content_start = tag_end + 1;
    const close = std.mem.indexOf(u8, rest[content_start..], Engine.closeTag("let")) orelse {
        Engine.setErrorDetail(ctx, input, start, "unclosed t-let element");
        return error.MalformedElement;
    };
    const body = rest[content_start .. content_start + close];

    const rendered = try Engine.renderContent(a, body, ctx, resolver, depth);

    if (transform_spec) |ts| {
        const transformed = try transform.applyTransforms(a, rendered, ts);
        a.free(rendered);
        try let_allocs.append(a, transformed);
        try ctx.putVar(a, let_name, transformed);
    } else {
        try let_allocs.append(a, rendered);
        try ctx.putVar(a, let_name, rendered);
    }

    return start + content_start + close + Engine.closeTag("let").len;
}

/// Render an HTML tag that contains `t-var:` or `t-attr:` attribute bindings.
pub fn renderBoundTag(a: Allocator, tag: []const u8, ctx: *const Context, out: *std.ArrayList(u8)) RenderError!void {
    const var_binding = Engine.prefix ++ "var:";
    const attr_binding = Engine.prefix ++ "attr:";

    var i: usize = 0;
    while (i < tag.len) {
        if (i > 0 and tag[i] == ' ' and i + 1 < tag.len) {
            const after_space = tag[i + 1 ..];
            const binding: ?struct { prefix_len: usize, is_var: bool } =
                if (std.mem.startsWith(u8, after_space, var_binding))
                .{ .prefix_len = var_binding.len, .is_var = true }
            else if (std.mem.startsWith(u8, after_space, attr_binding))
                .{ .prefix_len = attr_binding.len, .is_var = false }
            else
                null;

            if (binding) |b| {
                i += 1;
                i += b.prefix_len;
                const attr_start = i;
                while (i < tag.len and tag[i] != '=') : (i += 1) {}
                const html_attr = tag[attr_start..i];
                i += 2; // skip '="'
                const var_start = i;
                while (i < tag.len and tag[i] != '"') : (i += 1) {}
                const ref_name = tag[var_start..i];
                i += 1; // skip closing '"'

                const value = if (b.is_var) ctx.getVar(ref_name) else ctx.getAttr(ref_name);
                if (value) |v| {
                    try out.append(a, ' ');
                    try out.appendSlice(a, html_attr);
                    try out.appendSlice(a, "=\"");
                    try html.appendEscaped(a, out, v);
                    try out.append(a, '"');
                }
                continue;
            }
        }
        try out.append(a, tag[i]);
        i += 1;
    }
}
