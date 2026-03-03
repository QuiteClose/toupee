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
};

const State = struct {
    a: Allocator,
    resolver: *const Resolver,
    max_depth: usize,
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

    const state: State = .{ .a = a, .resolver = resolver, .max_depth = options.max_depth };
    const result = try renderNodes(state, nodes, &mutable_ctx, 0);
    return try caller_a.dupe(u8, result);
}

fn renderNodes(state: State, nodes: []const Node, ctx: *Context, depth: usize) RenderError![]const u8 {
    if (depth > state.max_depth) return error.CircularReference;

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
        setErrorDetail(ctx, v.name);
        return error.UndefinedVariable;
    }

    if (v.transform.len > 0) value = try applyTransforms(state.a, value, v.transform);
    if (escape) try h.appendEscaped(state.a, out, value) else try out.appendSlice(state.a, value);
}

fn renderLet(state: State, lb: N.LetBinding, ctx: *Context, depth: usize) RenderError!void {
    var rendered = try renderNodes(state, lb.body, ctx, depth);
    if (lb.transform.len > 0) rendered = try applyTransforms(state.a, rendered, lb.transform);
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
        setErrorDetail(ctx, inc.template);
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
    const tmpl_parse = Parser.parse(state.a, tmpl_content) catch return error.MalformedElement;
    const rendered = try renderNodes(state, tmpl_parse.nodes, &child_ctx, depth + 1);
    try indent_mod.appendIndented(state.a, out, rendered, indent);
}

fn renderExtend(state: State, ext: N.Extend, ctx: *Context, depth: usize, out: *std.ArrayList(u8)) RenderError!void {
    var slots = try buildSlotMap(state.a, ctx, ext.defines);
    const rendered = try resolveExtendChain(state, ext.template, ctx, &slots, depth);
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
) RenderError![]const u8 {
    var visited: std.StringArrayHashMapUnmanaged(void) = .{};
    try visited.put(state.a, initial_template, {});
    var current_source = resolveTemplate(state, ctx, initial_template) orelse return error.TemplateNotFound;

    while (true) {
        const parent_parse = Parser.parse(state.a, current_source) catch return error.MalformedElement;
        if (parent_parse.nodes.len == 0) return "";
        if (parent_parse.nodes[0] != .extend) return renderExtendLeaf(state, parent_parse.nodes, ctx, slots, depth);

        const parent_ext = parent_parse.nodes[0].extend;
        if (visited.contains(parent_ext.template)) {
            setErrorDetail(ctx, parent_ext.template);
            return error.CircularReference;
        }
        try visited.put(state.a, parent_ext.template, {});
        for (parent_ext.defines) |def| {
            if (!slots.contains(def.name)) try slots.put(state.a, def.name, def.raw_source);
        }
        current_source = resolveTemplate(state, ctx, parent_ext.template) orelse return error.TemplateNotFound;
    }
}

fn renderExtendLeaf(state: State, nodes: []const Node, ctx: *Context, slots: *std.StringArrayHashMapUnmanaged([]const u8), depth: usize) RenderError![]const u8 {
    var render_ctx: Context = .{ .data = ctx.data, .attrs = ctx.attrs, .slots = slots.*, .err_detail = ctx.err_detail };
    return renderNodes(state, nodes, &render_ctx, depth);
}

fn resolveTemplate(state: State, ctx: *Context, name: []const u8) ?[]const u8 {
    if (state.resolver.get(name)) |content| return content;
    setErrorDetail(ctx, name);
    return null;
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

fn applyTransforms(a: Allocator, value: []const u8, steps: []const N.TransformStep) RenderError![]u8 {
    var current = try a.dupe(u8, value);
    for (steps) |step| {
        current = try applyOne(a, current, step.name, step.args);
    }
    return current;
}

fn applyOne(a: Allocator, value: []const u8, name: []const u8, args: []const []const u8) RenderError![]u8 {
    if (std.mem.eql(u8, name, "upper")) return upperTransform(a, value);
    if (std.mem.eql(u8, name, "lower")) return lowerTransform(a, value);
    if (std.mem.eql(u8, name, "capitalize")) return capitalizeTransform(a, value);
    if (std.mem.eql(u8, name, "trim")) return a.dupe(u8, std.mem.trim(u8, value, " \t\n\r"));
    if (std.mem.eql(u8, name, "slugify")) return slugifyTransform(a, value);
    if (std.mem.eql(u8, name, "truncate")) return truncateTransform(a, value, args);
    if (std.mem.eql(u8, name, "replace")) return replaceTransform(a, value, args);
    if (std.mem.eql(u8, name, "default")) return defaultTransform(a, value, args);
    return error.MalformedElement;
}

fn upperTransform(a: Allocator, value: []const u8) RenderError![]u8 {
    const buf = try a.alloc(u8, value.len);
    for (buf, value) |*b, c| b.* = std.ascii.toUpper(c);
    return buf;
}

fn lowerTransform(a: Allocator, value: []const u8) RenderError![]u8 {
    const buf = try a.alloc(u8, value.len);
    for (buf, value) |*b, c| b.* = std.ascii.toLower(c);
    return buf;
}

fn capitalizeTransform(a: Allocator, value: []const u8) RenderError![]u8 {
    const buf = try a.alloc(u8, value.len);
    var prev_space = true;
    for (buf, value) |*b, c| {
        b.* = if (prev_space and std.ascii.isAlphabetic(c)) std.ascii.toUpper(c) else c;
        prev_space = c == ' ' or c == '\t' or c == '\n';
    }
    return buf;
}

fn slugifyTransform(a: Allocator, value: []const u8) RenderError![]u8 {
    var result: std.ArrayList(u8) = .{};
    var prev_hyphen = true;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try result.append(a, std.ascii.toLower(c));
            prev_hyphen = false;
        } else if (!prev_hyphen) {
            try result.append(a, '-');
            prev_hyphen = true;
        }
    }
    if (result.items.len > 0 and result.items[result.items.len - 1] == '-') _ = result.pop();
    return result.toOwnedSlice(a);
}

fn truncateTransform(a: Allocator, value: []const u8, args: []const []const u8) RenderError![]u8 {
    if (args.len == 0) return error.MalformedElement;
    const n = std.fmt.parseInt(usize, args[0], 10) catch return error.MalformedElement;
    return a.dupe(u8, if (value.len <= n) value else value[0..n]);
}

fn replaceTransform(a: Allocator, value: []const u8, args: []const []const u8) RenderError![]u8 {
    if (args.len < 1) return error.MalformedElement;
    const old = args[0];
    const new = if (args.len > 1) args[1] else "";
    var result: std.ArrayList(u8) = .{};
    var i: usize = 0;
    while (i < value.len) {
        if (old.len > 0 and i + old.len <= value.len and std.mem.eql(u8, value[i .. i + old.len], old)) {
            try result.appendSlice(a, new);
            i += old.len;
        } else {
            try result.append(a, value[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(a);
}

fn defaultTransform(a: Allocator, value: []const u8, args: []const []const u8) RenderError![]u8 {
    const def = if (args.len > 0) args[0] else "";
    return a.dupe(u8, if (value.len == 0) def else value);
}

fn setErrorDetail(ctx: *Context, message: []const u8) void {
    if (ctx.err_detail) |ed| ed.message = message;
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
