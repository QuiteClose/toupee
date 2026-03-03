const std = @import("std");
const Allocator = std.mem.Allocator;
const N = @import("Node.zig");
const Node = N.Node;
const Ctx = @import("Context.zig");
const Context = Ctx.Context;
const Resolver = Ctx.Resolver;
const RenderError = Ctx.RenderError;
const V = @import("Value.zig");
const h = @import("html.zig");
const transform = @import("transform.zig");
const indent_mod = @import("indent.zig");
const Parser = @import("Parser.zig");

pub const Options = struct {
    max_depth: usize = 50,
    template_name: []const u8 = "<input>",
    template_source: []const u8 = "",
    registry: ?*const transform.Registry = null,
};

const State = struct {
    a: Allocator,
    resolver: *const Resolver,
    max_depth: usize,
    template_name: []const u8,
    template_source: []const u8,
    registry: ?*const transform.Registry,
    include_stack_buf: [16]Ctx.IncludeEntry,
    include_stack_len: u8,

    fn pushInclude(self: State, name: []const u8, source: []const u8, line: usize) State {
        var new = self;
        if (self.include_stack_len < 16) {
            new.include_stack_buf[self.include_stack_len] = .{
                .template = self.template_name,
                .line = line,
            };
            new.include_stack_len = self.include_stack_len + 1;
        }
        new.template_name = name;
        new.template_source = source;
        return new;
    }
};

pub fn render(
    caller_a: Allocator,
    nodes: []const Node,
    ctx: *const Context,
    resolver: *const Resolver,
    options: Options,
) RenderError![]const u8 {
    var arena = std.heap.ArenaAllocator.init(caller_a);
    defer arena.deinit();
    const a = arena.allocator();

    var mutable_ctx: Context = .{
        .data = try copyMap(a, ctx.data),
        .attrs = ctx.attrs,
        .slots = ctx.slots,
        .err_detail = ctx.err_detail,
    };

    const state: State = .{
        .a = a,
        .resolver = resolver,
        .max_depth = options.max_depth,
        .template_name = options.template_name,
        .template_source = options.template_source,
        .registry = options.registry,
        .include_stack_buf = [_]Ctx.IncludeEntry{.{}} ** 16,
        .include_stack_len = 0,
    };
    const result = try renderNodes(state, nodes, &mutable_ctx, 0);
    return try caller_a.dupe(u8, result);
}

fn renderNodes(state: State, nodes: []const Node, ctx: *Context, depth: usize) RenderError![]const u8 {
    if (depth > state.max_depth) {
        setRichError(state, ctx, 0, .circular_reference, state.template_name);
        return error.CircularReference;
    }

    var out: std.ArrayList(u8) = .{};
    for (nodes) |node| {
        switch (node) {
            .text => |text| try out.appendSlice(state.a, text),
            .variable => |v| try renderVariable(state, v, ctx, depth, &out, true),
            .raw_variable => |v| try renderVariable(state, v, ctx, depth, &out, false),
            .let_binding => |lb| try renderLet(state, lb, ctx, depth),
            .comment => {},
            .attr_output => |ao| try renderAttrOutput(state, ao, ctx, &out),
            .slot => |s| try renderSlot(state, s, ctx, depth, &out),
            .include => |inc| try renderInclude(state, inc, ctx, depth, &out),
            .extend => |ext| try renderExtend(state, ext, ctx, depth, &out),
            .conditional => |cond| try renderConditional(state, cond, ctx, depth, &out),
            .loop => |loop| try renderLoop(state, loop, ctx, depth, &out),
            .bound_tag => |bt| try renderBoundTag(state, bt, ctx, &out),
        }
    }

    return out.toOwnedSlice(state.a);
}

// ---- Element renderers ----

