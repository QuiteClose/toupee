const std = @import("std");
const Allocator = std.mem.Allocator;
const N = @import("Node.zig");
const Node = N.Node;
const h = @import("html.zig");
const indent_mod = @import("indent.zig");

pub const ParseError = error{
    MalformedElement,
    DuplicateSlotDefinition,
    OutOfMemory,
    TemplateNotFound,
    CircularReference,
    UndefinedVariable,
};

pub const ParseResult = struct {
    nodes: []const Node,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

const prefix = "t-";

fn openTag(comptime name: []const u8) []const u8 {
    return comptime "<" ++ prefix ++ name ++ " ";
}

fn closeTag(comptime name: []const u8) []const u8 {
    return comptime "</" ++ prefix ++ name ++ ">";
}

pub fn parse(child_allocator: Allocator, source: []const u8) ParseError!ParseResult {
    var arena = std.heap.ArenaAllocator.init(child_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const start = h.skipWhitespace(source);
    const rest = source[start..];
    const extend_open = comptime "<" ++ prefix ++ "extend ";
    const extend_open_bare = comptime "<" ++ prefix ++ "extend>";

    if (std.mem.startsWith(u8, rest, extend_open) or
        std.mem.startsWith(u8, rest, extend_open_bare))
    {
        const nodes = try parseExtend(a, rest);
        return .{ .nodes = nodes, .arena = arena };
    }

    const nodes = try parseContent(a, source);
    return .{ .nodes = nodes, .arena = arena };
}

fn parseExtend(a: Allocator, input: []const u8) ParseError![]const Node {
    const tag_end = h.findTagEnd(input) orelse return error.MalformedElement;
    const tag = input[0 .. tag_end + 1];
    const template_name = h.extractAttrValue(tag, "template") orelse
        return error.MalformedElement;

    const defines = try parseDefineBlocks(a, input[tag_end + 1 ..]);

    var nodes: std.ArrayList(Node) = .{};
    try nodes.append(a, .{ .extend = .{
        .template = template_name,
        .defines = defines,
    } });
    return nodes.toOwnedSlice(a);
}

fn parseContent(a: Allocator, input: []const u8) ParseError![]const Node {
    const var_bind = comptime prefix ++ "var:";
    const attr_bind = comptime prefix ++ "attr:";

    var nodes: std.ArrayList(Node) = .{};
    var text_start: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        if (input[i] != '<') {
            i += 1;
            continue;
        }
        if (matchElement(input[i..])) |elem| {
            try flushText(a, &nodes, input, text_start, i);
            i = switch (elem) {
                .t_var => try parseVarOrRaw(a, input, i, &nodes, true),
                .t_raw => try parseVarOrRaw(a, input, i, &nodes, false),
                .t_let => try parseLet(a, input, i, &nodes),
                .t_comment => blk: {
                    const pos = try parseComment(input, i);
                    try nodes.append(a, .comment);
                    break :blk pos;
                },
                .t_attr => try parseAttrOutput(a, input, i, &nodes),
                .t_slot => try parseSlot(a, input, i, &nodes),
                .t_include => try parseInclude(a, input, i, &nodes),
                .t_for => try parseFor(a, input, i, &nodes),
                .t_if => try parseConditional(a, input, i, &nodes),
                .t_else, .t_elif => return error.MalformedElement,
            };
            text_start = i;
            continue;
        }
        if (i + 1 < input.len and input[i + 1] != '/' and input[i + 1] != '!') {
            if (h.findTagEnd(input[i..])) |end_offset| {
                const tag = input[i .. i + end_offset + 1];
                if (std.mem.indexOf(u8, tag, var_bind) != null or
                    std.mem.indexOf(u8, tag, attr_bind) != null)
                {
                    try flushText(a, &nodes, input, text_start, i);
                    try parseBoundTag(a, tag, &nodes);
                    i += end_offset + 1;
                    text_start = i;
                    continue;
                }
            }
        }
        i += 1;
    }

    try flushText(a, &nodes, input, text_start, input.len);
    return nodes.toOwnedSlice(a);
}

const Element = enum { t_var, t_raw, t_let, t_comment, t_attr, t_slot, t_include, t_for, t_if, t_else, t_elif };

fn matchElement(input: []const u8) ?Element {
    const tags = .{
        .{ "<" ++ prefix ++ "var ", Element.t_var },
        .{ "<" ++ prefix ++ "var/>", Element.t_var },
        .{ "<" ++ prefix ++ "var>", Element.t_var },
        .{ "<" ++ prefix ++ "raw ", Element.t_raw },
        .{ "<" ++ prefix ++ "raw/>", Element.t_raw },
        .{ "<" ++ prefix ++ "raw>", Element.t_raw },
        .{ "<" ++ prefix ++ "let ", Element.t_let },
        .{ "<" ++ prefix ++ "let>", Element.t_let },
        .{ "<" ++ prefix ++ "comment", Element.t_comment },
        .{ "<" ++ prefix ++ "attr ", Element.t_attr },
        .{ "<" ++ prefix ++ "attr/>", Element.t_attr },
        .{ "<" ++ prefix ++ "slot", Element.t_slot },
        .{ "<" ++ prefix ++ "include ", Element.t_include },
        .{ openTag("for"), Element.t_for },
        .{ "<" ++ prefix ++ "if ", Element.t_if },
        .{ "<" ++ prefix ++ "if>", Element.t_if },
        .{ "<" ++ prefix ++ "else", Element.t_else },
        .{ openTag("elif"), Element.t_elif },
    };
    inline for (tags) |entry| {
        if (std.mem.startsWith(u8, input, entry[0])) return entry[1];
    }
    return null;
}

fn flushText(a: Allocator, nodes: *std.ArrayList(Node), input: []const u8, start: usize, end: usize) ParseError!void {
    if (end > start) try nodes.append(a, .{ .text = input[start..end] });
}

fn parseVarOrRaw(a: Allocator, input: []const u8, start: usize, nodes: *std.ArrayList(Node), escape: bool) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
    const tag = rest[0 .. tag_end + 1];

    const name = h.extractAttrValue(tag, "name") orelse return error.MalformedElement;
    const transform = try parseTransformAttr(a, tag);

    var consumed: usize = tag_end + 1;
    var default_body: []const Node = &.{};

    if (!is_self_closing) {
        const var_close = comptime closeTag("var");
        const raw_close = comptime closeTag("raw");
        const close_str: []const u8 = if (escape) var_close else raw_close;
        const close_pos = std.mem.indexOf(u8, rest[tag_end + 1 ..], close_str) orelse
            return error.MalformedElement;
        default_body = try parseContent(a, rest[tag_end + 1 .. tag_end + 1 + close_pos]);
        consumed = tag_end + 1 + close_pos + close_str.len;
    }

    const variable: N.Variable = .{ .name = name, .transform = transform, .default_body = default_body };
    try nodes.append(a, if (escape) .{ .variable = variable } else .{ .raw_variable = variable });
    return start + consumed;
}

