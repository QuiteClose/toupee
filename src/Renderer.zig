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

const max_depth = 50;

pub fn render(a: Allocator, nodes: []const Node, ctx: *const Context, resolver: *const Resolver) RenderError![]const u8 {
    var owned_data: V.Map = .{};
    defer owned_data.deinit(a);
    var it = ctx.data.iterator();
    while (it.next()) |kv| try owned_data.put(a, kv.key_ptr.*, kv.value_ptr.*);

    var mutable_ctx: Context = .{
        .data = owned_data,
        .attrs = ctx.attrs,
        .slots = ctx.slots,
        .err_detail = ctx.err_detail,
    };
    const result = try renderNodes(a, nodes, &mutable_ctx, resolver, 0);
    owned_data = mutable_ctx.data;
    return result;
}

fn renderNodes(a: Allocator, nodes: []const Node, ctx: *Context, resolver: *const Resolver, depth: usize) RenderError![]const u8 {
    if (depth > max_depth) return error.CircularReference;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(a);

    var let_allocs: std.ArrayList([]const u8) = .{};
    defer {
        for (let_allocs.items) |s| a.free(s);
        let_allocs.deinit(a);
    }

    for (nodes) |node| {
        switch (node) {
            .text => |text| try out.appendSlice(a, text),
            .variable => |v| try renderVariable(a, v, ctx, resolver, depth, &out, true),
            .raw_variable => |v| try renderVariable(a, v, ctx, resolver, depth, &out, false),
            .let_binding => |lb| try renderLet(a, lb, ctx, resolver, depth, &let_allocs),
            .comment => {},
            .attr_output => |ao| try renderAttrOutput(a, ao, ctx, &out),
            .slot => |s| try renderSlot(a, s, ctx, resolver, depth, &out),
            .include => |inc| try renderInclude(a, inc, ctx, resolver, depth, &out),
            .extend => |ext| try renderExtend(a, ext, ctx, resolver, depth, &out),
            .conditional => |cond| try renderConditional(a, cond, ctx, resolver, depth, &out),
            .loop => |loop| try renderLoop(a, loop, ctx, resolver, depth, &out),
            .bound_tag => |bt| try renderBoundTag(a, bt, ctx, &out),
        }
    }

    return out.toOwnedSlice(a);
}

fn renderVariable(
    a: Allocator,
    v: N.Variable,
    ctx: *Context,
    resolver: *const Resolver,
    depth: usize,
    out: *std.ArrayList(u8),
    escape: bool,
) RenderError!void {
    var value: []const u8 = "";
    var value_allocated = false;

    if (ctx.resolveString(v.name)) |val| {
        value = val;
    } else if (v.has_body) {
        if (v.default_body.len > 0) {
            value = try renderNodes(a, v.default_body, ctx, resolver, depth);
            value_allocated = true;
        }
    } else if (v.transform.len > 0 and hasDefaultTransform(v.transform)) {
        // default transform will provide the value
    } else {
        setErrorDetail(ctx, v.name);
        return error.UndefinedVariable;
    }
    defer if (value_allocated) a.free(value);

    if (v.transform.len > 0) {
        const transformed = try applyTransforms(a, value, v.transform);
        defer a.free(transformed);
        if (escape) try h.appendEscaped(a, out, transformed) else try out.appendSlice(a, transformed);
    } else if (value_allocated) {
        try out.appendSlice(a, value);
    } else if (escape) {
        try h.appendEscaped(a, out, value);
    } else {
        try out.appendSlice(a, value);
    }
}

fn renderLet(
    a: Allocator,
    lb: N.LetBinding,
    ctx: *Context,
    resolver: *const Resolver,
    depth: usize,
    let_allocs: *std.ArrayList([]const u8),
) RenderError!void {
    const rendered = try renderNodes(a, lb.body, ctx, resolver, depth);
    if (lb.transform.len > 0) {
        const transformed = try applyTransforms(a, rendered, lb.transform);
        a.free(rendered);
        try let_allocs.append(a, transformed);
        try ctx.putData(a, lb.name, .{ .string = transformed });
    } else {
        try let_allocs.append(a, rendered);
        try ctx.putData(a, lb.name, .{ .string = rendered });
    }
}

fn renderAttrOutput(a: Allocator, ao: N.AttrOutput, ctx: *const Context, out: *std.ArrayList(u8)) RenderError!void {
    if (ctx.getAttr(ao.name)) |value| try h.appendEscaped(a, out, value);
}

fn renderSlot(
    a: Allocator,
    s: N.Slot,
    ctx: *Context,
    resolver: *const Resolver,
    depth: usize,
    out: *std.ArrayList(u8),
) RenderError!void {
    const indent = try a.dupe(u8, indent_mod.detectIndent(out.items));
    defer a.free(indent);

    if (ctx.getSlot(s.name)) |content| {
        const parse_result = Parser.parse(a, content) catch return error.MalformedElement;
        const rendered = try renderNodes(a, parse_result.nodes, ctx, resolver, depth);
        defer a.free(rendered);
        try indent_mod.appendIndented(a, out, rendered, indent);
    } else if (s.default_body.len > 0) {
        const rendered = try renderNodes(a, s.default_body, ctx, resolver, depth);
        defer a.free(rendered);
        try indent_mod.appendIndented(a, out, rendered, indent);
    }
}

