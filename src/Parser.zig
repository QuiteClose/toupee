const std = @import("std");
const Allocator = std.mem.Allocator;
const N = @import("Node.zig");
const Node = N.Node;
const h = @import("html.zig");
const indent_mod = @import("indent.zig");
const diagnostic = @import("diagnostic.zig");
const ErrorDetail = diagnostic.ErrorDetail;

/// Errors that may occur during template parsing.
pub const ParseError = error{
    MalformedElement,
    DuplicateSlotDefinition,
    OutOfMemory,
    TemplateNotFound,
    CircularReference,
    UndefinedVariable,
};

/// Optional parameters for parse(). Pass err_detail to receive rich error context;
/// template_name is used in error messages.
pub const ParseOptions = struct {
    err_detail: ?*ErrorDetail = null,
    template_name: []const u8 = "<input>",
};

const ParseState = struct {
    a: Allocator,
    full_source: []const u8,
    err_detail: ?*ErrorDetail,
    template_name: []const u8,

    fn fail(self: ParseState, pos: usize, kind: ErrorDetail.Kind, message: []const u8) void {
        diagnostic.setError(self.err_detail, self.full_source, pos, kind, message, self.template_name);
    }
};

/// Result of parsing. Owns the arena that holds all parsed nodes. Caller must call
/// deinit() when done, or manage the arena externally.
pub const ParseResult = struct {
    nodes: []const Node,
    arena: std.heap.ArenaAllocator,

    /// Frees the arena and all parsed nodes.
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

/// Parses template source into a flat []Node IR. Main entry point for the parser.
pub fn parse(child_allocator: Allocator, source: []const u8, options: ParseOptions) ParseError!ParseResult {
    var arena = std.heap.ArenaAllocator.init(child_allocator);
    errdefer arena.deinit();

    const state: ParseState = .{
        .a = arena.allocator(),
        .full_source = source,
        .err_detail = options.err_detail,
        .template_name = options.template_name,
    };

    const start = h.skipWhitespace(source);
    const rest = source[start..];
    const extend_open = comptime "<" ++ prefix ++ "extend ";
    const extend_open_bare = comptime "<" ++ prefix ++ "extend>";

    if (std.mem.startsWith(u8, rest, extend_open) or
        std.mem.startsWith(u8, rest, extend_open_bare))
    {
        const nodes = try parseExtend(state, rest, start);
        return .{ .nodes = nodes, .arena = arena };
    }

    const nodes = try parseContent(state, source, 0);
    return .{ .nodes = nodes, .arena = arena };
}

fn parseExtend(state: ParseState, input: []const u8, offset: usize) ParseError![]const Node {
    const tag_end = h.findTagEnd(input) orelse {
        state.fail(offset, .malformed_element, "unclosed <t-extend> tag");
        return error.MalformedElement;
    };
    const tag = input[0 .. tag_end + 1];
    const template_name = h.extractAttrValue(tag, "template") orelse {
        state.fail(offset, .malformed_element, "missing 'template' attribute on <t-extend>");
        return error.MalformedElement;
    };

    const result = try parseDefines(state, input[tag_end + 1 ..], offset + tag_end + 1);
    var nodes: std.ArrayList(Node) = .{};
    try nodes.append(state.a, .{ .extend = .{
        .template = template_name,
        .defines = result.defines,
        .source_pos = offset,
    } });
    return nodes.toOwnedSlice(state.a);
}

// ---- Content parsing ----

fn parseContent(state: ParseState, input: []const u8, offset: usize) ParseError![]const Node {
    var nodes: std.ArrayList(Node) = .{};
    var text_start: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        if (input[i] != '<') {
            i += 1;
            continue;
        }
        if (matchElement(input[i..])) |elem| {
            try flushText(state, &nodes, input, text_start, i);
            i = try dispatchElement(state, input, i, &nodes, elem, offset);
            text_start = i;
            continue;
        }
        if (findBoundTagEnd(input, i)) |end_offset| {
            try flushText(state, &nodes, input, text_start, i);
            try parseBoundTag(state, input[i .. i + end_offset + 1], &nodes, offset + i);
            i += end_offset + 1;
            text_start = i;
            continue;
        }
        i += 1;
    }

    try flushText(state, &nodes, input, text_start, input.len);
    return nodes.toOwnedSlice(state.a);
}