fn parseLet(a: Allocator, input: []const u8, start: usize, nodes: *std.ArrayList(Node)) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
    const tag = rest[0 .. tag_end + 1];
    const name = h.extractAttrValue(tag, "name") orelse return error.MalformedElement;
    const transform = try parseTransformAttr(a, tag);

    const let_close = comptime closeTag("let");
    const close_pos = std.mem.indexOf(u8, rest[tag_end + 1 ..], let_close) orelse
        return error.MalformedElement;
    const body = try parseContent(a, rest[tag_end + 1 .. tag_end + 1 + close_pos]);

    try nodes.append(a, .{ .let_binding = .{ .name = name, .transform = transform, .body = body } });
    return start + tag_end + 1 + close_pos + let_close.len;
}

fn parseComment(input: []const u8, start: usize) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
    if (tag_end > 0 and rest[tag_end - 1] == '/') return start + tag_end + 1;

    const comment_close = comptime closeTag("comment");
    const close_pos = std.mem.indexOf(u8, rest[tag_end + 1 ..], comment_close) orelse
        return error.MalformedElement;
    return start + tag_end + 1 + close_pos + comment_close.len;
}

fn parseAttrOutput(a: Allocator, input: []const u8, start: usize, nodes: *std.ArrayList(Node)) ParseError!usize {
    const rest = input[start..];
    const end_offset = std.mem.indexOf(u8, rest, "/>") orelse return error.MalformedElement;
    const tag = rest[0 .. end_offset + 2];
    const name = h.extractAttrValue(tag, "name") orelse return error.MalformedElement;
    try nodes.append(a, .{ .attr_output = .{ .name = name } });
    return start + end_offset + 2;
}

