const std = @import("std");
const Allocator = std.mem.Allocator;
const Ctx = @import("Context.zig");
const Context = Ctx.Context;
const Entry = Ctx.Entry;
const RenderError = Ctx.RenderError;
const h = @import("html.zig");
const Engine = @import("Engine.zig");

const Separator = struct { pos: usize, tag_len: usize, is_else: bool };

/// Render a `<t-if>` conditional block (with optional t-elif/t-else).
pub fn renderConditional(
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
        Engine.setErrorDetail(ctx, input, start, "unclosed t-if tag");
        return error.MalformedElement;
    };
    const if_tag = rest[0 .. tag_end + 1];
    const body_start = tag_end + 1;

    const if_close = h.findMatchingClose(rest[body_start..], Engine.openTag("if"), Engine.closeTag("if")) orelse {
        Engine.setErrorDetail(ctx, input, start, "unclosed t-if element");
        return error.MalformedElement;
    };
    const full_body = rest[body_start .. body_start + if_close];
    const total_end = start + body_start + if_close + Engine.closeTag("if").len;

    var matched = false;

    const first_sep = findConditionalSeparator(full_body, 0);
    const if_body = if (first_sep) |sep| full_body[0..sep.pos] else full_body;

    if (evaluateCondition(if_tag, ctx)) {
        const rendered = try Engine.renderContent(a, if_body, ctx, resolver, depth);
        defer a.free(rendered);
        try out.appendSlice(a, rendered);
        matched = true;
    }

    if (first_sep) |first| {
        var cursor = first;
        while (true) {
            if (cursor.is_else) {
                if (!matched) {
                    const else_body = full_body[cursor.pos + cursor.tag_len ..];
                    const rendered = try Engine.renderContent(a, else_body, ctx, resolver, depth);
                    defer a.free(rendered);
                    try out.appendSlice(a, rendered);
                }
                break;
            }
            const elif_tag = full_body[cursor.pos .. cursor.pos + cursor.tag_len];
            const next_start = cursor.pos + cursor.tag_len;
            const next_sep = findConditionalSeparator(full_body, next_start);
            const elif_body = if (next_sep) |ns| full_body[next_start..ns.pos] else full_body[next_start..];

            if (!matched and evaluateCondition(elif_tag, ctx)) {
                const rendered = try Engine.renderContent(a, elif_body, ctx, resolver, depth);
                defer a.free(rendered);
                try out.appendSlice(a, rendered);
                matched = true;
            }

            if (next_sep) |ns| {
                cursor = ns;
            } else break;
        }
    }

    return total_end;
}

fn evaluateCondition(tag: []const u8, ctx: *const Context) bool {
    if (h.extractAttrValue(tag, "var")) |name| {
        return evalComparison(tag, ctx.getVar(name));
    }
    if (h.extractAttrValue(tag, "attr")) |name| {
        return evalComparison(tag, ctx.getAttr(name));
    }
    if (h.extractAttrValue(tag, "slot")) |name| {
        const exists = ctx.hasSlot(name);
        if (h.hasBoolAttr(tag, "not-exists")) return !exists;
        return exists;
    }
    return false;
}

/// Strict exists/not-exists: empty string counts as existing.
fn evalComparison(tag: []const u8, value: ?[]const u8) bool {
    if (h.extractAttrValue(tag, "equals")) |expected| {
        return if (value) |v| std.mem.eql(u8, v, expected) else false;
    }
    if (h.extractAttrValue(tag, "not-equals")) |expected| {
        return if (value) |v| !std.mem.eql(u8, v, expected) else true;
    }
    if (h.hasBoolAttr(tag, "not-exists")) {
        return value == null;
    }
    return value != null;
}

fn findConditionalSeparator(body: []const u8, from: usize) ?Separator {
    const open_if = Engine.openTag("if");
    const close_if = Engine.closeTag("if");
    const open_elif = Engine.openTag("elif");
    const open_else = "<" ++ Engine.prefix ++ "else";

    var depth_count: usize = 0;
    var i = from;
    while (i < body.len) {
        if (std.mem.startsWith(u8, body[i..], open_if)) {
            depth_count += 1;
            i += open_if.len;
        } else if (std.mem.startsWith(u8, body[i..], close_if)) {
            if (depth_count == 0) return null;
            depth_count -= 1;
            i += close_if.len;
        } else if (depth_count == 0 and std.mem.startsWith(u8, body[i..], open_elif)) {
            const tag_end = h.findTagEnd(body[i..]) orelse return null;
            return .{ .pos = i, .tag_len = tag_end + 1, .is_else = false };
        } else if (depth_count == 0 and std.mem.startsWith(u8, body[i..], open_else)) {
            const tag_end = h.findTagEnd(body[i..]) orelse return null;
            return .{ .pos = i, .tag_len = tag_end + 1, .is_else = true };
        } else {
            i += 1;
        }
    }
    return null;
}