fn renderVariable(
    state: State,
    v: N.Variable,
    ctx: *Context,
    depth: usize,
    out: *std.ArrayList(u8),
    escape: bool,
) RenderError!void {
    var value: []const u8 = "";

    if (ctx.resolveString(v.name)) |val| {
        value = val;
    } else if (v.has_body) {
        if (v.default_body.len > 0) value = try renderNodes(state, v.default_body, ctx, depth);
    } else if (v.transform.len > 0 and hasDefaultTransform(v.transform)) {
        // default transform will provide the value
    } else {
        setRichError(state, ctx, v.source_pos, .undefined_variable, v.name);
        return error.UndefinedVariable;
    }

    if (v.transform.len > 0) value = try applyTransforms(state, value, v.transform);
    if (escape) try h.appendEscaped(state.a, out, value) else try out.appendSlice(state.a, value);
}

fn renderLet(state: State, lb: N.LetBinding, ctx: *Context, depth: usize) RenderError!void {
    var rendered = try renderNodes(state, lb.body, ctx, depth);
    if (lb.transform.len > 0) rendered = try applyTransforms(state, rendered, lb.transform);
    try ctx.putData(state.a, lb.name, .{ .string = rendered });
}

fn renderAttrOutput(state: State, ao: N.AttrOutput, ctx: *const Context, out: *std.ArrayList(u8)) RenderError!void {
    if (ctx.getAttr(ao.name)) |value| try h.appendEscaped(state.a, out, value);
}

fn renderSlot(state: State, s: N.Slot, ctx: *Context, depth: usize, out: *std.ArrayList(u8)) RenderError!void {
    const indent = try state.a.dupe(u8, indent_mod.detectIndent(out.items));
    if (ctx.getSlot(s.name)) |content| {
        const parse_result = Parser.parse(state.a, content) catch return error.MalformedElement;
        const rendered = try renderNodes(state, parse_result.nodes, ctx, depth);
        try indent_mod.appendIndented(state.a, out, rendered, indent);
    } else if (s.default_body.len > 0) {
        const rendered = try renderNodes(state, s.default_body, ctx, depth);
        try indent_mod.appendIndented(state.a, out, rendered, indent);
    }
}

fn renderInclude(state: State, inc: N.Include, ctx: *Context, depth: usize, out: *std.ArrayList(u8)) RenderError!void {
    const tmpl_content = state.resolver.get(inc.template) orelse {
        setRichError(state, ctx, inc.source_pos, .template_not_found, inc.template);
        return error.TemplateNotFound;
    };

    var child_slots: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    for (inc.defines) |def| try child_slots.put(state.a, def.name, def.raw_source);
    if (inc.anonymous_body_source.len > 0) try child_slots.put(state.a, "", inc.anonymous_body_source);

    var inc_attrs: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    for (inc.attrs) |attr| try inc_attrs.put(state.a, attr.name, attr.value);

    var child_ctx: Context = .{
        .data = ctx.data,
        .attrs = inc_attrs,
        .slots = child_slots,
        .err_detail = ctx.err_detail,
    };

    const indent = try state.a.dupe(u8, indent_mod.detectIndent(out.items));
    const lc = computeLineCol(state.template_source, inc.source_pos);
    const child_state = state.pushInclude(inc.template, tmpl_content, lc.line);
    const tmpl_parse = Parser.parse(state.a, tmpl_content) catch return error.MalformedElement;
    const rendered = try renderNodes(child_state, tmpl_parse.nodes, &child_ctx, depth + 1);
    try indent_mod.appendIndented(state.a, out, rendered, indent);
}

fn renderExtend(state: State, ext: N.Extend, ctx: *Context, depth: usize, out: *std.ArrayList(u8)) RenderError!void {
    var slots = try buildSlotMap(state.a, ctx, ext.defines);
    const rendered = try resolveExtendChain(state, ext.template, ctx, &slots, depth, ext.source_pos);
    try out.appendSlice(state.a, rendered);
}