fn dispatchElement(
    state: ParseState,
    input: []const u8,
    start: usize,
    nodes: *std.ArrayList(Node),
    elem: Element,
    offset: usize,
) ParseError!usize {
    return switch (elem) {
        .t_var => parseVarOrRaw(state, input, start, nodes, true, offset),
        .t_raw => parseVarOrRaw(state, input, start, nodes, false, offset),
        .t_let => parseLet(state, input, start, nodes, offset),
        .t_comment => blk: {
            const pos = try parseComment(state, input, start, offset);
            try nodes.append(state.a, .comment);
            break :blk pos;
        },
        .t_debug => blk: {
            const rest = input[start..];
            const tag_end = h.findTagEnd(rest) orelse {
                state.fail(offset + start, .malformed_element, "unclosed <t-debug> tag");
                return error.MalformedElement;
            };
            try nodes.append(state.a, .debug);
            break :blk start + tag_end + 1;
        },
        .t_attr => parseAttrOutput(state, input, start, nodes, offset),
        .t_slot => parseSlot(state, input, start, nodes, offset),
        .t_include => parseInclude(state, input, start, nodes, offset),
        .t_for => parseFor(state, input, start, nodes, offset),
        .t_if => parseConditional(state, input, start, nodes, offset),
        .t_else, .t_elif => {
            state.fail(offset + start, .malformed_element, "stray <t-else> or <t-elif> outside conditional or loop");
            return error.MalformedElement;
        },
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

pub const Element = enum { t_var, t_raw, t_let, t_comment, t_debug, t_attr, t_slot, t_include, t_for, t_if, t_else, t_elif };

/// Valid element names for the `t-` prefix. Shared between runtime parser and comptime validator.
pub const valid_element_names = [_][]const u8{
    "var", "raw", "let", "comment", "debug", "attr", "slot", "include", "for", "if", "else", "elif", "extend", "define",
};

/// Elements requiring a closing tag (block elements).
pub const block_elements = [_][]const u8{
    "var", "raw", "let", "comment", "slot", "include", "for", "if", "extend", "define",
};

/// Elements that must have a `name` attribute.
pub const name_required = [_][]const u8{
    "var", "raw", "let", "attr", "slot", "define",
};

/// Elements that must have a `template` attribute.
pub const template_required = [_][]const u8{
    "include", "extend",
};

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
        .{ "<" ++ prefix ++ "debug", Element.t_debug },
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

fn flushText(state: ParseState, nodes: *std.ArrayList(Node), input: []const u8, start: usize, end: usize) ParseError!void {
    if (end > start) try nodes.append(state.a, .{ .text = input[start..end] });
}

// ---- Element parsers ----

fn parseVarOrRaw(state: ParseState, input: []const u8, start: usize, nodes: *std.ArrayList(Node), escape: bool, offset: usize) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse {
        state.fail(offset + start, .malformed_element, "unclosed variable tag");
        return error.MalformedElement;
    };
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
    const tag = rest[0 .. tag_end + 1];

    const name = h.extractAttrValue(tag, "name") orelse {
        state.fail(offset + start, .malformed_element, "missing 'name' attribute");
        return error.MalformedElement;
    };
    const xform = try parseTransformAttr(state, tag);

    var consumed: usize = tag_end + 1;
    var default_body: []const Node = &.{};
    var has_body = false;

    if (!is_self_closing) {
        has_body = true;
        const close_str: []const u8 = if (escape) comptime closeTag("var") else comptime closeTag("raw");
        const close_pos = std.mem.indexOf(u8, rest[tag_end + 1 ..], close_str) orelse {
            state.fail(offset + start, .malformed_element, "missing closing tag");
            return error.MalformedElement;
        };
        default_body = try parseContent(state, rest[tag_end + 1 .. tag_end + 1 + close_pos], offset + start + tag_end + 1);
        consumed = tag_end + 1 + close_pos + close_str.len;
    }

    const variable: N.Variable = .{
        .name = name,
        .transform = xform,
        .default_body = default_body,
        .has_body = has_body,
        .source_pos = offset + start,
    };
    try nodes.append(state.a, if (escape) .{ .variable = variable } else .{ .raw_variable = variable });
    return start + consumed;
}

fn parseLet(state: ParseState, input: []const u8, start: usize, nodes: *std.ArrayList(Node), offset: usize) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse {
        state.fail(offset + start, .malformed_element, "unclosed <t-let> tag");
        return error.MalformedElement;
    };
    const tag = rest[0 .. tag_end + 1];
    const name = h.extractAttrValue(tag, "name") orelse {
        state.fail(offset + start, .malformed_element, "missing 'name' attribute on <t-let>");
        return error.MalformedElement;
    };
    const xform = try parseTransformAttr(state, tag);

    const let_close = comptime closeTag("let");
    const close_pos = std.mem.indexOf(u8, rest[tag_end + 1 ..], let_close) orelse {
        state.fail(offset + start, .malformed_element, "missing closing </t-let> tag");
        return error.MalformedElement;
    };
    const body = try parseContent(state, rest[tag_end + 1 .. tag_end + 1 + close_pos], offset + start + tag_end + 1);

    try nodes.append(state.a, .{ .let_binding = .{
        .name = name,
        .transform = xform,
        .body = body,
        .source_pos = offset + start,
    } });
    return start + tag_end + 1 + close_pos + let_close.len;
}

fn parseComment(state: ParseState, input: []const u8, start: usize, offset: usize) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse {
        state.fail(offset + start, .malformed_element, "unclosed <t-comment> tag");
        return error.MalformedElement;
    };
    if (tag_end > 0 and rest[tag_end - 1] == '/') return start + tag_end + 1;

    const comment_close = comptime closeTag("comment");
    const close_pos = std.mem.indexOf(u8, rest[tag_end + 1 ..], comment_close) orelse {
        state.fail(offset + start, .malformed_element, "missing closing </t-comment> tag");
        return error.MalformedElement;
    };
    return start + tag_end + 1 + close_pos + comment_close.len;
}

/// After `/>` or `</t-slot>`, if the next character starts a line break, skip it so a newline used to
/// format the template does not become a text node (avoids an extra blank line when combined with
/// slot fill that ends in `\n`).
fn consumeOptionalLineBreakAfterSlotTag(input: []const u8, pos: usize) usize {
    if (pos >= input.len) return pos;
    if (input[pos] == '\r' and pos + 1 < input.len and input[pos + 1] == '\n') return pos + 2;
    if (input[pos] == '\n') return pos + 1;
    return pos;
}

fn parseAttrOutput(state: ParseState, input: []const u8, start: usize, nodes: *std.ArrayList(Node), offset: usize) ParseError!usize {
    const rest = input[start..];
    const end_offset = std.mem.indexOf(u8, rest, "/>") orelse {
        state.fail(offset + start, .malformed_element, "unclosed <t-attr> tag");
        return error.MalformedElement;
    };
    const tag = rest[0 .. end_offset + 2];
    const name = h.extractAttrValue(tag, "name") orelse {
        state.fail(offset + start, .malformed_element, "missing 'name' attribute on <t-attr>");
        return error.MalformedElement;
    };
    try nodes.append(state.a, .{ .attr_output = .{ .name = name, .source_pos = offset + start } });
    return start + end_offset + 2;
}