fn parseSlot(a: Allocator, input: []const u8, start: usize, nodes: *std.ArrayList(Node)) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
    const tag = rest[0 .. tag_end + 1];
    const name = h.extractAttrValue(tag, "name") orelse "";

    if (is_self_closing) {
        try nodes.append(a, .{ .slot = .{ .name = name } });
        return start + tag_end + 1;
    }

    const slot_close = comptime closeTag("slot");
    const close_pos = std.mem.indexOf(u8, rest[tag_end + 1 ..], slot_close) orelse
        return error.MalformedElement;
    const default_body = try parseContent(a, rest[tag_end + 1 .. tag_end + 1 + close_pos]);

    try nodes.append(a, .{ .slot = .{ .name = name, .default_body = default_body } });
    return start + tag_end + 1 + close_pos + slot_close.len;
}

fn parseInclude(a: Allocator, input: []const u8, start: usize, nodes: *std.ArrayList(Node)) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
    const tag = rest[0 .. tag_end + 1];
    const tmpl_name = h.extractAttrValue(tag, "template") orelse return error.MalformedElement;
    const attrs = try parseTagAttrList(a, tag);

    var consumed: usize = tag_end + 1;
    var defines: []const N.Define = &.{};
    var anonymous_body: []const Node = &.{};

    if (!is_self_closing) {
        const include_close = comptime closeTag("include");
        const close_pos = std.mem.indexOf(u8, rest[tag_end + 1 ..], include_close) orelse
            return error.MalformedElement;
        const raw_body = rest[tag_end + 1 .. tag_end + 1 + close_pos];
        const strip_result = try indent_mod.stripCommonIndent(a, raw_body);
        const body = strip_result.slice;
        consumed = tag_end + 1 + close_pos + include_close.len;

        if (body.len > 0) {
            const define_open = openTag("define");
            if (std.mem.indexOf(u8, body, define_open) != null) {
                const parts = try parseIncludeBody(a, body);
                defines = parts.defines;
                anonymous_body = parts.anonymous_body;
            } else {
                anonymous_body = try parseContent(a, body);
            }
        }
    }

    try nodes.append(a, .{ .include = .{
        .template = tmpl_name,
        .attrs = attrs,
        .defines = defines,
        .anonymous_body = anonymous_body,
    } });
    return start + consumed;
}

fn parseFor(a: Allocator, input: []const u8, start: usize, nodes: *std.ArrayList(Node)) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
    const tag = rest[0 .. tag_end + 1];
    const for_open = openTag("for");

    const item_prefix = blk: {
        const space = std.mem.indexOfPos(u8, tag, for_open.len, " ") orelse
            return error.MalformedElement;
        break :blk tag[for_open.len..space];
    };

    const collection = blk: {
        const in_tok = std.mem.indexOf(u8, tag, " in ") orelse return error.MalformedElement;
        const after_in = in_tok + 4;
        var end: usize = after_in;
        while (end < tag.len and tag[end] != ' ' and tag[end] != '>' and tag[end] != '/') : (end += 1) {}
        break :blk tag[after_in..end];
    };

    const alias: ?[]const u8 = blk: {
        const in_tok = std.mem.indexOf(u8, tag, " in ") orelse break :blk null;
        const as_tok = std.mem.indexOfPos(u8, tag, in_tok + 4, " as ") orelse break :blk null;
        const after_as = as_tok + 4;
        var end: usize = after_as;
        while (end < tag.len and tag[end] != ' ' and tag[end] != '>' and tag[end] != '/') : (end += 1) {}
        if (end > after_as) break :blk tag[after_as..end];
        break :blk null;
    };

    const limit = try parseUintAttr(tag, "limit");
    const offset = try parseUintAttr(tag, "offset");

    const body_start = start + tag_end + 1;
    const for_close = comptime closeTag("for");
    const close_offset = h.findMatchingClose(input[body_start..], for_open, for_close) orelse
        return error.MalformedElement;
    const body = try parseContent(a, input[body_start .. body_start + close_offset]);

    try nodes.append(a, .{ .loop = .{
        .item_prefix = item_prefix,
        .collection = collection,
        .alias = alias,
        .sort_field = h.extractAttrValue(tag, "sort"),
        .order_desc = if (h.extractAttrValue(tag, "order")) |o| std.mem.eql(u8, o, "desc") else false,
        .limit = limit,
        .offset = offset,
        .body = body,
    } });
    return body_start + close_offset + for_close.len;
}