fn buildSlotMap(a: Allocator, ctx: *const Context, defines: []const N.Define) RenderError!std.StringArrayHashMapUnmanaged([]const u8) {
    var slots: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    var sit = ctx.slots.iterator();
    while (sit.next()) |entry| try slots.put(a, entry.key_ptr.*, entry.value_ptr.*);
    for (defines) |def| try slots.put(a, def.name, def.raw_source);
    return slots;
}

fn resolveExtendChain(
    state: State,
    initial_template: []const u8,
    ctx: *Context,
    slots: *std.StringArrayHashMapUnmanaged([]const u8),
    depth: usize,
    source_pos: usize,
) RenderError![]const u8 {
    var visited: std.StringArrayHashMapUnmanaged(void) = .{};
    try visited.put(state.a, initial_template, {});
    var current_source = state.resolver.get(initial_template) orelse {
        setRichError(state, ctx, source_pos, .template_not_found, initial_template);
        return error.TemplateNotFound;
    };
    const lc = computeLineCol(state.template_source, source_pos);
    var current_state = state.pushInclude(initial_template, current_source, lc.line);

    while (true) {
        const parent_parse = Parser.parse(state.a, current_source) catch return error.MalformedElement;
        if (parent_parse.nodes.len == 0) return "";
        if (parent_parse.nodes[0] != .extend)
            return renderExtendLeaf(current_state, parent_parse.nodes, ctx, slots, depth);
        const parent_ext = parent_parse.nodes[0].extend;
        if (visited.contains(parent_ext.template)) {
            setRichError(current_state, ctx, parent_ext.source_pos, .circular_reference, parent_ext.template);
            return error.CircularReference;
        }
        try visited.put(state.a, parent_ext.template, {});
        try mergeDefines(state.a, slots, parent_ext.defines);
        current_source = state.resolver.get(parent_ext.template) orelse {
            setRichError(current_state, ctx, parent_ext.source_pos, .template_not_found, parent_ext.template);
            return error.TemplateNotFound;
        };
        const ext_lc = computeLineCol(current_state.template_source, parent_ext.source_pos);
        current_state = current_state.pushInclude(parent_ext.template, current_source, ext_lc.line);
    }
}

fn mergeDefines(a: Allocator, slots: *std.StringArrayHashMapUnmanaged([]const u8), defines: []const N.Define) RenderError!void {
    for (defines) |def| {
        if (!slots.contains(def.name)) try slots.put(a, def.name, def.raw_source);
    }
}

fn renderExtendLeaf(state: State, nodes: []const Node, ctx: *Context, slots: *std.StringArrayHashMapUnmanaged([]const u8), depth: usize) RenderError![]const u8 {
    var render_ctx: Context = .{ .data = ctx.data, .attrs = ctx.attrs, .slots = slots.*, .err_detail = ctx.err_detail };
    return renderNodes(state, nodes, &render_ctx, depth);
}

fn renderConditional(state: State, cond: N.Conditional, ctx: *Context, depth: usize, out: *std.ArrayList(u8)) RenderError!void {
    for (cond.branches) |branch| {
        if (evaluateCondition(branch.condition, ctx)) {
            const rendered = try renderNodes(state, branch.body, ctx, depth);
            try out.appendSlice(state.a, rendered);
            return;
        }
    }
    if (cond.else_body.len > 0) {
        const rendered = try renderNodes(state, cond.else_body, ctx, depth);
        try out.appendSlice(state.a, rendered);
    }
}

fn evaluateCondition(cond: N.Condition, ctx: *const Context) bool {
    if (cond.source == .slot) {
        const exists = ctx.hasSlot(cond.name);
        return switch (cond.comparison) {
            .not_exists => !exists,
            else => exists,
        };
    }
    if (cond.source == .attr) {
        return evalComparison(cond.comparison, ctx.getAttr(cond.name));
    }
    const resolved = ctx.resolve(cond.name);
    return switch (cond.comparison) {
        .exists => resolved != null,
        .not_exists => resolved == null,
        .equals => |expected| if (resolved) |rv| std.mem.eql(u8, rv.asString() orelse "", expected) else false,
        .not_equals => |expected| if (resolved) |rv| !std.mem.eql(u8, rv.asString() orelse "", expected) else true,
    };
}

