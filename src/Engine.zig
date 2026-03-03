const std = @import("std");
const Allocator = std.mem.Allocator;
const Ctx = @import("Context.zig");
const Context = Ctx.Context;
const Resolver = Ctx.Resolver;
const RenderError = Ctx.RenderError;
const h = @import("html.zig");
const vars = @import("vars.zig");
const compose = @import("compose.zig");
const control = @import("control.zig");

/// Element prefix. All template elements are `<{prefix}name>`.
pub const prefix = "t-";

const max_depth = 50;

/// Generate an opening tag prefix: `"<t-" ++ name ++ " "`.
pub fn openTag(comptime name: []const u8) []const u8 {
    return comptime "<" ++ prefix ++ name ++ " ";
}

/// Generate a closing tag: `"</t-" ++ name ++ ">"`.
pub fn closeTag(comptime name: []const u8) []const u8 {
    return comptime "</" ++ prefix ++ name ++ ">";
}

/// Top-level render: copies vars so t-let mutations don't leak to caller.
pub fn render(a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver) RenderError![]const u8 {
    var owned_vars: @TypeOf(ctx.vars) = .{};
    defer owned_vars.deinit(a);
    var vit = ctx.vars.iterator();
    while (vit.next()) |kv| {
        try owned_vars.put(a, kv.key_ptr.*, kv.value_ptr.*);
    }
    var mutable_ctx: Context = .{
        .vars = owned_vars,
        .attrs = ctx.attrs,
        .slots = ctx.slots,
        .collections = ctx.collections,
        .err_detail = ctx.err_detail,
    };
    const result = try renderTemplate(a, input, &mutable_ctx, resolver);
    owned_vars = mutable_ctx.vars;
    return result;
}

fn renderTemplate(a: Allocator, input: []const u8, ctx: *Context, resolver: *const Resolver) RenderError![]const u8 {
    const extend_open = comptime "<" ++ prefix ++ "extend ";
    const extend_open_bare = comptime "<" ++ prefix ++ "extend>";

    const start = h.skipWhitespace(input);
    if (!std.mem.startsWith(u8, input[start..], extend_open) and
        !std.mem.startsWith(u8, input[start..], extend_open_bare))
    {
        return renderContent(a, input, ctx, resolver, 0);
    }

    var current = input;
    var slots: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    defer slots.deinit(a);

    var allocs: std.ArrayList([]const u8) = .{};
    defer {
        for (allocs.items) |s| a.free(s);
        allocs.deinit(a);
    }

    var sit = ctx.slots.iterator();
    while (sit.next()) |entry| {
        try slots.put(a, entry.key_ptr.*, entry.value_ptr.*);
    }

    var visited: std.StringArrayHashMapUnmanaged(void) = .{};
    defer visited.deinit(a);

    while (true) {
        const ws = h.skipWhitespace(current);
        if (!std.mem.startsWith(u8, current[ws..], extend_open) and
            !std.mem.startsWith(u8, current[ws..], extend_open_bare)) break;

        const rest = current[ws..];
        const tag_end = h.findTagEnd(rest) orelse {
            setErrorDetail(ctx, current, ws, "unclosed t-extend tag");
            return error.MalformedElement;
        };
        const parent_name = h.extractAttrValue(rest[0 .. tag_end + 1], "template") orelse {
            setErrorDetail(ctx, current, ws, "missing 'template' attribute on t-extend");
            return error.MalformedElement;
        };

        if (visited.contains(parent_name)) {
            setErrorDetail(ctx, current, ws, parent_name);
            return error.CircularReference;
        }
        try visited.put(a, parent_name, {});

        try compose.parseDefines(a, rest[tag_end + 1 ..], &slots, &allocs);

        current = resolver.get(parent_name) orelse {
            setErrorDetail(ctx, current, ws, parent_name);
            return error.TemplateNotFound;
        };
    }

    var render_ctx: Context = .{
        .vars = ctx.vars,
        .attrs = ctx.attrs,
        .slots = slots,
        .collections = ctx.collections,
        .err_detail = ctx.err_detail,
    };

    return renderContent(a, current, &render_ctx, resolver, 0);
}

