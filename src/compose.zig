const std = @import("std");
const Allocator = std.mem.Allocator;
const Ctx = @import("Context.zig");
const Context = Ctx.Context;
const RenderError = Ctx.RenderError;
const h = @import("html.zig");
const Engine = @import("Engine.zig");
const indent_mod = @import("indent.zig");

/// Render a `<t-slot>` element.
pub fn renderSlot(
    a: Allocator,
    input: []const u8,
    start: usize,
    ctx: *Context,
    resolver: *const Ctx.Resolver,
    depth: usize,
    out: *std.ArrayList(u8),
) RenderError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse {
        Engine.setErrorDetail(ctx, input, start, "unclosed t-slot tag");
        return error.MalformedElement;
    };
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';

    const indent = try a.dupe(u8, indent_mod.detectIndent(out.items));
    defer a.free(indent);

    if (is_self_closing) {
        const tag = rest[0 .. tag_end + 1];
        const name = h.extractAttrValue(tag, "name") orelse "";
        if (ctx.getSlot(name)) |content| {
            const rendered = try Engine.renderContent(a, content, ctx, resolver, depth);
            defer a.free(rendered);
            try indent_mod.appendIndented(a, out, rendered, indent);
        }
        return start + tag_end + 1;
    }

    const tag = rest[0 .. tag_end + 1];
    const name = h.extractAttrValue(tag, "name") orelse "";
    const content_start = tag_end + 1;
    const close_tag = std.mem.indexOf(u8, rest[content_start..], Engine.closeTag("slot")) orelse {
        Engine.setErrorDetail(ctx, input, start, "unclosed t-slot element");
        return error.MalformedElement;
    };
    const default_content = rest[content_start .. content_start + close_tag];
    const total_end = content_start + close_tag + Engine.closeTag("slot").len;

    const content_to_render = ctx.getSlot(name) orelse default_content;
    const rendered = try Engine.renderContent(a, content_to_render, ctx, resolver, depth);
    defer a.free(rendered);
    try indent_mod.appendIndented(a, out, rendered, indent);

    return start + total_end;
}

/// Render a `<t-include>` element.
pub fn renderInclude(
    a: Allocator,
    input: []const u8,
    start: usize,
    ctx: *Context,
    resolver: *const Ctx.Resolver,
    depth: usize,
    out: *std.ArrayList(u8),
) RenderError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse {
        Engine.setErrorDetail(ctx, input, start, "unclosed t-include tag");
        return error.MalformedElement;
    };
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
    const tag = rest[0 .. tag_end + 1];
    const tmpl_name = h.extractAttrValue(tag, "template") orelse {
        Engine.setErrorDetail(ctx, input, start, "missing 'template' attribute on t-include");
        return error.MalformedElement;
    };

    var inc_attrs = try h.parseTagAttrs(a, tag);
    defer inc_attrs.deinit(a);

    var body: []const u8 = "";
    var body_allocated = false;
    var consumed: usize = tag_end + 1;

    if (!is_self_closing) {
        const content_start = tag_end + 1;
        const close = std.mem.indexOf(u8, rest[content_start..], Engine.closeTag("include")) orelse {
            Engine.setErrorDetail(ctx, input, start, "unclosed t-include element");
            return error.MalformedElement;
        };
        const raw_body = rest[content_start .. content_start + close];
        const strip_result = try indent_mod.stripCommonIndent(a, raw_body);
        body = strip_result.slice;
        body_allocated = strip_result.allocated;
        consumed = content_start + close + Engine.closeTag("include").len;
    }
    defer if (body_allocated) a.free(body);

    const tmpl_content = resolver.get(tmpl_name) orelse {
        Engine.setErrorDetail(ctx, input, start, tmpl_name);
        return error.TemplateNotFound;
    };

    var child_slots: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    defer child_slots.deinit(a);
    var slot_allocs: std.ArrayList([]const u8) = .{};
    defer {
        for (slot_allocs.items) |s| a.free(s);
        slot_allocs.deinit(a);
    }

    if (body.len > 0) {
        const define_open = Engine.openTag("define");
        if (std.mem.indexOf(u8, body, define_open) != null) {
            try parseIncludeBody(a, body, &child_slots, &slot_allocs);
        } else {
            try child_slots.put(a, "", body);
        }
    }

    var child_ctx: Context = .{
        .vars = ctx.vars,
        .attrs = inc_attrs,
        .slots = child_slots,
        .collections = ctx.collections,
        .err_detail = ctx.err_detail,
    };

    const indent = try a.dupe(u8, indent_mod.detectIndent(out.items));
    defer a.free(indent);
    const rendered = try Engine.renderContent(a, tmpl_content, &child_ctx, resolver, depth + 1);
    defer a.free(rendered);
    try indent_mod.appendIndented(a, out, rendered, indent);

    return start + consumed;
}