fn evalComparison(comparison: N.Condition.Comparison, value: ?[]const u8) bool {
    return switch (comparison) {
        .exists => value != null,
        .not_exists => value == null,
        .equals => |expected| if (value) |v| std.mem.eql(u8, v, expected) else false,
        .not_equals => |expected| if (value) |v| !std.mem.eql(u8, v, expected) else true,
    };
}

fn renderLoop(state: State, loop: N.Loop, ctx: *Context, depth: usize, out: *std.ArrayList(u8)) RenderError!void {
    const resolved = ctx.resolve(loop.collection) orelse return;
    const list = resolved.asList() orelse return;
    const items = try state.a.dupe(V.Value, list);
    if (loop.sort_field) |field| sortItems(items, field, loop.order_desc);
    const final = applyLimitOffset(items, loop.limit, loop.offset);

    for (final, 0..) |item, idx| {
        var child_data = try copyMap(state.a, ctx.data);
        try child_data.put(state.a, loop.item_prefix, item);
        if (loop.alias) |alias| try putAliasMetadata(state.a, &child_data, alias, idx);

        var child_ctx: Context = .{
            .data = child_data,
            .attrs = ctx.attrs,
            .slots = ctx.slots,
            .err_detail = ctx.err_detail,
        };
        const rendered = try renderNodes(state, loop.body, &child_ctx, depth + 1);
        try out.appendSlice(state.a, rendered);
    }
}

fn sortItems(items: []V.Value, field: []const u8, descending: bool) void {
    const Sort = struct {
        field_name: []const u8,
        desc: bool,
        pub fn lessThan(self: @This(), lhs: V.Value, rhs: V.Value) bool {
            const a_val = if (lhs.resolve(self.field_name)) |v| v.asString() orelse "" else "";
            const b_val = if (rhs.resolve(self.field_name)) |v| v.asString() orelse "" else "";
            const cmp = std.mem.order(u8, a_val, b_val);
            if (self.desc) return cmp == .gt;
            return cmp == .lt;
        }
    };
    std.mem.sort(V.Value, items, Sort{ .field_name = field, .desc = descending }, Sort.lessThan);
}

fn applyLimitOffset(items: []V.Value, limit: ?usize, offset: ?usize) []V.Value {
    const off = if (offset) |o| @min(o, items.len) else 0;
    const sliced = items[off..];
    return if (limit) |l| sliced[0..@min(l, sliced.len)] else sliced;
}

fn copyMap(a: Allocator, source: V.Map) RenderError!V.Map {
    var result: V.Map = .{};
    var it = source.iterator();
    while (it.next()) |kv| try result.put(a, kv.key_ptr.*, kv.value_ptr.*);
    return result;
}

fn putAliasMetadata(a: Allocator, data: *V.Map, alias: []const u8, idx: usize) RenderError!void {
    var alias_map: V.Map = .{};
    try alias_map.put(a, "index", .{ .string = try std.fmt.allocPrint(a, "{d}", .{idx}) });
    try alias_map.put(a, "number", .{ .string = try std.fmt.allocPrint(a, "{d}", .{idx + 1}) });
    try data.put(a, alias, .{ .map = alias_map });
}

fn renderBoundTag(state: State, bt: N.BoundTag, ctx: *const Context, out: *std.ArrayList(u8)) RenderError!void {
    for (bt.segments) |segment| {
        switch (segment) {
            .literal => |text| try out.appendSlice(state.a, text),
            .binding => |b| {
                const value = if (b.is_var) ctx.resolveString(b.ref_name) else ctx.getAttr(b.ref_name);
                if (value) |v| {
                    try out.append(state.a, ' ');
                    try out.appendSlice(state.a, b.html_attr);
                    try out.appendSlice(state.a, "=\"");
                    try h.appendEscaped(state.a, out, v);
                    try out.append(state.a, '"');
                }
            },
        }
    }
}