pub fn renderContent(a: Allocator, input: []const u8, ctx: *Context, resolver: *const Resolver, depth: usize) RenderError![]const u8 {
    if (depth > max_depth) return error.CircularReference;

    const var_open = comptime "<" ++ prefix ++ "var ";
    const var_open_sc = comptime "<" ++ prefix ++ "var/>";
    const var_open_bare = comptime "<" ++ prefix ++ "var>";
    const raw_open = comptime "<" ++ prefix ++ "raw ";
    const raw_open_sc = comptime "<" ++ prefix ++ "raw/>";
    const raw_open_bare = comptime "<" ++ prefix ++ "raw>";
    const let_open = comptime "<" ++ prefix ++ "let ";
    const let_open_bare = comptime "<" ++ prefix ++ "let>";
    const comment_open = comptime "<" ++ prefix ++ "comment";
    const attr_open = comptime "<" ++ prefix ++ "attr ";
    const attr_open_sc = comptime "<" ++ prefix ++ "attr/>";
    const slot_open = comptime "<" ++ prefix ++ "slot";
    const include_open = comptime "<" ++ prefix ++ "include ";
    const for_open = openTag("for");
    const if_open = comptime "<" ++ prefix ++ "if ";
    const if_open_bare = comptime "<" ++ prefix ++ "if>";
    const else_open = comptime "<" ++ prefix ++ "else";
    const elif_open = openTag("elif");
    const var_bind = comptime prefix ++ "var:";
    const attr_bind = comptime prefix ++ "attr:";

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(a);

    var let_allocs: std.ArrayList([]const u8) = .{};
    defer {
        for (let_allocs.items) |s| a.free(s);
        let_allocs.deinit(a);
    }

    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], var_open) or
            std.mem.startsWith(u8, input[i..], var_open_sc) or
            std.mem.startsWith(u8, input[i..], var_open_bare))
        {
            i = try vars.renderVarOrRaw(a, input, i, ctx, resolver, depth, &out, true);
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], raw_open) or
            std.mem.startsWith(u8, input[i..], raw_open_sc) or
            std.mem.startsWith(u8, input[i..], raw_open_bare))
        {
            i = try vars.renderVarOrRaw(a, input, i, ctx, resolver, depth, &out, false);
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], let_open) or
            std.mem.startsWith(u8, input[i..], let_open_bare))
        {
            i = try vars.renderLet(a, input, i, ctx, resolver, depth, &let_allocs);
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], comment_open)) {
            const rest = input[i..];
            const tag_end = h.findTagEnd(rest) orelse {
                setErrorDetail(ctx, input, i, "unclosed t-comment tag");
                return error.MalformedElement;
            };
            const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
            if (is_self_closing) {
                i += tag_end + 1;
            } else {
                const close = std.mem.indexOf(u8, rest[tag_end + 1 ..], closeTag("comment")) orelse {
                    setErrorDetail(ctx, input, i, "unclosed t-comment element");
                    return error.MalformedElement;
                };
                i += tag_end + 1 + close + closeTag("comment").len;
            }
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], attr_open) or
            std.mem.startsWith(u8, input[i..], attr_open_sc))
        {
            const rest = input[i..];
            const end_offset = std.mem.indexOf(u8, rest, "/>") orelse {
                setErrorDetail(ctx, input, i, "unclosed t-attr tag");
                return error.MalformedElement;
            };
            const tag = rest[0 .. end_offset + 2];
            const name = h.extractAttrValue(tag, "name") orelse {
                setErrorDetail(ctx, input, i, "missing 'name' attribute on t-attr");
                return error.MalformedElement;
            };
            if (ctx.getAttr(name)) |value| {
                try h.appendEscaped(a, &out, value);
            }
            i += end_offset + 2;
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], slot_open)) {
            i = try compose.renderSlot(a, input, i, ctx, resolver, depth, &out);
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], include_open)) {
            i = try compose.renderInclude(a, input, i, ctx, resolver, depth, &out);
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], for_open)) {
            i = try control.renderFor(a, input, i, ctx, resolver, depth, &out);
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], if_open) or
            std.mem.startsWith(u8, input[i..], if_open_bare))
        {
            i = try control.renderConditional(a, input, i, ctx, resolver, depth, &out);
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], else_open) or
            std.mem.startsWith(u8, input[i..], elif_open))
        {
            return error.MalformedElement;
        }

        if (input[i] == '<' and i + 1 < input.len and
            input[i + 1] != '/' and input[i + 1] != '!')
        {
            const rest = input[i..];
            if (h.findTagEnd(rest)) |end_offset| {
                const tag = rest[0 .. end_offset + 1];
                if (std.mem.indexOf(u8, tag, var_bind) != null or
                    std.mem.indexOf(u8, tag, attr_bind) != null)
                {
                    try vars.renderBoundTag(a, tag, ctx, &out);
                    i += end_offset + 1;
                    continue;
                }
            }
        }

        try out.append(a, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(a);
}

pub fn setErrorDetail(ctx: *Context, input: []const u8, pos: usize, message: []const u8) void {
    if (ctx.err_detail) |ed| {
        const lc = h.computeLineCol(input, pos);
        ed.line = lc.line;
        ed.column = lc.column;
        ed.message = message;
    }
}