fn parseSlot(state: ParseState, input: []const u8, start: usize, nodes: *std.ArrayList(Node), offset: usize) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse {
        state.fail(offset + start, .malformed_element, "unclosed <t-slot> tag");
        return error.MalformedElement;
    };
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
    const tag = rest[0 .. tag_end + 1];
    const name = h.extractAttrValue(tag, "name") orelse "";

    if (is_self_closing) {
        try nodes.append(state.a, .{ .slot = .{ .name = name, .source_pos = offset + start } });
        const after_tag = start + tag_end + 1;
        return consumeOptionalLineBreakAfterSlotTag(input, after_tag);
    }

    const slot_close = comptime closeTag("slot");
    const close_pos = std.mem.indexOf(u8, rest[tag_end + 1 ..], slot_close) orelse {
        state.fail(offset + start, .malformed_element, "missing closing </t-slot> tag");
        return error.MalformedElement;
    };
    const default_body = try parseContent(state, rest[tag_end + 1 .. tag_end + 1 + close_pos], offset + start + tag_end + 1);

    try nodes.append(state.a, .{ .slot = .{ .name = name, .default_body = default_body, .source_pos = offset + start } });
    const after_close = start + tag_end + 1 + close_pos + slot_close.len;
    return consumeOptionalLineBreakAfterSlotTag(input, after_close);
}

fn parseInclude(state: ParseState, input: []const u8, start: usize, nodes: *std.ArrayList(Node), offset: usize) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse {
        state.fail(offset + start, .malformed_element, "unclosed <t-include> tag");
        return error.MalformedElement;
    };
    const is_self_closing = tag_end > 0 and rest[tag_end - 1] == '/';
    const tag = rest[0 .. tag_end + 1];
    const tmpl_name = h.extractAttrValue(tag, "template") orelse {
        state.fail(offset + start, .malformed_element, "missing 'template' attribute on <t-include>");
        return error.MalformedElement;
    };
    const attrs = try parseTagAttrList(state, tag);

    var consumed: usize = tag_end + 1;
    var result: DefineResult = .{};

    if (!is_self_closing) {
        const include_close = comptime closeTag("include");
        const close_pos = std.mem.indexOf(u8, rest[tag_end + 1 ..], include_close) orelse {
            state.fail(offset + start, .malformed_element, "missing closing </t-include> tag");
            return error.MalformedElement;
        };
        const raw_body = rest[tag_end + 1 .. tag_end + 1 + close_pos];
        const strip = try indent_mod.stripCommonIndent(state.a, raw_body);
        consumed = tag_end + 1 + close_pos + include_close.len;
        if (strip.slice.len > 0) result = try parseDefines(state, strip.slice, offset + start + tag_end + 1);
    }

    const isolated = h.hasBoolAttr(tag, "isolated");
    // Context bindings apply to both isolated and inherited includes (overlay onto child context).
    const context_bindings = try parseContextBindings(state, h.extractAttrValue(tag, "context"));

    try nodes.append(state.a, .{ .include = .{
        .template = tmpl_name,
        .attrs = attrs,
        .defines = result.defines,
        .anonymous_body = result.anonymous_body,
        .anonymous_body_source = result.anonymous_body_source,
        .isolated = isolated,
        .context_bindings = context_bindings,
        .source_pos = offset + start,
    } });
    return start + consumed;
}

fn parseFor(state: ParseState, input: []const u8, start: usize, nodes: *std.ArrayList(Node), offset: usize) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse {
        state.fail(offset + start, .malformed_element, "unclosed <t-for> tag");
        return error.MalformedElement;
    };
    const tag = rest[0 .. tag_end + 1];
    const attrs = try parseForAttrs(state, tag, offset + start);

    const body_start = start + tag_end + 1;
    const for_close = comptime closeTag("for");
    const close_offset = h.findMatchingClose(input[body_start..], openTag("for"), for_close) orelse {
        state.fail(offset + start, .malformed_element, "missing closing </t-for> tag");
        return error.MalformedElement;
    };
    const full_body = input[body_start .. body_start + close_offset];
    const body_offset = offset + body_start;
    const split = splitForElse(full_body);

    try nodes.append(state.a, .{ .loop = .{
        .item_prefix = attrs.item_prefix,
        .collection = attrs.collection,
        .alias = attrs.alias,
        .sort_field = attrs.sort_field,
        .order_desc = attrs.order_desc,
        .limit = attrs.limit,
        .offset = attrs.offset,
        .body = try parseContent(state, split.body, body_offset),
        .else_body = if (split.else_body) |eb| try parseContent(state, eb, body_offset + split.else_offset) else &.{},
        .source_pos = offset + start,
    } });
    return body_start + close_offset + for_close.len;
}

const ForSplit = struct {
    body: []const u8,
    else_body: ?[]const u8,
    else_offset: usize,
};

fn splitForElse(full_body: []const u8) ForSplit {
    const match = findAtDepthZero(full_body, 0, .for_context) orelse
        return .{ .body = full_body, .else_body = null, .else_offset = 0 };
    return .{
        .body = full_body[0..match.pos],
        .else_body = full_body[match.pos + match.tag_len ..],
        .else_offset = match.pos + match.tag_len,
    };
}

const ScanContext = enum { for_context, if_context };