/// Parse `<t-define>` blocks from extend bodies into slots.
pub fn parseDefines(
    a: Allocator,
    input: []const u8,
    slots: *std.StringArrayHashMapUnmanaged([]const u8),
    allocs: *std.ArrayList([]const u8),
) RenderError!void {
    const define_open = Engine.openTag("define");
    const define_close = Engine.closeTag("define");
    var i: usize = 0;
    while (i < input.len) {
        const ws = h.skipWhitespace(input[i..]);
        i += ws;
        if (i >= input.len) break;

        if (std.mem.startsWith(u8, input[i..], define_open)) {
            const rest_slice = input[i..];
            const tag_end = h.findTagEnd(rest_slice) orelse return error.MalformedElement;
            const slot_name = h.extractAttrValue(rest_slice[0 .. tag_end + 1], "name") orelse
                return error.MalformedElement;
            const content_start = tag_end + 1;
            const close = std.mem.indexOf(u8, rest_slice[content_start..], define_close) orelse
                return error.MalformedElement;
            const raw_content = rest_slice[content_start .. content_start + close];
            const result = try indent_mod.stripCommonIndent(a, raw_content);
            if (result.allocated) try allocs.append(a, result.slice);
            try slots.put(a, slot_name, result.slice);
            i += content_start + close + define_close.len;
        } else {
            i += 1;
        }
    }
}

fn parseIncludeBody(
    a: Allocator,
    body: []const u8,
    slots: *std.StringArrayHashMapUnmanaged([]const u8),
    allocs: *std.ArrayList([]const u8),
) RenderError!void {
    const define_open = Engine.openTag("define");
    const define_close = Engine.closeTag("define");

    var anon_parts: std.ArrayList(u8) = .{};
    defer anon_parts.deinit(a);

    var i: usize = 0;
    while (i < body.len) {
        if (std.mem.startsWith(u8, body[i..], define_open)) {
            const rest_slice = body[i..];
            const tag_end = h.findTagEnd(rest_slice) orelse return error.MalformedElement;
            const tag = rest_slice[0 .. tag_end + 1];
            const slot_name = h.extractAttrValue(tag, "name") orelse
                return error.MalformedElement;

            if (slots.contains(slot_name)) return error.DuplicateSlotDefinition;

            const content_start = tag_end + 1;
            const close = std.mem.indexOf(u8, rest_slice[content_start..], define_close) orelse
                return error.MalformedElement;
            const raw_content = rest_slice[content_start .. content_start + close];
            const result = try indent_mod.stripCommonIndent(a, raw_content);
            if (result.allocated) try allocs.append(a, result.slice);
            try slots.put(a, slot_name, result.slice);
            i += content_start + close + define_close.len;
        } else {
            try anon_parts.append(a, body[i]);
            i += 1;
        }
    }

    const trimmed = std.mem.trim(u8, anon_parts.items, " \t\r\n");
    if (trimmed.len > 0) {
        const anon_copy = try a.dupe(u8, trimmed);
        try allocs.append(a, anon_copy);
        try slots.put(a, "", anon_copy);
    }
}
