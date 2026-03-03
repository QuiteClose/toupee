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
        const nodes = try parseExtend(a, rest, start);
        return .{ .nodes = nodes, .arena = arena };
    }

    const nodes = try parseContent(a, source, 0);
    return .{ .nodes = nodes, .arena = arena };
}

fn parseExtend(a: Allocator, input: []const u8, offset: usize) ParseError![]const Node {
    const tag_end = h.findTagEnd(input) orelse return error.MalformedElement;
    const tag = input[0 .. tag_end + 1];
    const template_name = h.extractAttrValue(tag, "template") orelse
        return error.MalformedElement;

    const result = try parseDefines(a, input[tag_end + 1 ..], offset + tag_end + 1);
    var nodes: std.ArrayList(Node) = .{};
    try nodes.append(a, .{ .extend = .{
        .template = template_name,
        .defines = result.defines,
        .source_pos = offset,
    } });
    return nodes.toOwnedSlice(a);
}

// ---- Content parsing ----

fn parseContent(a: Allocator, input: []const u8, offset: usize) ParseError![]const Node {
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
            i = try dispatchElement(a, input, i, &nodes, elem, offset);
            text_start = i;
            continue;
        }
        if (findBoundTagEnd(input, i)) |end_offset| {
            try flushText(a, &nodes, input, text_start, i);
            try parseBoundTag(a, input[i .. i + end_offset + 1], &nodes, offset + i);
            i += end_offset + 1;
            text_start = i;
            continue;
        }
        i += 1;
    }

    try flushText(a, &nodes, input, text_start, input.len);
    return nodes.toOwnedSlice(a);
}

fn dispatchElement(
    a: Allocator,
    input: []const u8,
    start: usize,
    nodes: *std.ArrayList(Node),
    elem: Element,
    offset: usize,
) ParseError!usize {
    return switch (elem) {
        .t_var => parseVarOrRaw(a, input, start, nodes, true, offset),
        .t_raw => parseVarOrRaw(a, input, start, nodes, false, offset),
        .t_let => parseLet(a, input, start, nodes, offset),
        .t_comment => blk: {
            const pos = try parseComment(input, start);
            try nodes.append(a, .comment);
            break :blk pos;
        },
        .t_attr => parseAttrOutput(a, input, start, nodes, offset),
        .t_slot => parseSlot(a, input, start, nodes, offset),
        .t_include => parseInclude(a, input, start, nodes, offset),
        .t_for => parseFor(a, input, start, nodes, offset),
        .t_if => parseConditional(a, input, start, nodes, offset),
        .t_else, .t_elif => error.MalformedElement,
    };
}

fn findBoundTagEnd(input: []const u8, pos: usize) ?usize {
    if (pos + 1 >= input.len or input[pos + 1] == '/' or input[pos + 1] == '!') return null;
    const end_offset = h.findTagEnd(input[pos..]) orelse return null;
    const tag = input[pos .. pos + end_offset + 1];
    const var_bind = comptime prefix ++ "var:";
    const attr_bind = comptime prefix ++ "attr:";
    if (std.mem.indexOf(u8, tag, var_bind) == null and
        std.mem.indexOf(u8, tag, attr_bind) == null) return null;
    return end_offset;
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

// ---- Element parsers ----

fn parseVarOrRaw(a: Allocator, input: []const u8, start: usize, nodes: *std.ArrayList(Node), escape: bool, offset: usize) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
    const tag = rest[0 .. tag_end + 1];

    const name = h.extractAttrValue(tag, "name") orelse return error.MalformedElement;
    const xform = try parseTransformAttr(a, tag);

    var consumed: usize = tag_end + 1;
    var default_body: []const Node = &.{};
    var has_body = false;

    if (!is_self_closing) {
        has_body = true;
        const close_str: []const u8 = if (escape) comptime closeTag("var") else comptime closeTag("raw");
        const close_pos = std.mem.indexOf(u8, rest[tag_end + 1 ..], close_str) orelse
            return error.MalformedElement;
        default_body = try parseContent(a, rest[tag_end + 1 .. tag_end + 1 + close_pos], offset + start + tag_end + 1);
        consumed = tag_end + 1 + close_pos + close_str.len;
    }

    const variable: N.Variable = .{
        .name = name,
        .transform = xform,
        .default_body = default_body,
        .has_body = has_body,
        .source_pos = offset + start,
    };
    try nodes.append(a, if (escape) .{ .variable = variable } else .{ .raw_variable = variable });
    return start + consumed;
}