// ---- Transform helpers ----

fn hasDefaultTransform(steps: []const N.TransformStep) bool {
    for (steps) |step| {
        if (std.mem.eql(u8, step.name, "default")) return true;
    }
    return false;
}

fn applyTransforms(state: State, value: []const u8, steps: []const N.TransformStep) RenderError![]u8 {
    var current = try state.a.dupe(u8, value);
    for (steps) |step| {
        current = try applyOne(state, current, step.name, step.args);
    }
    return current;
}

fn applyOne(state: State, value: []const u8, name: []const u8, args: []const []const u8) RenderError![]u8 {
    if (state.registry) |reg| {
        if (reg.get(name)) |func| return func(state.a, value, args);
    }
    return error.MalformedElement;
}

// ---- Error helpers ----

const LineCol = struct { line: usize, col: usize };

fn computeLineCol(source: []const u8, pos: usize) LineCol {
    if (source.len == 0) return .{ .line = 0, .col = 0 };
    var line: usize = 1;
    var col: usize = 1;
    for (source[0..@min(pos, source.len)]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

fn extractSourceLine(source: []const u8, pos: usize) []const u8 {
    if (source.len == 0) return "";
    const clamped = @min(pos, source.len - 1);
    var start = clamped;
    while (start > 0 and source[start - 1] != '\n') : (start -= 1) {}
    var end = clamped;
    while (end < source.len and source[end] != '\n') : (end += 1) {}
    return source[start..end];
}

fn computeCaretLen(source: []const u8, pos: usize) usize {
    if (pos >= source.len or source[pos] != '<') return 1;
    var i = pos + 1;
    while (i < source.len and source[i] != '>' and source[i] != '\n') : (i += 1) {}
    return if (i < source.len and source[i] == '>') i - pos + 1 else @max(i - pos, 1);
}

fn setRichError(state: State, ctx: *Context, pos: usize, kind: Ctx.ErrorDetail.Kind, name: []const u8) void {
    const ed = ctx.err_detail orelse return;
    const lc = computeLineCol(state.template_source, pos);
    ed.* = .{
        .kind = kind,
        .message = name,
        .source_file = state.template_name,
        .line = lc.line,
        .column = lc.col,
        .source_line = extractSourceLine(state.template_source, pos),
        .caret_len = computeCaretLen(state.template_source, pos),
        .include_stack_len = state.include_stack_len,
        .include_stack_buf = state.include_stack_buf,
    };
    if (kind == .undefined_variable) ed.suggestion = findSuggestion(name, ctx);
}

fn findSuggestion(name: []const u8, ctx: *const Context) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        const parent_path = name[0..dot];
        const leaf = name[dot + 1 ..];
        const root: V.Value = .{ .map = ctx.data };
        if (root.resolve(parent_path)) |parent_val| {
            if (parent_val.asMap()) |map| {
                const result = findClosestKey(leaf, map);
                if (result.len > 0) return result;
            }
        }
    }
    return findClosestKey(name, ctx.data);
}

fn findClosestKey(name: []const u8, map: V.Map) []const u8 {
    var best: []const u8 = "";
    var best_dist: usize = 3;
    var it = map.iterator();
    while (it.next()) |entry| {
        const d = levenshtein(name, entry.key_ptr.*);
        if (d > 0 and d < best_dist) {
            best_dist = d;
            best = entry.key_ptr.*;
        }
    }
    return best;
}

fn levenshtein(a_str: []const u8, b_str: []const u8) usize {
    if (a_str.len == 0) return b_str.len;
    if (b_str.len == 0) return a_str.len;
    if (b_str.len >= 256) return b_str.len;

    var row: [256]usize = undefined;
    for (0..b_str.len + 1) |j| row[j] = j;

    for (a_str) |a_ch| {
        var prev_diag = row[0];
        row[0] += 1;
        for (b_str, 0..) |b_ch, j| {
            const temp = row[j + 1];
            const cost: usize = if (a_ch == b_ch) 0 else 1;
            row[j + 1] = @min(@min(row[j + 1] + 1, row[j] + 1), prev_diag + cost);
            prev_diag = temp;
        }
    }
    return row[b_str.len];
}