fn parseConditional(a: Allocator, input: []const u8, start: usize, nodes: *std.ArrayList(Node)) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
    const if_tag = rest[0 .. tag_end + 1];
    const body_start = tag_end + 1;

    const if_open = openTag("if");
    const if_close = comptime closeTag("if");
    const close_pos = h.findMatchingClose(rest[body_start..], if_open, if_close) orelse
        return error.MalformedElement;
    const full_body = rest[body_start .. body_start + close_pos];
    const total_end = start + body_start + close_pos + if_close.len;

    var branches: std.ArrayList(N.Branch) = .{};
    const first_sep = findConditionalSeparator(full_body, 0);
    const if_body_source = if (first_sep) |sep| full_body[0..sep.pos] else full_body;
    try branches.append(a, .{
        .condition = parseCondition(if_tag),
        .body = try parseContent(a, if_body_source),
    });

    var else_body: []const Node = &.{};
    if (first_sep) |first| {
        var cursor = first;
        while (true) {
            if (cursor.is_else) {
                else_body = try parseContent(a, full_body[cursor.pos + cursor.tag_len ..]);
                break;
            }
            const elif_tag = full_body[cursor.pos .. cursor.pos + cursor.tag_len];
            const next_start = cursor.pos + cursor.tag_len;
            const next_sep = findConditionalSeparator(full_body, next_start);
            const elif_body_src = if (next_sep) |ns| full_body[next_start..ns.pos] else full_body[next_start..];
            try branches.append(a, .{
                .condition = parseCondition(elif_tag),
                .body = try parseContent(a, elif_body_src),
            });
            if (next_sep) |ns| {
                cursor = ns;
            } else break;
        }
    }

    try nodes.append(a, .{ .conditional = .{
        .branches = try branches.toOwnedSlice(a),
        .else_body = else_body,
    } });
    return total_end;
}

fn parseBoundTag(a: Allocator, tag: []const u8, nodes: *std.ArrayList(Node)) ParseError!void {
    const var_binding = comptime prefix ++ "var:";
    const attr_binding = comptime prefix ++ "attr:";
    var segments: std.ArrayList(N.Segment) = .{};
    var literal_start: usize = 0;
    var i: usize = 0;

    while (i < tag.len) {
        if (i > 0 and tag[i] == ' ' and i + 1 < tag.len) {
            const after = tag[i + 1 ..];
            const binding: ?struct { len: usize, is_var: bool } =
                if (std.mem.startsWith(u8, after, var_binding))
                .{ .len = var_binding.len, .is_var = true }
            else if (std.mem.startsWith(u8, after, attr_binding))
                .{ .len = attr_binding.len, .is_var = false }
            else
                null;

            if (binding) |b| {
                if (i > literal_start) try segments.append(a, .{ .literal = tag[literal_start..i] });
                var j = i + 1 + b.len;
                const attr_start = j;
                while (j < tag.len and tag[j] != '=') : (j += 1) {}
                const html_attr = tag[attr_start..j];
                j += 2;
                const ref_start = j;
                while (j < tag.len and tag[j] != '"') : (j += 1) {}
                const ref_name = tag[ref_start..j];
                j += 1;
                try segments.append(a, .{ .binding = .{
                    .html_attr = html_attr,
                    .ref_name = ref_name,
                    .is_var = b.is_var,
                } });
                i = j;
                literal_start = j;
                continue;
            }
        }
        i += 1;
    }

    if (literal_start < tag.len) try segments.append(a, .{ .literal = tag[literal_start..] });
    try nodes.append(a, .{ .bound_tag = .{ .segments = try segments.toOwnedSlice(a) } });
}

const IncludeBodyParts = struct {
    defines: []const N.Define,
    anonymous_body: []const Node,
};