fn parseLet(a: Allocator, input: []const u8, start: usize, nodes: *std.ArrayList(Node), offset: usize) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
    const tag = rest[0 .. tag_end + 1];
    const name = h.extractAttrValue(tag, "name") orelse return error.MalformedElement;
    const xform = try parseTransformAttr(a, tag);

    const let_close = comptime closeTag("let");
    const close_pos = std.mem.indexOf(u8, rest[tag_end + 1 ..], let_close) orelse
        return error.MalformedElement;
    const body = try parseContent(a, rest[tag_end + 1 .. tag_end + 1 + close_pos], offset + start + tag_end + 1);

    try nodes.append(a, .{ .let_binding = .{
        .name = name,
        .transform = xform,
        .body = body,
        .source_pos = offset + start,
    } });
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

fn parseAttrOutput(a: Allocator, input: []const u8, start: usize, nodes: *std.ArrayList(Node), offset: usize) ParseError!usize {
    const rest = input[start..];
    const end_offset = std.mem.indexOf(u8, rest, "/>") orelse return error.MalformedElement;
    const tag = rest[0 .. end_offset + 2];
    const name = h.extractAttrValue(tag, "name") orelse return error.MalformedElement;
    try nodes.append(a, .{ .attr_output = .{ .name = name, .source_pos = offset + start } });
    return start + end_offset + 2;
}

fn parseSlot(a: Allocator, input: []const u8, start: usize, nodes: *std.ArrayList(Node), offset: usize) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
    const tag = rest[0 .. tag_end + 1];
    const name = h.extractAttrValue(tag, "name") orelse "";

    if (is_self_closing) {
        try nodes.append(a, .{ .slot = .{ .name = name, .source_pos = offset + start } });
        return start + tag_end + 1;
    }

    const slot_close = comptime closeTag("slot");
    const close_pos = std.mem.indexOf(u8, rest[tag_end + 1 ..], slot_close) orelse
        return error.MalformedElement;
    const default_body = try parseContent(a, rest[tag_end + 1 .. tag_end + 1 + close_pos], offset + start + tag_end + 1);

    try nodes.append(a, .{ .slot = .{ .name = name, .default_body = default_body, .source_pos = offset + start } });
    return start + tag_end + 1 + close_pos + slot_close.len;
}

fn parseInclude(a: Allocator, input: []const u8, start: usize, nodes: *std.ArrayList(Node), offset: usize) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
    const tag = rest[0 .. tag_end + 1];
    const tmpl_name = h.extractAttrValue(tag, "template") orelse return error.MalformedElement;
    const attrs = try parseTagAttrList(a, tag);

    var consumed: usize = tag_end + 1;
    var result: DefineResult = .{};

    if (!is_self_closing) {
        const include_close = comptime closeTag("include");
        const close_pos = std.mem.indexOf(u8, rest[tag_end + 1 ..], include_close) orelse
            return error.MalformedElement;
        const raw_body = rest[tag_end + 1 .. tag_end + 1 + close_pos];
        const strip = try indent_mod.stripCommonIndent(a, raw_body);
        consumed = tag_end + 1 + close_pos + include_close.len;
        if (strip.slice.len > 0) result = try parseDefines(a, strip.slice, offset + start + tag_end + 1);
    }

    try nodes.append(a, .{ .include = .{
        .template = tmpl_name,
        .attrs = attrs,
        .defines = result.defines,
        .anonymous_body = result.anonymous_body,
        .anonymous_body_source = result.anonymous_body_source,
        .source_pos = offset + start,
    } });
    return start + consumed;
}

fn parseFor(a: Allocator, input: []const u8, start: usize, nodes: *std.ArrayList(Node), offset: usize) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
    const tag = rest[0 .. tag_end + 1];
    const attrs = try parseForAttrs(tag);

    const body_start = start + tag_end + 1;
    const for_close = comptime closeTag("for");
    const close_offset = h.findMatchingClose(input[body_start..], openTag("for"), for_close) orelse
        return error.MalformedElement;
    const body = try parseContent(a, input[body_start .. body_start + close_offset], offset + body_start);

    try nodes.append(a, .{ .loop = .{
        .item_prefix = attrs.item_prefix,
        .collection = attrs.collection,
        .alias = attrs.alias,
        .sort_field = attrs.sort_field,
        .order_desc = attrs.order_desc,
        .limit = attrs.limit,
        .offset = attrs.offset,
        .body = body,
        .source_pos = offset + start,
    } });
    return body_start + close_offset + for_close.len;
}

const ForAttrs = struct {
    item_prefix: []const u8,
    collection: []const u8,
    alias: ?[]const u8,
    sort_field: ?[]const u8,
    order_desc: bool,
    limit: ?usize,
    offset: ?usize,
};