fn renderInclude(
    a: Allocator,
    inc: N.Include,
    ctx: *Context,
    resolver: *const Resolver,
    depth: usize,
    out: *std.ArrayList(u8),
) RenderError!void {
    const tmpl_content = resolver.get(inc.template) orelse {
        setErrorDetail(ctx, inc.template);
        return error.TemplateNotFound;
    };

    var child_slots: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    defer child_slots.deinit(a);

    for (inc.defines) |def| {
        try child_slots.put(a, def.name, def.raw_source);
    }
    if (inc.anonymous_body_source.len > 0) {
        try child_slots.put(a, "", inc.anonymous_body_source);
    }

    var inc_attrs: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    defer inc_attrs.deinit(a);
    for (inc.attrs) |attr| try inc_attrs.put(a, attr.name, attr.value);

    var child_ctx: Context = .{
        .data = ctx.data,
        .attrs = inc_attrs,
        .slots = child_slots,
        .err_detail = ctx.err_detail,
    };

    const indent = try a.dupe(u8, indent_mod.detectIndent(out.items));
    defer a.free(indent);

    const tmpl_parse = Parser.parse(a, tmpl_content) catch return error.MalformedElement;
    const rendered = try renderNodes(a, tmpl_parse.nodes, &child_ctx, resolver, depth + 1);
    defer a.free(rendered);
    try indent_mod.appendIndented(a, out, rendered, indent);
}

fn renderExtend(
    a: Allocator,
    ext: N.Extend,
    ctx: *Context,
    resolver: *const Resolver,
    depth: usize,
    out: *std.ArrayList(u8),
) RenderError!void {
    var slots: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    defer slots.deinit(a);

    var sit = ctx.slots.iterator();
    while (sit.next()) |entry| try slots.put(a, entry.key_ptr.*, entry.value_ptr.*);

    for (ext.defines) |def| {
        try slots.put(a, def.name, def.raw_source);
    }

    var visited: std.StringArrayHashMapUnmanaged(void) = .{};
    defer visited.deinit(a);
    try visited.put(a, ext.template, {});

    var current_name = ext.template;
    var current_source = resolver.get(current_name) orelse {
        setErrorDetail(ctx, current_name);
        return error.TemplateNotFound;
    };

    while (true) {
        const parent_parse = Parser.parse(a, current_source) catch return error.MalformedElement;
        if (parent_parse.nodes.len == 0) break;

        if (parent_parse.nodes[0] != .extend) {
            var render_ctx: Context = .{
                .data = ctx.data,
                .attrs = ctx.attrs,
                .slots = slots,
                .err_detail = ctx.err_detail,
            };
            const rendered = try renderNodes(a, parent_parse.nodes, &render_ctx, resolver, depth);
            defer a.free(rendered);
            try out.appendSlice(a, rendered);
            return;
        }

        const parent_ext = parent_parse.nodes[0].extend;
        if (visited.contains(parent_ext.template)) {
            setErrorDetail(ctx, parent_ext.template);
            return error.CircularReference;
        }
        try visited.put(a, parent_ext.template, {});

        for (parent_ext.defines) |def| {
            if (!slots.contains(def.name)) {
                try slots.put(a, def.name, def.raw_source);
            }
        }

        current_name = parent_ext.template;
        current_source = resolver.get(current_name) orelse {
            setErrorDetail(ctx, current_name);
            return error.TemplateNotFound;
        };
    }
}