fn parseIncludeBody(a: Allocator, body: []const u8) ParseError!IncludeBodyParts {
    const define_open = openTag("define");
    const define_close = comptime closeTag("define");

    var defines: std.ArrayList(N.Define) = .{};
    var seen_names: std.ArrayList([]const u8) = .{};
    var anon_parts: std.ArrayList(u8) = .{};
    var i: usize = 0;

    while (i < body.len) {
        if (std.mem.startsWith(u8, body[i..], define_open)) {
            const rest = body[i..];
            const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
            const tag = rest[0 .. tag_end + 1];
            const name = h.extractAttrValue(tag, "name") orelse
                h.extractAttrValue(tag, "slot") orelse
                return error.MalformedElement;
            for (seen_names.items) |seen| {
                if (std.mem.eql(u8, seen, name)) return error.DuplicateSlotDefinition;
            }
            try seen_names.append(a, name);
            const content_start = tag_end + 1;
            const close = std.mem.indexOf(u8, rest[content_start..], define_close) orelse
                return error.MalformedElement;
            const raw = rest[content_start .. content_start + close];
            const stripped = try indent_mod.stripCommonIndent(a, raw);
            try defines.append(a, .{ .name = name, .body = try parseContent(a, stripped.slice) });
            i += content_start + close + define_close.len;
        } else {
            try anon_parts.append(a, body[i]);
            i += 1;
        }
    }

    const trimmed = std.mem.trim(u8, anon_parts.items, " \t\r\n");
    const anonymous_body: []const Node = if (trimmed.len > 0)
        try parseContent(a, trimmed)
    else
        &.{};

    return .{
        .defines = try defines.toOwnedSlice(a),
        .anonymous_body = anonymous_body,
    };
}

fn parseDefineBlocks(a: Allocator, input: []const u8) ParseError![]const N.Define {
    const define_open = openTag("define");
    const define_close = comptime closeTag("define");
    var defines: std.ArrayList(N.Define) = .{};
    var i: usize = 0;

    while (i < input.len) {
        i += h.skipWhitespace(input[i..]);
        if (i >= input.len) break;
        if (std.mem.startsWith(u8, input[i..], define_open)) {
            const rest = input[i..];
            const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
            const tag = rest[0 .. tag_end + 1];
            const name = h.extractAttrValue(tag, "name") orelse
                h.extractAttrValue(tag, "slot") orelse
                return error.MalformedElement;
            const content_start = tag_end + 1;
            const close = std.mem.indexOf(u8, rest[content_start..], define_close) orelse
                return error.MalformedElement;
            const raw = rest[content_start .. content_start + close];
            const stripped = try indent_mod.stripCommonIndent(a, raw);
            try defines.append(a, .{ .name = name, .body = try parseContent(a, stripped.slice) });
            i += content_start + close + define_close.len;
        } else {
            i += 1;
        }
    }

    return defines.toOwnedSlice(a);
}

fn parseCondition(tag: []const u8) N.Condition {
    if (h.extractAttrValue(tag, "var")) |name| {
        return .{ .source = .variable, .name = name, .comparison = parseComparison(tag) };
    }
    if (h.extractAttrValue(tag, "attr")) |name| {
        return .{ .source = .attr, .name = name, .comparison = parseComparison(tag) };
    }
    if (h.extractAttrValue(tag, "slot")) |name| {
        return .{ .source = .slot, .name = name, .comparison = parseComparison(tag) };
    }
    return .{ .source = .variable, .name = "", .comparison = .exists };
}

fn parseComparison(tag: []const u8) N.Condition.Comparison {
    if (h.extractAttrValue(tag, "equals")) |val| return .{ .equals = val };
    if (h.extractAttrValue(tag, "not-equals")) |val| return .{ .not_equals = val };
    if (h.hasBoolAttr(tag, "not-exists")) return .not_exists;
    return .exists;
}

fn parseTransformAttr(a: Allocator, tag: []const u8) ParseError![]const N.TransformStep {
    const spec = h.extractAttrValue(tag, "transform") orelse return &.{};
    return parseTransformSpec(a, spec);
}

fn parseTransformSpec(a: Allocator, spec: []const u8) ParseError![]const N.TransformStep {
    var steps: std.ArrayList(N.TransformStep) = .{};
    var pipe_iter = std.mem.splitScalar(u8, spec, '|');

    while (pipe_iter.next()) |transform| {
        if (transform.len == 0) continue;
        var colon_iter = std.mem.splitScalar(u8, transform, ':');
        const name = colon_iter.next().?;
        var args: std.ArrayList([]const u8) = .{};
        while (colon_iter.next()) |arg| try args.append(a, arg);
        try steps.append(a, .{ .name = name, .args = try args.toOwnedSlice(a) });
    }

    return steps.toOwnedSlice(a);
}