fn parseForAttrs(tag: []const u8) ParseError!ForAttrs {
    const for_open = openTag("for");
    const space = std.mem.indexOfPos(u8, tag, for_open.len, " ") orelse
        return error.MalformedElement;
    const in_tok = std.mem.indexOf(u8, tag, " in ") orelse return error.MalformedElement;
    const alias: ?[]const u8 = blk: {
        const as_tok = std.mem.indexOfPos(u8, tag, in_tok + 4, " as ") orelse break :blk null;
        const word = extractWord(tag, as_tok + 4);
        break :blk if (word.len > 0) word else null;
    };
    return .{
        .item_prefix = tag[for_open.len..space],
        .collection = extractWord(tag, in_tok + 4),
        .alias = alias,
        .sort_field = h.extractAttrValue(tag, "sort"),
        .order_desc = if (h.extractAttrValue(tag, "order")) |o| std.mem.eql(u8, o, "desc") else false,
        .limit = try parseUintAttr(tag, "limit"),
        .offset = try parseUintAttr(tag, "offset"),
    };
}

fn extractWord(input: []const u8, start: usize) []const u8 {
    var end = start;
    while (end < input.len and input[end] != ' ' and input[end] != '>' and input[end] != '/') : (end += 1) {}
    return input[start..end];
}

fn parseConditional(a: Allocator, input: []const u8, start: usize, nodes: *std.ArrayList(Node), offset: usize) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse return error.MalformedElement;
    const if_tag = rest[0 .. tag_end + 1];
    const body_start = tag_end + 1;

    const if_close = comptime closeTag("if");
    const close_pos = h.findMatchingClose(rest[body_start..], openTag("if"), if_close) orelse
        return error.MalformedElement;
    const full_body = rest[body_start .. body_start + close_pos];
    const body_offset = offset + start + body_start;
    const result = try parseBranches(a, if_tag, full_body, body_offset);

    try nodes.append(a, .{ .conditional = .{
        .branches = result.branches,
        .else_body = result.else_body,
        .source_pos = offset + start,
    } });
    return start + body_start + close_pos + if_close.len;
}

fn parseBranches(a: Allocator, if_tag: []const u8, full_body: []const u8, body_offset: usize) ParseError!struct {
    branches: []const N.Branch,
    else_body: []const Node,
} {
    var branches: std.ArrayList(N.Branch) = .{};
    const first_sep = findConditionalSeparator(full_body, 0);
    const if_body_source = if (first_sep) |sep| full_body[0..sep.pos] else full_body;
    try branches.append(a, .{
        .condition = parseCondition(if_tag),
        .body = try parseContent(a, if_body_source, body_offset),
    });

    var else_body: []const Node = &.{};
    if (first_sep) |first| {
        var cursor = first;
        while (true) {
            if (cursor.is_else) {
                else_body = try parseContent(a, full_body[cursor.pos + cursor.tag_len ..], body_offset + cursor.pos + cursor.tag_len);
                break;
            }
            const elif_tag = full_body[cursor.pos .. cursor.pos + cursor.tag_len];
            const next_start = cursor.pos + cursor.tag_len;
            const next_sep = findConditionalSeparator(full_body, next_start);
            const body_src = if (next_sep) |ns| full_body[next_start..ns.pos] else full_body[next_start..];
            try branches.append(a, .{
                .condition = parseCondition(elif_tag),
                .body = try parseContent(a, body_src, body_offset + next_start),
            });
            if (next_sep) |ns| {
                cursor = ns;
            } else break;
        }
    }

    return .{
        .branches = try branches.toOwnedSlice(a),
        .else_body = else_body,
    };
}

fn parseBoundTag(a: Allocator, tag: []const u8, nodes: *std.ArrayList(Node), tag_offset: usize) ParseError!void {
    var segments: std.ArrayList(N.Segment) = .{};
    var literal_start: usize = 0;
    var i: usize = 0;

    while (i < tag.len) {
        if (i > 0 and tag[i] == ' ' and i + 1 < tag.len) {
            if (matchBinding(tag[i + 1 ..])) |b| {
                if (i > literal_start) try segments.append(a, .{ .literal = tag[literal_start..i] });
                const result = extractBinding(tag, i + 1, b);
                try segments.append(a, result.segment);
                i = result.end;
                literal_start = i;
                continue;
            }
        }
        i += 1;
    }

    if (literal_start < tag.len) try segments.append(a, .{ .literal = tag[literal_start..] });
    try nodes.append(a, .{ .bound_tag = .{
        .segments = try segments.toOwnedSlice(a),
        .source_pos = tag_offset,
    } });
}