// ---- Tests ----

const testing = std.testing;

test "render plain text" {
    const nodes = [_]Node{.{ .text = "hello" }};
    var ctx: Context = .{};
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "render variable" {
    const nodes = [_]Node{.{ .variable = .{ .name = "title" } }};
    var ctx: Context = .{};
    try ctx.putData(testing.allocator, "title", .{ .string = "Hello" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello", result);
}

test "render variable escapes html" {
    const nodes = [_]Node{.{ .variable = .{ .name = "v" } }};
    var ctx: Context = .{};
    try ctx.putData(testing.allocator, "v", .{ .string = "<b>bold</b>" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("&lt;b&gt;bold&lt;/b&gt;", result);
}

test "render raw variable" {
    const nodes = [_]Node{.{ .raw_variable = .{ .name = "v" } }};
    var ctx: Context = .{};
    try ctx.putData(testing.allocator, "v", .{ .string = "<b>bold</b>" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("<b>bold</b>", result);
}

test "render undefined variable is error" {
    const nodes = [_]Node{.{ .variable = .{ .name = "missing" } }};
    var ctx: Context = .{};
    var resolver: Resolver = .{};
    const result = render(testing.allocator, &nodes, &ctx, &resolver, .{});
    try testing.expectError(error.UndefinedVariable, result);
}

test "render variable with default body" {
    const default_body = [_]Node{.{ .text = "Fallback" }};
    const nodes = [_]Node{.{ .variable = .{ .name = "missing", .default_body = &default_body, .has_body = true } }};
    var ctx: Context = .{};
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Fallback", result);
}

test "render conditional true branch" {
    const body = [_]Node{.{ .text = "yes" }};
    const branches = [_]N.Branch{.{
        .condition = .{ .source = .variable, .name = "show" },
        .body = &body,
    }};
    const nodes = [_]Node{.{ .conditional = .{ .branches = &branches } }};
    var ctx: Context = .{};
    try ctx.putData(testing.allocator, "show", .{ .string = "1" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("yes", result);
}

test "render conditional else branch" {
    const body = [_]Node{.{ .text = "yes" }};
    const else_body = [_]Node{.{ .text = "no" }};
    const branches = [_]N.Branch{.{
        .condition = .{ .source = .variable, .name = "show" },
        .body = &body,
    }};
    const nodes = [_]Node{.{ .conditional = .{ .branches = &branches, .else_body = &else_body } }};
    var ctx: Context = .{};
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("no", result);
}

test "render bound tag" {
    const segments = [_]N.Segment{
        .{ .literal = "<a" },
        .{ .binding = .{ .html_attr = "href", .ref_name = "url", .is_var = true } },
        .{ .literal = ">" },
    };
    const nodes = [_]Node{.{ .bound_tag = .{ .segments = &segments } }};
    var ctx: Context = .{};
    try ctx.putData(testing.allocator, "url", .{ .string = "/home" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("<a href=\"/home\">", result);
}

test "render comment produces no output" {
    const nodes = [_]Node{ .{ .text = "a" }, .comment, .{ .text = "b" } };
    var ctx: Context = .{};
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("ab", result);
}

test "computeLineCol single line" {
    const lc = computeLineCol("hello world", 6);
    try testing.expectEqual(@as(usize, 1), lc.line);
    try testing.expectEqual(@as(usize, 7), lc.col);
}

test "computeLineCol multi line" {
    const lc = computeLineCol("abc\ndef\nghi", 8);
    try testing.expectEqual(@as(usize, 3), lc.line);
    try testing.expectEqual(@as(usize, 1), lc.col);
}

test "computeLineCol empty source" {
    const lc = computeLineCol("", 0);
    try testing.expectEqual(@as(usize, 0), lc.line);
    try testing.expectEqual(@as(usize, 0), lc.col);
}

test "extractSourceLine" {
    const line = extractSourceLine("abc\ndef\nghi", 5);
    try testing.expectEqualStrings("def", line);
}

test "extractSourceLine first line" {
    const line = extractSourceLine("hello", 2);
    try testing.expectEqualStrings("hello", line);
}

test "computeCaretLen tag" {
    const src = "<t-var name=\"x\" />";
    try testing.expectEqual(@as(usize, 18), computeCaretLen(src, 0));
}

test "computeCaretLen non-tag" {
    try testing.expectEqual(@as(usize, 1), computeCaretLen("hello", 2));
}

test "levenshtein identical" {
    try testing.expectEqual(@as(usize, 0), levenshtein("abc", "abc"));
}

test "levenshtein one insert" {
    try testing.expectEqual(@as(usize, 1), levenshtein("titl", "title"));
}

test "levenshtein one replace" {
    try testing.expectEqual(@as(usize, 1), levenshtein("abc", "axc"));
}

test "levenshtein one delete" {
    try testing.expectEqual(@as(usize, 1), levenshtein("title", "titl"));
}

test "levenshtein empty" {
    try testing.expectEqual(@as(usize, 3), levenshtein("", "abc"));
    try testing.expectEqual(@as(usize, 3), levenshtein("abc", ""));
}

test "levenshtein both empty" {
    try testing.expectEqual(@as(usize, 0), levenshtein("", ""));
}

test "rich error populates ErrorDetail" {
    const source = "<t-var name=\"titl\" />";
    const nodes = [_]Node{.{ .variable = .{ .name = "titl", .source_pos = 0 } }};
    var ed: Ctx.ErrorDetail = .{};
    var ctx: Context = .{ .err_detail = &ed };
    try ctx.putData(testing.allocator, "title", .{ .string = "Hello" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};
    const result = render(testing.allocator, &nodes, &ctx, &resolver, .{
        .template_name = "page.html",
        .template_source = source,
    });
    try testing.expectError(error.UndefinedVariable, result);
    try testing.expectEqual(Ctx.ErrorDetail.Kind.undefined_variable, ed.kind);
    try testing.expectEqualStrings("titl", ed.message);
    try testing.expectEqualStrings("page.html", ed.source_file);
    try testing.expectEqual(@as(usize, 1), ed.line);
    try testing.expectEqual(@as(usize, 1), ed.column);
    try testing.expectEqualStrings("title", ed.suggestion);
    try testing.expectEqualStrings(source, ed.source_line);
    try testing.expectEqual(@as(usize, 21), ed.caret_len);
}

test "rich error with include stack" {
    const child_source = "<t-var name=\"missing\" />";
    const parent_source = "<t-include template=\"child.html\" />";
    var ed: Ctx.ErrorDetail = .{};
    var ctx: Context = .{ .err_detail = &ed };
    var resolver: Resolver = .{};
    try resolver.put(testing.allocator, "child.html", child_source);
    defer resolver.deinit(testing.allocator);
    const parent_nodes = [_]Node{.{ .include = .{ .template = "child.html", .source_pos = 0 } }};
    const result = render(testing.allocator, &parent_nodes, &ctx, &resolver, .{
        .template_name = "parent.html",
        .template_source = parent_source,
    });
    try testing.expectError(error.UndefinedVariable, result);
    try testing.expectEqual(Ctx.ErrorDetail.Kind.undefined_variable, ed.kind);
    try testing.expectEqualStrings("missing", ed.message);
    try testing.expectEqualStrings("child.html", ed.source_file);
    try testing.expectEqual(@as(u8, 1), ed.include_stack_len);
    try testing.expectEqualStrings("parent.html", ed.includeStack()[0].template);
}