fn parseTagAttrList(a: Allocator, tag: []const u8) ParseError![]const N.Attr {
    var attrs: std.ArrayList(N.Attr) = .{};
    var i: usize = 1;
    while (i < tag.len and tag[i] != ' ' and tag[i] != '/' and tag[i] != '>') : (i += 1) {}

    while (i < tag.len) {
        while (i < tag.len and tag[i] == ' ') : (i += 1) {}
        if (i >= tag.len or tag[i] == '/' or tag[i] == '>') break;
        const name_start = i;
        while (i < tag.len and tag[i] != '=' and tag[i] != ' ' and tag[i] != '/' and tag[i] != '>') : (i += 1) {}
        const attr_name = tag[name_start..i];
        if (i < tag.len and tag[i] == '=') {
            i += 1;
            if (i < tag.len and tag[i] == '"') {
                i += 1;
                const val_start = i;
                while (i < tag.len and tag[i] != '"') : (i += 1) {}
                const attr_value = tag[val_start..i];
                if (i < tag.len) i += 1;
                if (!std.mem.eql(u8, attr_name, "template")) {
                    try attrs.append(a, .{ .name = attr_name, .value = attr_value });
                }
            }
        } else if (!std.mem.eql(u8, attr_name, "template")) {
            try attrs.append(a, .{ .name = attr_name, .value = "" });
        }
    }

    return attrs.toOwnedSlice(a);
}

fn parseUintAttr(tag: []const u8, name: []const u8) ParseError!?usize {
    const val = h.extractAttrValue(tag, name) orelse return null;
    return std.fmt.parseInt(usize, val, 10) catch return error.MalformedElement;
}

const Separator = struct { pos: usize, tag_len: usize, is_else: bool };

fn findConditionalSeparator(body: []const u8, from: usize) ?Separator {
    const open_if = openTag("if");
    const close_if = comptime closeTag("if");
    const open_elif = openTag("elif");
    const open_else = comptime "<" ++ prefix ++ "else";

    var depth: usize = 0;
    var i = from;
    while (i < body.len) {
        if (std.mem.startsWith(u8, body[i..], open_if)) {
            depth += 1;
            i += open_if.len;
        } else if (std.mem.startsWith(u8, body[i..], close_if)) {
            if (depth == 0) return null;
            depth -= 1;
            i += close_if.len;
        } else if (depth == 0 and std.mem.startsWith(u8, body[i..], open_elif)) {
            const tag_end = h.findTagEnd(body[i..]) orelse return null;
            return .{ .pos = i, .tag_len = tag_end + 1, .is_else = false };
        } else if (depth == 0 and std.mem.startsWith(u8, body[i..], open_else)) {
            const tag_end = h.findTagEnd(body[i..]) orelse return null;
            return .{ .pos = i, .tag_len = tag_end + 1, .is_else = true };
        } else {
            i += 1;
        }
    }
    return null;
}

// ---- Tests ----

const testing = std.testing;

test "parse plain text" {
    var result = try parse(testing.allocator, "hello world");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.nodes.len);
    try testing.expectEqualStrings("hello world", result.nodes[0].text);
}

test "parse variable" {
    var result = try parse(testing.allocator, "<t-var name=\"title\" />");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.nodes.len);
    try testing.expectEqualStrings("title", result.nodes[0].variable.name);
    try testing.expectEqual(@as(usize, 0), result.nodes[0].variable.transform.len);
}

test "parse raw variable" {
    var result = try parse(testing.allocator, "<t-raw name=\"content\" />");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.nodes.len);
    try testing.expectEqualStrings("content", result.nodes[0].raw_variable.name);
}

test "parse variable with transform" {
    var result = try parse(testing.allocator, "<t-var name=\"title\" transform=\"upper|truncate:10\" />");
    defer result.deinit();
    const v = result.nodes[0].variable;
    try testing.expectEqualStrings("title", v.name);
    try testing.expectEqual(@as(usize, 2), v.transform.len);
    try testing.expectEqualStrings("upper", v.transform[0].name);
    try testing.expectEqualStrings("truncate", v.transform[1].name);
    try testing.expectEqual(@as(usize, 1), v.transform[1].args.len);
    try testing.expectEqualStrings("10", v.transform[1].args[0]);
}

test "parse variable with default body" {
    var result = try parse(testing.allocator, "<t-var name=\"title\">Untitled</t-var>");
    defer result.deinit();
    const v = result.nodes[0].variable;
    try testing.expectEqualStrings("title", v.name);
    try testing.expectEqual(@as(usize, 1), v.default_body.len);
    try testing.expectEqualStrings("Untitled", v.default_body[0].text);
}