/// Render a `<t-for>` loop.
pub fn renderFor(
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
        Engine.setErrorDetail(ctx, input, start, "unclosed t-for tag");
        return error.MalformedElement;
    };
    const tag = rest[0 .. tag_end + 1];

    const open_for = Engine.openTag("for");
    const item_prefix = blk: {
        const after_for = open_for.len;
        const space = std.mem.indexOfPos(u8, tag, after_for, " ") orelse
            return error.MalformedElement;
        break :blk tag[after_for..space];
    };

    const collection_name = blk: {
        const in_tok = std.mem.indexOf(u8, tag, " in ") orelse
            return error.MalformedElement;
        const after_in = in_tok + 4;
        var end = after_in;
        while (end < tag.len and tag[end] != ' ' and tag[end] != '>' and tag[end] != '/') : (end += 1) {}
        break :blk tag[after_in..end];
    };

    const loop_alias: ?[]const u8 = blk: {
        const in_tok = std.mem.indexOf(u8, tag, " in ") orelse break :blk null;
        const as_tok = std.mem.indexOfPos(u8, tag, in_tok + 4, " as ") orelse break :blk null;
        const after_as = as_tok + 4;
        var alias_end = after_as;
        while (alias_end < tag.len and tag[alias_end] != ' ' and
            tag[alias_end] != '>' and tag[alias_end] != '/') : (alias_end += 1)
        {}
        if (alias_end > after_as) break :blk tag[after_as..alias_end];
        break :blk null;
    };

    const sort_field = h.extractAttrValue(tag, "sort");
    const order_desc = if (h.extractAttrValue(tag, "order")) |o|
        std.mem.eql(u8, o, "desc")
    else
        false;

    const limit_val = if (h.extractAttrValue(tag, "limit")) |v|
        std.fmt.parseInt(usize, v, 10) catch return error.MalformedElement
    else
        null;
    const offset_val = if (h.extractAttrValue(tag, "offset")) |v|
        std.fmt.parseInt(usize, v, 10) catch return error.MalformedElement
    else
        null;

    const body_start = start + tag_end + 1;
    const close_offset = h.findMatchingClose(input[body_start..], open_for, Engine.closeTag("for")) orelse {
        Engine.setErrorDetail(ctx, input, start, "unclosed t-for element");
        return error.MalformedElement;
    };
    const body = input[body_start .. body_start + close_offset];
    const after_close = body_start + close_offset + Engine.closeTag("for").len;

    const entries = ctx.getCollection(collection_name) orelse return after_close;

    const items = try a.dupe(Entry, entries);
    defer a.free(items);

    if (sort_field) |field| {
        const Sort = struct {
            field_name: []const u8,
            descending: bool,

            pub fn lessThan(self_sort: @This(), lhs: Entry, rhs: Entry) bool {
                const a_val = lhs.get(self_sort.field_name) orelse "";
                const b_val = rhs.get(self_sort.field_name) orelse "";
                const cmp = std.mem.order(u8, a_val, b_val);
                if (self_sort.descending) return cmp == .gt;
                return cmp == .lt;
            }
        };
        std.mem.sort(Entry, items, Sort{ .field_name = field, .descending = order_desc }, Sort.lessThan);
    }

    const off = if (offset_val) |o| @min(o, items.len) else 0;
    const sliced = items[off..];
    const final = if (limit_val) |l| sliced[0..@min(l, sliced.len)] else sliced;

    for (final, 0..) |entry, idx| {
        var child_ctx: Context = .{
            .attrs = ctx.attrs,
            .slots = ctx.slots,
            .collections = ctx.collections,
            .err_detail = ctx.err_detail,
        };

        var child_vars: @TypeOf(ctx.vars) = .{};
        var it = ctx.vars.iterator();
        while (it.next()) |kv| {
            try child_vars.put(a, kv.key_ptr.*, kv.value_ptr.*);
        }

        var allocated_keys: std.ArrayList([]const u8) = .{};
        defer {
            for (allocated_keys.items) |k| a.free(k);
            allocated_keys.deinit(a);
        }

        var entry_it = entry.values.iterator();
        while (entry_it.next()) |kv| {
            const prefixed = try std.fmt.allocPrint(a, "{s}.{s}", .{ item_prefix, kv.key_ptr.* });
            try allocated_keys.append(a, prefixed);
            try child_vars.put(a, prefixed, kv.value_ptr.*);
        }

        if (loop_alias) |alias| {
            const idx_key = try std.fmt.allocPrint(a, "{s}.index", .{alias});
            try allocated_keys.append(a, idx_key);
            const idx_str = try std.fmt.allocPrint(a, "{d}", .{idx});
            try allocated_keys.append(a, idx_str);
            try child_vars.put(a, idx_key, idx_str);

            const num_key = try std.fmt.allocPrint(a, "{s}.number", .{alias});
            try allocated_keys.append(a, num_key);
            const num_str = try std.fmt.allocPrint(a, "{d}", .{idx + 1});
            try allocated_keys.append(a, num_str);
            try child_vars.put(a, num_key, num_str);
        }

        child_ctx.vars = child_vars;
        defer child_vars.deinit(a);

        const rendered = try Engine.renderContent(a, body, &child_ctx, resolver, depth + 1);
        defer a.free(rendered);
        try out.appendSlice(a, rendered);
    }

    return after_close;
}