fn findAtDepthZero(body: []const u8, from: usize, context: ScanContext) ?Separator {
    const open_if = openTag("if");
    const close_if = comptime closeTag("if");
    const open_for = openTag("for");
    const close_for = comptime closeTag("for");
    const open_elif = openTag("elif");
    const open_else = comptime "<" ++ prefix ++ "else";

    var if_depth: usize = 0;
    var for_depth: usize = 0;
    var i = from;
    while (i < body.len) {
        if (std.mem.startsWith(u8, body[i..], open_if)) {
            if_depth += 1;
            i += open_if.len;
        } else if (std.mem.startsWith(u8, body[i..], close_if)) {
            if (context == .if_context and if_depth == 0) return null;
            if (if_depth > 0) if_depth -= 1;
            i += close_if.len;
        } else if (std.mem.startsWith(u8, body[i..], open_for)) {
            for_depth += 1;
            i += open_for.len;
        } else if (std.mem.startsWith(u8, body[i..], close_for)) {
            if (context == .for_context and for_depth == 0) break;
            if (for_depth > 0) for_depth -= 1;
            i += close_for.len;
        } else if (if_depth == 0 and for_depth == 0) {
            if (context == .if_context and std.mem.startsWith(u8, body[i..], open_elif)) {
                const tag_end = h.findTagEnd(body[i..]) orelse return null;
                return .{ .pos = i, .tag_len = tag_end + 1, .is_else = false };
            } else if (std.mem.startsWith(u8, body[i..], open_else)) {
                const tag_end = h.findTagEnd(body[i..]) orelse return null;
                return .{ .pos = i, .tag_len = tag_end + 1, .is_else = true };
            } else {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    return null;
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

fn parseForAttrs(state: ParseState, tag: []const u8, tag_offset: usize) ParseError!ForAttrs {
    const for_open = openTag("for");
    const space = std.mem.indexOfPos(u8, tag, for_open.len, " ") orelse {
        state.fail(tag_offset, .malformed_element, "missing item variable in <t-for>");
        return error.MalformedElement;
    };
    const in_tok = std.mem.indexOf(u8, tag, " in ") orelse {
        state.fail(tag_offset, .malformed_element, "missing 'in' keyword in <t-for>");
        return error.MalformedElement;
    };
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
        .limit = try parseUintAttr(state, tag, "limit", tag_offset),
        .offset = try parseUintAttr(state, tag, "offset", tag_offset),
    };
}

fn extractWord(input: []const u8, start: usize) []const u8 {
    var end = start;
    while (end < input.len and input[end] != ' ' and input[end] != '>' and input[end] != '/') : (end += 1) {}
    return input[start..end];
}

fn parseConditional(state: ParseState, input: []const u8, start: usize, nodes: *std.ArrayList(Node), offset: usize) ParseError!usize {
    const rest = input[start..];
    const tag_end = h.findTagEnd(rest) orelse {
        state.fail(offset + start, .malformed_element, "unclosed <t-if> tag");
        return error.MalformedElement;
    };
    const if_tag = rest[0 .. tag_end + 1];
    const body_start = tag_end + 1;

    const if_close = comptime closeTag("if");
    const close_pos = h.findMatchingClose(rest[body_start..], openTag("if"), if_close) orelse {
        state.fail(offset + start, .malformed_element, "missing closing </t-if> tag");
        return error.MalformedElement;
    };
    const full_body = rest[body_start .. body_start + close_pos];
    const body_offset = offset + start + body_start;
    const result = try parseBranches(state, if_tag, full_body, body_offset);

    try nodes.append(state.a, .{ .conditional = .{
        .branches = result.branches,
        .else_body = result.else_body,
        .source_pos = offset + start,
    } });
    return start + body_start + close_pos + if_close.len;
}

fn parseBranches(state: ParseState, if_tag: []const u8, full_body: []const u8, body_offset: usize) ParseError!struct {
    branches: []const N.Branch,
    else_body: []const Node,
} {
    var branches: std.ArrayList(N.Branch) = .{};
    const first_sep = findConditionalSeparator(full_body, 0);
    const if_body_source = if (first_sep) |sep| full_body[0..sep.pos] else full_body;
    try branches.append(state.a, .{
        .condition = parseCondition(if_tag),
        .body = try parseContent(state, if_body_source, body_offset),
    });

    var else_body: []const Node = &.{};
    if (first_sep) |first| {
        var cursor = first;
        while (true) {
            if (cursor.is_else) {
                else_body = try parseContent(state, full_body[cursor.pos + cursor.tag_len ..], body_offset + cursor.pos + cursor.tag_len);
                break;
            }
            const elif_tag = full_body[cursor.pos .. cursor.pos + cursor.tag_len];
            const next_start = cursor.pos + cursor.tag_len;
            const next_sep = findConditionalSeparator(full_body, next_start);
            const body_src = if (next_sep) |ns| full_body[next_start..ns.pos] else full_body[next_start..];
            try branches.append(state.a, .{
                .condition = parseCondition(elif_tag),
                .body = try parseContent(state, body_src, body_offset + next_start),
            });
            if (next_sep) |ns| {
                cursor = ns;
            } else break;
        }
    }

    return .{
        .branches = try branches.toOwnedSlice(state.a),
        .else_body = else_body,
    };
}

fn parseBoundTag(state: ParseState, tag: []const u8, nodes: *std.ArrayList(Node), tag_offset: usize) ParseError!void {
    var segments: std.ArrayList(N.Segment) = .{};
    var literal_start: usize = 0;
    var i: usize = 0;

    while (i < tag.len) {
        if (i > 0 and tag[i] == ' ' and i + 1 < tag.len) {
            if (matchBinding(tag[i + 1 ..])) |b| {
                if (i > literal_start) try segments.append(state.a, .{ .literal = tag[literal_start..i] });
                const result = extractBinding(tag, i + 1, b);
                try segments.append(state.a, result.segment);
                i = result.end;
                literal_start = i;
                continue;
            }
        }
        i += 1;
    }

    if (literal_start < tag.len) try segments.append(state.a, .{ .literal = tag[literal_start..] });
    try nodes.append(state.a, .{ .bound_tag = .{
        .segments = try segments.toOwnedSlice(state.a),
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

/// True if `input` starts with `<t-define>` or `<t-define ...>` (opening tag).
/// `openTag("define")` is `<t-define ` only; bare `<t-define>` must be recognized too.
fn startsWithDefineOpen(input: []const u8) bool {
    return std.mem.startsWith(u8, input, "<t-define>") or std.mem.startsWith(u8, input, openTag("define"));
}

fn parseDefines(state: ParseState, body: []const u8, body_offset: usize) ParseError!DefineResult {
    const define_close = comptime closeTag("define");
    var defines: std.ArrayList(N.Define) = .{};
    var seen_names: std.ArrayList([]const u8) = .{};
    var anon_parts: std.ArrayList(u8) = .{};
    var i: usize = 0;

    while (i < body.len) {
        if (startsWithDefineOpen(body[i..])) {
            const result = try parseSingleDefine(state, body[i..], define_close, body_offset + i);
            for (seen_names.items) |seen| {
                if (std.mem.eql(u8, seen, result.name)) {
                    state.fail(body_offset + i, .duplicate_slot, result.name);
                    return error.DuplicateSlotDefinition;
                }
            }
            try seen_names.append(state.a, result.name);
            try defines.append(state.a, result.define);
            i += result.consumed;
        } else {
            try anon_parts.append(state.a, body[i]);
            i += 1;
        }
    }

    const trimmed = std.mem.trim(u8, anon_parts.items, " \t\r\n");
    return .{
        .defines = try defines.toOwnedSlice(state.a),
        .anonymous_body = if (trimmed.len > 0) try parseContent(state, trimmed, body_offset) else &.{},
        .anonymous_body_source = if (trimmed.len > 0) try state.a.dupe(u8, trimmed) else "",
    };
}

const ParsedDefine = struct {
    define: N.Define,
    name: []const u8,
    consumed: usize,
};

fn parseSingleDefine(state: ParseState, rest: []const u8, define_close: []const u8, define_offset: usize) ParseError!ParsedDefine {
    const tag_end = h.findTagEnd(rest) orelse {
        state.fail(define_offset, .malformed_element, "unclosed <t-define> tag");
        return error.MalformedElement;
    };
    const tag = rest[0 .. tag_end + 1];
    // Default slot name "" matches anonymous / default slot fills (`<t-define>` with no attrs).
    const name = h.extractAttrValue(tag, "name") orelse
        h.extractAttrValue(tag, "slot") orelse "";
    const content_start = tag_end + 1;
    const close = std.mem.indexOf(u8, rest[content_start..], define_close) orelse {
        state.fail(define_offset, .malformed_element, "missing closing </t-define> tag");
        return error.MalformedElement;
    };
    const raw = rest[content_start .. content_start + close];
    const stripped = try indent_mod.stripCommonIndent(state.a, raw);
    const raw_source = try state.a.dupe(u8, stripped.slice);
    return .{
        .define = .{ .name = name, .body = try parseContent(state, stripped.slice, define_offset + content_start), .raw_source = raw_source },
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
    if (h.extractAttrValue(tag, "contains")) |val| return .{ .contains = val };
    if (h.extractAttrValue(tag, "starts-with")) |val| return .{ .starts_with = val };
    if (h.extractAttrValue(tag, "ends-with")) |val| return .{ .ends_with = val };
    if (h.extractAttrValue(tag, "matches")) |val| return .{ .matches = val };
    if (h.hasBoolAttr(tag, "not-exists")) return .not_exists;
    return .exists;
}

// ---- Attribute and transform parsing ----

fn parseTransformAttr(state: ParseState, tag: []const u8) ParseError![]const N.TransformStep {
    const spec = h.extractAttrValue(tag, "transform") orelse return &.{};
    return parseTransformSpec(state, spec);
}

fn parseTransformSpec(state: ParseState, spec: []const u8) ParseError![]const N.TransformStep {
    var steps: std.ArrayList(N.TransformStep) = .{};
    var pipe_iter = std.mem.splitScalar(u8, spec, '|');

    while (pipe_iter.next()) |xform| {
        if (xform.len == 0) continue;
        var colon_iter = std.mem.splitScalar(u8, xform, ':');
        const name = colon_iter.next().?;
        var args: std.ArrayList([]const u8) = .{};
        while (colon_iter.next()) |arg| try args.append(state.a, arg);
        try steps.append(state.a, .{ .name = name, .args = try args.toOwnedSlice(state.a) });
    }

    return steps.toOwnedSlice(state.a);
}

fn parseTagAttrList(state: ParseState, tag: []const u8) ParseError![]const N.Attr {
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
                if (!isReservedAttr(attr_name)) {
                    try attrs.append(state.a, .{ .name = attr_name, .value = attr_value });
                }
            }
        } else if (!isReservedAttr(attr_name)) {
            try attrs.append(state.a, .{ .name = attr_name, .value = "" });
        }
    }

    return attrs.toOwnedSlice(state.a);
}

fn isReservedAttr(name: []const u8) bool {
    return std.mem.eql(u8, name, "template") or
        std.mem.eql(u8, name, "isolated") or
        std.mem.eql(u8, name, "context");
}

fn parseContextBindings(state: ParseState, spec: ?[]const u8) ParseError![]const N.ContextBinding {
    const raw = spec orelse return &.{};
    if (raw.len == 0) return &.{};
    var bindings: std.ArrayList(N.ContextBinding) = .{};
    var iter = std.mem.splitScalar(u8, raw, ',');
    while (iter.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " ");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOf(u8, trimmed, " as ")) |as_pos| {
            const path = std.mem.trim(u8, trimmed[0..as_pos], " ");
            const key = std.mem.trim(u8, trimmed[as_pos + 4 ..], " ");
            try bindings.append(state.a, .{ .path = path, .key = key });
        } else {
            const leaf = if (std.mem.lastIndexOfScalar(u8, trimmed, '.')) |dot| trimmed[dot + 1 ..] else trimmed;
            try bindings.append(state.a, .{ .path = trimmed, .key = leaf });
        }
    }
    return bindings.toOwnedSlice(state.a);
}

fn parseUintAttr(state: ParseState, tag: []const u8, name: []const u8, tag_offset: usize) ParseError!?usize {
    const val = h.extractAttrValue(tag, name) orelse return null;
    return std.fmt.parseInt(usize, val, 10) catch {
        state.fail(tag_offset, .malformed_element, "invalid integer value for attribute");
        return error.MalformedElement;
    };
}

// ---- Conditional separator detection ----

const Separator = struct { pos: usize, tag_len: usize, is_else: bool };

fn findConditionalSeparator(body: []const u8, from: usize) ?Separator {
    return findAtDepthZero(body, from, .if_context);
}

// ---- Tests ----

const testing = std.testing;

test "parse plain text" {
    var result = try parse(testing.allocator, "hello world", .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.nodes.len);
    try testing.expectEqualStrings("hello world", result.nodes[0].text);
}

test "parse variable" {
    var result = try parse(testing.allocator, "<t-var name=\"title\" />", .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.nodes.len);
    try testing.expectEqualStrings("title", result.nodes[0].variable.name);
    try testing.expectEqual(@as(usize, 0), result.nodes[0].variable.transform.len);
}

test "parse raw variable" {
    var result = try parse(testing.allocator, "<t-raw name=\"content\" />", .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.nodes.len);
    try testing.expectEqualStrings("content", result.nodes[0].raw_variable.name);
}

test "parse variable with transform" {
    var result = try parse(testing.allocator, "<t-var name=\"title\" transform=\"upper|truncate:10\" />", .{});
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
    var result = try parse(testing.allocator, "<t-var name=\"title\">Untitled</t-var>", .{});
    defer result.deinit();
    const v = result.nodes[0].variable;
    try testing.expectEqualStrings("title", v.name);
    try testing.expectEqual(@as(usize, 1), v.default_body.len);
    try testing.expectEqualStrings("Untitled", v.default_body[0].text);
}

test "parse text with embedded variable" {
    var result = try parse(testing.allocator, "<p><t-var name=\"x\" /></p>", .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.nodes.len);
    try testing.expectEqualStrings("<p>", result.nodes[0].text);
    try testing.expectEqualStrings("x", result.nodes[1].variable.name);
    try testing.expectEqualStrings("</p>", result.nodes[2].text);
}

test "parse let binding" {
    var result = try parse(testing.allocator, "<t-let name=\"x\">hello</t-let>", .{});
    defer result.deinit();
    const lb = result.nodes[0].let_binding;
    try testing.expectEqualStrings("x", lb.name);
    try testing.expectEqual(@as(usize, 1), lb.body.len);
    try testing.expectEqualStrings("hello", lb.body[0].text);
}

test "parse comment self-closing" {
    var result = try parse(testing.allocator, "a<t-comment />b", .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.nodes.len);
    try testing.expectEqualStrings("a", result.nodes[0].text);
    try testing.expect(result.nodes[1] == .comment);
    try testing.expectEqualStrings("b", result.nodes[2].text);
}

test "parse comment block" {
    var result = try parse(testing.allocator, "a<t-comment>ignored</t-comment>b", .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.nodes.len);
    try testing.expectEqualStrings("a", result.nodes[0].text);
    try testing.expect(result.nodes[1] == .comment);
    try testing.expectEqualStrings("b", result.nodes[2].text);
}

test "parse attr output" {
    var result = try parse(testing.allocator, "<t-attr name=\"href\" />", .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.nodes.len);
    try testing.expectEqualStrings("href", result.nodes[0].attr_output.name);
}

test "parse slot self-closing" {
    var result = try parse(testing.allocator, "<t-slot name=\"main\" />", .{});
    defer result.deinit();
    const s = result.nodes[0].slot;
    try testing.expectEqualStrings("main", s.name);
    try testing.expectEqual(@as(usize, 0), s.default_body.len);
}

test "parse slot consumes one newline after self-closing tag" {
    const src = "<body><t-slot />\n</body>";
    var result = try parse(testing.allocator, src, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.nodes.len);
    try testing.expectEqualStrings("<body>", result.nodes[0].text);
    try testing.expectEqualStrings("", result.nodes[1].slot.name);
    try testing.expectEqualStrings("</body>", result.nodes[2].text);
}

test "parse slot with default" {
    var result = try parse(testing.allocator, "<t-slot name=\"main\">default</t-slot>", .{});
    defer result.deinit();
    const s = result.nodes[0].slot;
    try testing.expectEqualStrings("main", s.name);
    try testing.expectEqual(@as(usize, 1), s.default_body.len);
    try testing.expectEqualStrings("default", s.default_body[0].text);
}

test "parse include self-closing" {
    var result = try parse(testing.allocator, "<t-include template=\"card.html\" class=\"wide\" />", .{});
    defer result.deinit();
    const inc = result.nodes[0].include;
    try testing.expectEqualStrings("card.html", inc.template);
    try testing.expectEqual(@as(usize, 1), inc.attrs.len);
    try testing.expectEqualStrings("class", inc.attrs[0].name);
    try testing.expectEqualStrings("wide", inc.attrs[0].value);
}

test "parse include with anonymous body" {
    var result = try parse(testing.allocator, "<t-include template=\"box.html\">content</t-include>", .{});
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
    var result = try parse(testing.allocator, source, .{});
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
    var result = try parse(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.nodes.len);
    const ext = result.nodes[0].extend;
    try testing.expectEqualStrings("base.html", ext.template);
    try testing.expectEqual(@as(usize, 1), ext.defines.len);
    try testing.expectEqualStrings("content", ext.defines[0].name);
}

test "parse extend with bare t-define default slot" {
    const source =
        \\<t-extend template="base.html">
        \\<t-define>
        \\  <t-slot />
        \\</t-define>
    ;
    var result = try parse(testing.allocator, source, .{});
    defer result.deinit();
    const ext = result.nodes[0].extend;
    try testing.expectEqual(@as(usize, 1), ext.defines.len);
    try testing.expectEqualStrings("", ext.defines[0].name);
    try testing.expectEqual(@as(usize, 1), ext.defines[0].body.len);
    switch (ext.defines[0].body[0]) {
        .slot => |s| try testing.expectEqualStrings("", s.name),
        else => return error.ExpectedSlotNode,
    }
}

test "parse for loop" {
    var result = try parse(testing.allocator, "<t-for item in items>body</t-for>", .{});
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
    , .{});
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
    var result = try parse(testing.allocator, "<t-if var=\"show\">yes</t-if>", .{});
    defer result.deinit();
    const cond = result.nodes[0].conditional;
    try testing.expectEqual(@as(usize, 1), cond.branches.len);
    try testing.expectEqual(N.Condition.Source.variable, cond.branches[0].condition.source);
    try testing.expectEqualStrings("show", cond.branches[0].condition.name);
    try testing.expectEqual(@as(usize, 0), cond.else_body.len);
}

test "parse conditional with elif and else" {
    const source = "<t-if var=\"a\">A<t-elif var=\"b\" />B<t-else />C</t-if>";
    var result = try parse(testing.allocator, source, .{});
    defer result.deinit();
    const cond = result.nodes[0].conditional;
    try testing.expectEqual(@as(usize, 2), cond.branches.len);
    try testing.expectEqualStrings("a", cond.branches[0].condition.name);
    try testing.expectEqualStrings("b", cond.branches[1].condition.name);
    try testing.expectEqual(@as(usize, 1), cond.else_body.len);
    try testing.expectEqualStrings("C", cond.else_body[0].text);
}

test "parse conditional with equals" {
    var result = try parse(testing.allocator, "<t-if var=\"x\" equals=\"y\">match</t-if>", .{});
    defer result.deinit();
    const cond = result.nodes[0].conditional;
    switch (cond.branches[0].condition.comparison) {
        .equals => |v| try testing.expectEqualStrings("y", v),
        else => return error.TestUnexpectedResult,
    }
}

test "parse bound tag" {
    var result = try parse(testing.allocator, "<a t-var:href=\"url\">link</a>", .{});
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

test "parse debug element" {
    var result = try parse(testing.allocator, "a<t-debug />b", .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.nodes.len);
    try testing.expectEqualStrings("a", result.nodes[0].text);
    try testing.expect(result.nodes[1] == .debug);
    try testing.expectEqualStrings("b", result.nodes[2].text);
}

test "parse for-else" {
    var result = try parse(testing.allocator, "<t-for item in items>body<t-else />empty</t-for>", .{});
    defer result.deinit();
    const loop = result.nodes[0].loop;
    try testing.expectEqual(@as(usize, 1), loop.body.len);
    try testing.expectEqualStrings("body", loop.body[0].text);
    try testing.expectEqual(@as(usize, 1), loop.else_body.len);
    try testing.expectEqualStrings("empty", loop.else_body[0].text);
}

test "parse for without else has empty else_body" {
    var result = try parse(testing.allocator, "<t-for item in items>body</t-for>", .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.nodes[0].loop.else_body.len);
}

test "parse for-else ignores else inside nested if" {
    var result = try parse(testing.allocator, "<t-for item in items><t-if var=\"x\">yes<t-else />no</t-if><t-else />empty</t-for>", .{});
    defer result.deinit();
    const loop = result.nodes[0].loop;
    try testing.expectEqual(@as(usize, 1), loop.body.len);
    try testing.expect(loop.body[0] == .conditional);
    try testing.expectEqual(@as(usize, 1), loop.else_body.len);
    try testing.expectEqualStrings("empty", loop.else_body[0].text);
}

test "parse conditional with contains" {
    var result = try parse(testing.allocator, "<t-if var=\"x\" contains=\"hello\">yes</t-if>", .{});
    defer result.deinit();
    switch (result.nodes[0].conditional.branches[0].condition.comparison) {
        .contains => |v| try testing.expectEqualStrings("hello", v),
        else => return error.TestUnexpectedResult,
    }
}

test "parse conditional with starts-with" {
    var result = try parse(testing.allocator, "<t-if var=\"x\" starts-with=\"/blog\">yes</t-if>", .{});
    defer result.deinit();
    switch (result.nodes[0].conditional.branches[0].condition.comparison) {
        .starts_with => |v| try testing.expectEqualStrings("/blog", v),
        else => return error.TestUnexpectedResult,
    }
}

test "parse conditional with ends-with" {
    var result = try parse(testing.allocator, "<t-if var=\"x\" ends-with=\".html\">yes</t-if>", .{});
    defer result.deinit();
    switch (result.nodes[0].conditional.branches[0].condition.comparison) {
        .ends_with => |v| try testing.expectEqualStrings(".html", v),
        else => return error.TestUnexpectedResult,
    }
}

test "parse conditional with matches" {
    var result = try parse(testing.allocator, "<t-if var=\"x\" matches=\"*.html\">yes</t-if>", .{});
    defer result.deinit();
    switch (result.nodes[0].conditional.branches[0].condition.comparison) {
        .matches => |v| try testing.expectEqualStrings("*.html", v),
        else => return error.TestUnexpectedResult,
    }
}

test "parse stray else is error" {
    const result = parse(testing.allocator, "<t-else />", .{});
    try testing.expectError(error.MalformedElement, result);
}

test "parse unclosed var is error" {
    const result = parse(testing.allocator, "<t-var name=\"x\"", .{});
    try testing.expectError(error.MalformedElement, result);
}

test "parse empty template" {
    var result = try parse(testing.allocator, "", .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.nodes.len);
}

test "parse nested elements" {
    var result = try parse(testing.allocator, "<t-if var=\"show\"><t-var name=\"x\" /></t-if>", .{});
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
    const result = parse(testing.allocator, source, .{});
    try testing.expectError(error.DuplicateSlotDefinition, result);
}

test "parse source positions" {
    var result = try parse(testing.allocator, "hi <t-var name=\"x\" />", .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.nodes.len);
    try testing.expectEqual(@as(usize, 3), result.nodes[1].variable.source_pos);
}

test "parse nested source positions" {
    var result = try parse(testing.allocator, "<t-if var=\"a\">XY<t-var name=\"b\" /></t-if>", .{});
    defer result.deinit();
    const body = result.nodes[0].conditional.branches[0].body;
    try testing.expectEqual(@as(usize, 2), body.len);
    const var_pos = body[1].variable.source_pos;
    try testing.expectEqual(@as(usize, 16), var_pos);
}

test "parse include isolated with context bindings" {
    var result = try parse(testing.allocator,
        \\<t-include template="card.html" isolated context="post, site.title as title" />
    , .{});
    defer result.deinit();
    const inc = result.nodes[0].include;
    try testing.expectEqualStrings("card.html", inc.template);
    try testing.expect(inc.isolated);
    try testing.expectEqual(@as(usize, 2), inc.context_bindings.len);
    try testing.expectEqualStrings("post", inc.context_bindings[0].path);
    try testing.expectEqualStrings("post", inc.context_bindings[0].key);
    try testing.expectEqualStrings("site.title", inc.context_bindings[1].path);
    try testing.expectEqualStrings("title", inc.context_bindings[1].key);
}

test "parse include isolated without context" {
    var result = try parse(testing.allocator,
        \\<t-include template="badge.html" isolated label="New" />
    , .{});
    defer result.deinit();
    const inc = result.nodes[0].include;
    try testing.expect(inc.isolated);
    try testing.expectEqual(@as(usize, 0), inc.context_bindings.len);
    try testing.expectEqual(@as(usize, 1), inc.attrs.len);
    try testing.expectEqualStrings("label", inc.attrs[0].name);
    try testing.expectEqualStrings("New", inc.attrs[0].value);
}

test "parse include not isolated by default" {
    var result = try parse(testing.allocator,
        \\<t-include template="card.html" />
    , .{});
    defer result.deinit();
    try testing.expect(!result.nodes[0].include.isolated);
    try testing.expectEqual(@as(usize, 0), result.nodes[0].include.context_bindings.len);
}

test "parse include with context but not isolated" {
    var result = try parse(testing.allocator,
        \\<t-include template="list.html" context="document.children as posts" />
    , .{});
    defer result.deinit();
    const inc = result.nodes[0].include;
    try testing.expect(!inc.isolated);
    try testing.expectEqual(@as(usize, 1), inc.context_bindings.len);
    try testing.expectEqualStrings("document.children", inc.context_bindings[0].path);
    try testing.expectEqualStrings("posts", inc.context_bindings[0].key);
}

test "parse conditional with not-exists" {
    var result = try parse(testing.allocator, "<t-if var=\"x\" not-exists>yes</t-if>", .{});
    defer result.deinit();
    try testing.expect(result.nodes[0].conditional.branches[0].condition.comparison == .not_exists);
}

test "parse conditional with not-equals" {
    var result = try parse(testing.allocator, "<t-if var=\"x\" not-equals=\"draft\">yes</t-if>", .{});
    defer result.deinit();
    switch (result.nodes[0].conditional.branches[0].condition.comparison) {
        .not_equals => |v| try testing.expectEqualStrings("draft", v),
        else => return error.TestUnexpectedResult,
    }
}

test "parse conditional on attr source" {
    var result = try parse(testing.allocator, "<t-if attr=\"variant\" equals=\"primary\">yes</t-if>", .{});
    defer result.deinit();
    const cond = result.nodes[0].conditional.branches[0].condition;
    try testing.expectEqual(N.Condition.Source.attr, cond.source);
    try testing.expectEqualStrings("variant", cond.name);
}

test "parse conditional on slot source" {
    var result = try parse(testing.allocator, "<t-if slot=\"footer\">yes</t-if>", .{});
    defer result.deinit();
    try testing.expectEqual(N.Condition.Source.slot, result.nodes[0].conditional.branches[0].condition.source);
}

test "parse let binding with transform" {
    var result = try parse(testing.allocator, "<t-let name=\"slug\" transform=\"slugify\">Hello World</t-let>", .{});
    defer result.deinit();
    const lb = result.nodes[0].let_binding;
    try testing.expectEqualStrings("slug", lb.name);
    try testing.expectEqual(@as(usize, 1), lb.transform.len);
    try testing.expectEqualStrings("slugify", lb.transform[0].name);
}

test "parse variable has_body flag" {
    var self_closing = try parse(testing.allocator, "<t-var name=\"x\" />", .{});
    defer self_closing.deinit();
    try testing.expect(!self_closing.nodes[0].variable.has_body);

    var block = try parse(testing.allocator, "<t-var name=\"x\">default</t-var>", .{});
    defer block.deinit();
    try testing.expect(block.nodes[0].variable.has_body);
}