test "parse text with embedded variable" {
    var result = try parse(testing.allocator, "<p><t-var name=\"x\" /></p>");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.nodes.len);
    try testing.expectEqualStrings("<p>", result.nodes[0].text);
    try testing.expectEqualStrings("x", result.nodes[1].variable.name);
    try testing.expectEqualStrings("</p>", result.nodes[2].text);
}

test "parse let binding" {
    var result = try parse(testing.allocator, "<t-let name=\"x\">hello</t-let>");
    defer result.deinit();
    const lb = result.nodes[0].let_binding;
    try testing.expectEqualStrings("x", lb.name);
    try testing.expectEqual(@as(usize, 1), lb.body.len);
    try testing.expectEqualStrings("hello", lb.body[0].text);
}

test "parse comment self-closing" {
    var result = try parse(testing.allocator, "a<t-comment />b");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.nodes.len);
    try testing.expectEqualStrings("a", result.nodes[0].text);
    try testing.expect(result.nodes[1] == .comment);
    try testing.expectEqualStrings("b", result.nodes[2].text);
}

test "parse comment block" {
    var result = try parse(testing.allocator, "a<t-comment>ignored</t-comment>b");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.nodes.len);
    try testing.expectEqualStrings("a", result.nodes[0].text);
    try testing.expect(result.nodes[1] == .comment);
    try testing.expectEqualStrings("b", result.nodes[2].text);
}

test "parse attr output" {
    var result = try parse(testing.allocator, "<t-attr name=\"href\" />");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.nodes.len);
    try testing.expectEqualStrings("href", result.nodes[0].attr_output.name);
}

test "parse slot self-closing" {
    var result = try parse(testing.allocator, "<t-slot name=\"main\" />");
    defer result.deinit();
    const s = result.nodes[0].slot;
    try testing.expectEqualStrings("main", s.name);
    try testing.expectEqual(@as(usize, 0), s.default_body.len);
}

test "parse slot with default" {
    var result = try parse(testing.allocator, "<t-slot name=\"main\">default</t-slot>");
    defer result.deinit();
    const s = result.nodes[0].slot;
    try testing.expectEqualStrings("main", s.name);
    try testing.expectEqual(@as(usize, 1), s.default_body.len);
    try testing.expectEqualStrings("default", s.default_body[0].text);
}

test "parse include self-closing" {
    var result = try parse(testing.allocator, "<t-include template=\"card.html\" class=\"wide\" />");
    defer result.deinit();
    const inc = result.nodes[0].include;
    try testing.expectEqualStrings("card.html", inc.template);
    try testing.expectEqual(@as(usize, 1), inc.attrs.len);
    try testing.expectEqualStrings("class", inc.attrs[0].name);
    try testing.expectEqualStrings("wide", inc.attrs[0].value);
}

test "parse include with anonymous body" {
    var result = try parse(testing.allocator, "<t-include template=\"box.html\">content</t-include>");
    defer result.deinit();
    const inc = result.nodes[0].include;
    try testing.expectEqualStrings("box.html", inc.template);
    try testing.expectEqual(@as(usize, 1), inc.anonymous_body.len);
    try testing.expectEqualStrings("content", inc.anonymous_body[0].text);
}

test "parse include with defines" {
    const source =
        \\<t-include template="page.html">
        \\  <t-define name="header">
        \\    <h1>Title</h1>
        \\  </t-define>
        \\</t-include>
    ;
    var result = try parse(testing.allocator, source);
    defer result.deinit();
    const inc = result.nodes[0].include;
    try testing.expectEqual(@as(usize, 1), inc.defines.len);
    try testing.expectEqualStrings("header", inc.defines[0].name);
}

test "parse extend" {
    const source =
        \\<t-extend template="base.html">
        \\<t-define name="content">
        \\  hello
        \\</t-define>
    ;
    var result = try parse(testing.allocator, source);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.nodes.len);
    const ext = result.nodes[0].extend;
    try testing.expectEqualStrings("base.html", ext.template);
    try testing.expectEqual(@as(usize, 1), ext.defines.len);
    try testing.expectEqualStrings("content", ext.defines[0].name);
}