const BindingMatch = struct { len: usize, is_var: bool };

fn matchBinding(input: []const u8) ?BindingMatch {
    const var_binding = comptime prefix ++ "var:";
    const attr_binding = comptime prefix ++ "attr:";
    if (std.mem.startsWith(u8, input, var_binding)) return .{ .len = var_binding.len, .is_var = true };
    if (std.mem.startsWith(u8, input, attr_binding)) return .{ .len = attr_binding.len, .is_var = false };
    return null;
}

fn extractBinding(tag: []const u8, bind_start: usize, b: BindingMatch) struct { segment: N.Segment, end: usize } {
    var j = bind_start + b.len;
    const attr_start = j;
    while (j < tag.len and tag[j] != '=') : (j += 1) {}
    const html_attr = tag[attr_start..j];
    j += 2;
    const ref_start = j;
    while (j < tag.len and tag[j] != '"') : (j += 1) {}
    const ref_name = tag[ref_start..j];
    j += 1;
    return .{
        .segment = .{ .binding = .{ .html_attr = html_attr, .ref_name = ref_name, .is_var = b.is_var } },
        .end = j,
    };
}

// ---- Define block parsing (shared between extend and include) ----

const DefineResult = struct {
    defines: []const N.Define = &.{},
    anonymous_body: []const Node = &.{},
    anonymous_body_source: []const u8 = "",
};

fn parseDefines(a: Allocator, body: []const u8, body_offset: usize) ParseError!DefineResult {
    const define_open = openTag("define");
    const define_close = comptime closeTag("define");
    var defines: std.ArrayList(N.Define) = .{};
    var seen_names: std.ArrayList([]const u8) = .{};
    var anon_parts: std.ArrayList(u8) = .{};
    var i: usize = 0;

    while (i < body.len) {
        if (std.mem.startsWith(u8, body[i..], define_open)) {
            const result = try parseSingleDefine(a, body[i..], define_close, body_offset + i);
            for (seen_names.items) |seen| {
                if (std.mem.eql(u8, seen, result.name)) return error.DuplicateSlotDefinition;
            }
            try seen_names.append(a, result.name);
            try defines.append(a, result.define);
            i += result.consumed;
        } else {
            try anon_parts.append(a, body[i]);
            i += 1;
        }
    }

    const trimmed = std.mem.trim(u8, anon_parts.items, " \t\r\n");
    return .{
        .defines = try defines.toOwnedSlice(a),
        .anonymous_body = if (trimmed.len > 0) try parseContent(a, trimmed, body_offset) else &.{},
        .anonymous_body_source = if (trimmed.len > 0) try a.dupe(u8, trimmed) else "",
    };
}

const ParsedDefine = struct {
    define: N.Define,
    name: []const u8,
    consumed: usize,
};

fn parseSingleDefine(a: Allocator, rest: []const u8, define_close: []const u8, define_offset: usize) ParseError!ParsedDefine {
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
    const raw_source = try a.dupe(u8, stripped.slice);
    return .{
        .define = .{ .name = name, .body = try parseContent(a, stripped.slice, define_offset + content_start), .raw_source = raw_source },
        .name = name,
        .consumed = content_start + close + define_close.len,
    };
}

// ---- Condition parsing ----

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

// ---- Attribute and transform parsing ----

fn parseTransformAttr(a: Allocator, tag: []const u8) ParseError![]const N.TransformStep {
    const spec = h.extractAttrValue(tag, "transform") orelse return &.{};
    return parseTransformSpec(a, spec);
}

fn parseTransformSpec(a: Allocator, spec: []const u8) ParseError![]const N.TransformStep {
    var steps: std.ArrayList(N.TransformStep) = .{};
    var pipe_iter = std.mem.splitScalar(u8, spec, '|');

    while (pipe_iter.next()) |xform| {
        if (xform.len == 0) continue;
        var colon_iter = std.mem.splitScalar(u8, xform, ':');
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

// ---- Conditional separator detection ----

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

test "parse source positions" {
    var result = try parse(testing.allocator, "hi <t-var name=\"x\" />");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.nodes.len);
    try testing.expectEqual(@as(usize, 3), result.nodes[1].variable.source_pos);
}

test "parse nested source positions" {
    var result = try parse(testing.allocator, "<t-if var=\"a\">XY<t-var name=\"b\" /></t-if>");
    defer result.deinit();
    const body = result.nodes[0].conditional.branches[0].body;
    try testing.expectEqual(@as(usize, 2), body.len);
    const var_pos = body[1].variable.source_pos;
    try testing.expectEqual(@as(usize, 16), var_pos);
}