fn renderConditional(
    a: Allocator,
    cond: N.Conditional,
    ctx: *Context,
    resolver: *const Resolver,
    depth: usize,
    out: *std.ArrayList(u8),
) RenderError!void {
    for (cond.branches) |branch| {
        if (evaluateCondition(branch.condition, ctx)) {
            const rendered = try renderNodes(a, branch.body, ctx, resolver, depth);
            defer a.free(rendered);
            try out.appendSlice(a, rendered);
            return;
        }
    }
    if (cond.else_body.len > 0) {
        const rendered = try renderNodes(a, cond.else_body, ctx, resolver, depth);
        defer a.free(rendered);
        try out.appendSlice(a, rendered);
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

fn renderLoop(
    a: Allocator,
    loop: N.Loop,
    ctx: *Context,
    resolver: *const Resolver,
    depth: usize,
    out: *std.ArrayList(u8),
) RenderError!void {
    const resolved = ctx.resolve(loop.collection) orelse return;
    const list = resolved.asList() orelse return;

    const items = try a.dupe(V.Value, list);
    defer a.free(items);

    if (loop.sort_field) |field| {
        const Sort = struct {
            field_name: []const u8,
            descending: bool,

            pub fn lessThan(self: @This(), lhs: V.Value, rhs: V.Value) bool {
                const a_val = if (lhs.resolve(self.field_name)) |v| v.asString() orelse "" else "";
                const b_val = if (rhs.resolve(self.field_name)) |v| v.asString() orelse "" else "";
                const cmp = std.mem.order(u8, a_val, b_val);
                if (self.descending) return cmp == .gt;
                return cmp == .lt;
            }
        };
        std.mem.sort(V.Value, items, Sort{ .field_name = field, .descending = loop.order_desc }, Sort.lessThan);
    }

    const off = if (loop.offset) |o| @min(o, items.len) else 0;
    const sliced = items[off..];
    const final = if (loop.limit) |l| sliced[0..@min(l, sliced.len)] else sliced;

    for (final, 0..) |item, idx| {
        var child_data: V.Map = .{};
        defer child_data.deinit(a);
        var dit = ctx.data.iterator();
        while (dit.next()) |kv| try child_data.put(a, kv.key_ptr.*, kv.value_ptr.*);

        try child_data.put(a, loop.item_prefix, item);

        var allocs: std.ArrayList([]const u8) = .{};
        defer {
            for (allocs.items) |s| a.free(s);
            allocs.deinit(a);
        }

        if (loop.alias) |alias| {
            var alias_map: V.Map = .{};
            const idx_str = try std.fmt.allocPrint(a, "{d}", .{idx});
            try allocs.append(a, idx_str);
            const num_str = try std.fmt.allocPrint(a, "{d}", .{idx + 1});
            try allocs.append(a, num_str);
            try alias_map.put(a, "index", .{ .string = idx_str });
            try alias_map.put(a, "number", .{ .string = num_str });
            try child_data.put(a, alias, .{ .map = alias_map });
        }

        var child_ctx: Context = .{
            .data = child_data,
            .attrs = ctx.attrs,
            .slots = ctx.slots,
            .err_detail = ctx.err_detail,
        };

        const rendered = try renderNodes(a, loop.body, &child_ctx, resolver, depth + 1);
        defer a.free(rendered);
        try out.appendSlice(a, rendered);
    }
}

fn renderBoundTag(a: Allocator, bt: N.BoundTag, ctx: *const Context, out: *std.ArrayList(u8)) RenderError!void {
    for (bt.segments) |segment| {
        switch (segment) {
            .literal => |text| try out.appendSlice(a, text),
            .binding => |b| {
                const value = if (b.is_var) ctx.resolveString(b.ref_name) else ctx.getAttr(b.ref_name);
                if (value) |v| {
                    try out.append(a, ' ');
                    try out.appendSlice(a, b.html_attr);
                    try out.appendSlice(a, "=\"");
                    try h.appendEscaped(a, out, v);
                    try out.append(a, '"');
                }
            },
        }
    }
}

fn hasDefaultTransform(steps: []const N.TransformStep) bool {
    for (steps) |step| {
        if (std.mem.eql(u8, step.name, "default")) return true;
    }
    return false;
}

fn applyTransforms(a: Allocator, value: []const u8, steps: []const N.TransformStep) RenderError![]u8 {
    var current = try a.dupe(u8, value);
    errdefer a.free(current);

    for (steps) |step| {
        const next = try applyOne(a, current, step.name, step.args);
        if (next.ptr != current.ptr) a.free(current);
        current = next;
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
    errdefer result.deinit(a);
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
    errdefer result.deinit(a);
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
    const result = try render(testing.allocator, &nodes, &ctx, &resolver);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "render variable" {
    const nodes = [_]Node{.{ .variable = .{ .name = "title" } }};
    var ctx: Context = .{};
    try ctx.putData(testing.allocator, "title", .{ .string = "Hello" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, &resolver);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello", result);
}

test "render variable escapes html" {
    const nodes = [_]Node{.{ .variable = .{ .name = "v" } }};
    var ctx: Context = .{};
    try ctx.putData(testing.allocator, "v", .{ .string = "<b>bold</b>" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, &resolver);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("&lt;b&gt;bold&lt;/b&gt;", result);
}

test "render raw variable" {
    const nodes = [_]Node{.{ .raw_variable = .{ .name = "v" } }};
    var ctx: Context = .{};
    try ctx.putData(testing.allocator, "v", .{ .string = "<b>bold</b>" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, &resolver);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("<b>bold</b>", result);
}

test "render undefined variable is error" {
    const nodes = [_]Node{.{ .variable = .{ .name = "missing" } }};
    var ctx: Context = .{};
    var resolver: Resolver = .{};
    const result = render(testing.allocator, &nodes, &ctx, &resolver);
    try testing.expectError(error.UndefinedVariable, result);
}

test "render variable with default body" {
    const default_body = [_]Node{.{ .text = "Fallback" }};
    const nodes = [_]Node{.{ .variable = .{ .name = "missing", .default_body = &default_body, .has_body = true } }};
    var ctx: Context = .{};
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, &resolver);
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
    const result = try render(testing.allocator, &nodes, &ctx, &resolver);
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
    const result = try render(testing.allocator, &nodes, &ctx, &resolver);
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
    const result = try render(testing.allocator, &nodes, &ctx, &resolver);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("<a href=\"/home\">", result);
}

test "render comment produces no output" {
    const nodes = [_]Node{ .{ .text = "a" }, .comment, .{ .text = "b" } };
    var ctx: Context = .{};
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, &resolver);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("ab", result);
}