test "parse for loop" {
    var result = try parse(testing.allocator, "<t-for item in items>body</t-for>");
    defer result.deinit();
    const loop = result.nodes[0].loop;
    try testing.expectEqualStrings("item", loop.item_prefix);
    try testing.expectEqualStrings("items", loop.collection);
    try testing.expectEqual(@as(?[]const u8, null), loop.alias);
    try testing.expectEqual(@as(usize, 1), loop.body.len);
    try testing.expectEqualStrings("body", loop.body[0].text);
}

test "parse for loop with alias and attrs" {
    var result = try parse(testing.allocator,
        \\<t-for post in posts as loop sort="date" order="desc" limit="5" offset="2">x</t-for>
    );
    defer result.deinit();
    const loop = result.nodes[0].loop;
    try testing.expectEqualStrings("post", loop.item_prefix);
    try testing.expectEqualStrings("posts", loop.collection);
    try testing.expectEqualStrings("loop", loop.alias.?);
    try testing.expectEqualStrings("date", loop.sort_field.?);
    try testing.expect(loop.order_desc);
    try testing.expectEqual(@as(usize, 5), loop.limit.?);
    try testing.expectEqual(@as(usize, 2), loop.offset.?);
}

test "parse conditional" {
    var result = try parse(testing.allocator, "<t-if var=\"show\">yes</t-if>");
    defer result.deinit();
    const cond = result.nodes[0].conditional;
    try testing.expectEqual(@as(usize, 1), cond.branches.len);
    try testing.expectEqual(N.Condition.Source.variable, cond.branches[0].condition.source);
    try testing.expectEqualStrings("show", cond.branches[0].condition.name);
    try testing.expectEqual(@as(usize, 0), cond.else_body.len);
}

test "parse conditional with elif and else" {
    const source = "<t-if var=\"a\">A<t-elif var=\"b\" />B<t-else />C</t-if>";
    var result = try parse(testing.allocator, source);
    defer result.deinit();
    const cond = result.nodes[0].conditional;
    try testing.expectEqual(@as(usize, 2), cond.branches.len);
    try testing.expectEqualStrings("a", cond.branches[0].condition.name);
    try testing.expectEqualStrings("b", cond.branches[1].condition.name);
    try testing.expectEqual(@as(usize, 1), cond.else_body.len);
    try testing.expectEqualStrings("C", cond.else_body[0].text);
}

test "parse conditional with equals" {
    var result = try parse(testing.allocator, "<t-if var=\"x\" equals=\"y\">match</t-if>");
    defer result.deinit();
    const cond = result.nodes[0].conditional;
    switch (cond.branches[0].condition.comparison) {
        .equals => |v| try testing.expectEqualStrings("y", v),
        else => return error.TestUnexpectedResult,
    }
}

test "parse bound tag" {
    var result = try parse(testing.allocator, "<a t-var:href=\"url\">link</a>");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.nodes.len);
    const bt = result.nodes[0].bound_tag;
    try testing.expectEqual(@as(usize, 3), bt.segments.len);
    try testing.expectEqualStrings("<a", bt.segments[0].literal);
    try testing.expectEqualStrings("href", bt.segments[1].binding.html_attr);
    try testing.expectEqualStrings("url", bt.segments[1].binding.ref_name);
    try testing.expect(bt.segments[1].binding.is_var);
    try testing.expectEqualStrings(">", bt.segments[2].literal);
    try testing.expectEqualStrings("link</a>", result.nodes[1].text);
}

test "parse stray else is error" {
    const result = parse(testing.allocator, "<t-else />");
    try testing.expectError(error.MalformedElement, result);
}

test "parse unclosed var is error" {
    const result = parse(testing.allocator, "<t-var name=\"x\"");
    try testing.expectError(error.MalformedElement, result);
}

test "parse empty template" {
    var result = try parse(testing.allocator, "");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.nodes.len);
}

test "parse nested elements" {
    var result = try parse(testing.allocator, "<t-if var=\"show\"><t-var name=\"x\" /></t-if>");
    defer result.deinit();
    const branch_body = result.nodes[0].conditional.branches[0].body;
    try testing.expectEqual(@as(usize, 1), branch_body.len);
    try testing.expectEqualStrings("x", branch_body[0].variable.name);
}

test "parse duplicate slot definition is error" {
    const source =
        \\<t-include template="x.html">
        \\  <t-define name="a">1</t-define>
        \\  <t-define name="a">2</t-define>
        \\</t-include>
    ;
    const result = parse(testing.allocator, source);
    try testing.expectError(error.DuplicateSlotDefinition, result);
}
