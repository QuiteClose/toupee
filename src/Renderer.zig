const std = @import("std");
const Allocator = std.mem.Allocator;
const N = @import("Node.zig");
const Node = N.Node;
const Ctx = @import("Context.zig");
const Context = Ctx.Context;
const Resolver = Ctx.Resolver;
const Loader = Ctx.Loader;
const RenderError = Ctx.RenderError;
const V = @import("Value.zig");
const h = @import("html.zig");
const transform = @import("transform.zig");
const indent_mod = @import("indent.zig");
const Parser = @import("Parser.zig");
const diagnostic = @import("diagnostic.zig");

/// Configuration for rendering: max include/extend depth, template metadata for errors,
/// transform registry, strict mode, and debug flag for context dumps.
pub const Options = struct {
    max_depth: usize = 50,
    template_name: []const u8 = "<input>",
    template_source: []const u8 = "",
    registry: ?*const transform.Registry = null,
    strict: bool = true,
    debug: bool = false,
};

const State = struct {
    a: Allocator,
    loader: Loader,
    max_depth: usize,
    template_name: []const u8,
    template_source: []const u8,
    registry: ?*const transform.Registry,
    strict: bool,
    debug: bool,
    /// Error-reporting stack trace (most recent 16 frames). Intentionally smaller
    /// than max_depth: deep nesting is allowed, but error messages only need the
    /// innermost frames to be useful. Oldest frames are silently dropped.
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

/// Renders []Node IR with the given context and resolver. Main entry point for the renderer.
pub fn render(
    caller_a: Allocator,
    nodes: []const Node,
    ctx: *const Context,
    loader: Loader,
    options: Options,
) RenderError![]const u8 {
    var arena = std.heap.ArenaAllocator.init(caller_a);
    defer arena.deinit();
    const a = arena.allocator();

    var mutable_ctx = try Context.initFrom(a, ctx);

    const state = initState(a, loader, options);
    const result = try renderNodes(state, nodes, &mutable_ctx, 0);
    return try caller_a.dupe(u8, result);
}

/// Renders []Node IR, writing output to `writer` as each top-level node completes.
/// Nested rendering (includes, slots, let bindings) still buffers internally.
/// Text nodes are written directly to the writer without intermediate allocation.
pub fn renderToWriter(
    caller_a: Allocator,
    nodes: []const Node,
    ctx: *const Context,
    loader: Loader,
    options: Options,
    writer: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(caller_a);
    defer arena.deinit();
    const a = arena.allocator();

    var mutable_ctx = try Context.initFrom(a, ctx);

    const state = initState(a, loader, options);
    for (nodes) |node| {
        switch (node) {
            .text => |text| try writer.writeAll(text),
            .comment => {},
            else => {
                const single = [1]Node{node};
                const chunk = try renderNodes(state, &single, &mutable_ctx, 0);
                try writer.writeAll(chunk);
            },
        }
    }
}

fn initState(a: Allocator, loader: Loader, options: Options) State {
    return .{
        .a = a,
        .loader = loader,
        .max_depth = options.max_depth,
        .template_name = options.template_name,
        .template_source = options.template_source,
        .registry = options.registry,
        .strict = options.strict,
        .debug = options.debug,
        .include_stack_buf = [_]Ctx.IncludeEntry{.{}} ** 16,
        .include_stack_len = 0,
    };
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
            .debug => if (state.debug) try renderDebug(state, ctx, &out),
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

/// When `<t-define>` with no name replaces the default slot (`""`), the previous slot fill
/// (usually the page body) is stored under this key so inner `<t-slot />` can render it.
const default_slot_super_key = "__t_inner_body__";

fn cloneSlotMap(a: Allocator, src: std.StringArrayHashMapUnmanaged([]const u8)) Allocator.Error!std.StringArrayHashMapUnmanaged([]const u8) {
    var dest: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    var it = src.iterator();
    while (it.next()) |e| try dest.put(a, e.key_ptr.*, e.value_ptr.*);
    return dest;
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

    if (try ctx.resolveAlloc(v.name, state.a)) |resolved| {
        if (try resolved.toStringValue(state.a)) |val| {
            value = val;
        } else if (v.has_body) {
            if (v.default_body.len > 0) value = try renderNodes(state, v.default_body, ctx, depth);
        } else if (v.transform.len > 0 and hasDefaultTransform(v.transform)) {
            // default transform will provide the value
        } else if (state.strict) {
            setRichError(state, ctx, v.source_pos, .undefined_variable, v.name);
            return error.UndefinedVariable;
        }
    } else if (v.has_body) {
        if (v.default_body.len > 0) value = try renderNodes(state, v.default_body, ctx, depth);
    } else if (v.transform.len > 0 and hasDefaultTransform(v.transform)) {
        // default transform will provide the value
    } else if (state.strict) {
        setRichError(state, ctx, v.source_pos, .undefined_variable, v.name);
        return error.UndefinedVariable;
    }

    if (v.transform.len > 0) value = try applyTransforms(state, value, v.transform);
    if (escape) try h.appendEscaped(state.a, out, value) else try out.appendSlice(state.a, value);
}

fn renderLet(state: State, lb: N.LetBinding, ctx: *Context, depth: usize) RenderError!void {
    var rendered = try renderNodes(state, lb.body, ctx, depth);
    if (lb.transform.len > 0) rendered = try applyTransforms(state, rendered, lb.transform);
    try ctx.put(lb.name, .{ .string = rendered });
}

fn renderAttrOutput(state: State, ao: N.AttrOutput, ctx: *const Context, out: *std.ArrayList(u8)) RenderError!void {
    if (ctx.getAttr(ao.name)) |value| try h.appendEscaped(state.a, out, value);
}

fn renderSlot(state: State, s: N.Slot, ctx: *Context, depth: usize, out: *std.ArrayList(u8)) RenderError!void {
    const indent = try state.a.dupe(u8, indent_mod.detectIndent(out.items));
    if (ctx.getSlot(s.name)) |content| {
        const parse_result = try Parser.parse(state.a, content, .{ .err_detail = ctx.err_detail });
        var fill_ctx = try Context.initFrom(state.a, ctx);
        // Default-slot fill from anonymous `<t-define>` overwrites ""; inner `<t-slot />` must see the
        // parked body, not recurse into the wrapper again.
        if (s.name.len == 0 and ctx.hasSlot(default_slot_super_key)) {
            fill_ctx.slots = try cloneSlotMap(state.a, ctx.slots);
            if (fill_ctx.slots.get(default_slot_super_key)) |inner| {
                try fill_ctx.slots.put(state.a, "", inner);
                _ = fill_ctx.slots.swapRemove(default_slot_super_key);
            }
        }
        const rendered = try renderNodes(state, parse_result.nodes, &fill_ctx, depth);
        try indent_mod.appendIndented(state.a, out, rendered, indent);
    } else if (s.default_body.len > 0) {
        const rendered = try renderNodes(state, s.default_body, ctx, depth);
        try indent_mod.appendIndented(state.a, out, rendered, indent);
    }
}

fn renderInclude(state: State, inc: N.Include, ctx: *Context, depth: usize, out: *std.ArrayList(u8)) RenderError!void {
    const tmpl_content = try state.loader.getSource(state.a, inc.template) orelse {
        setRichError(state, ctx, inc.source_pos, .template_not_found, inc.template);
        return error.TemplateNotFound;
    };

    var child_slots: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    for (inc.defines) |def| try child_slots.put(state.a, def.name, def.raw_source);
    if (inc.anonymous_body_source.len > 0) try child_slots.put(state.a, "", inc.anonymous_body_source);

    var inc_attrs: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    for (inc.attrs) |attr| try inc_attrs.put(state.a, attr.name, attr.value);

    var child_ctx = if (inc.isolated) Context.init(state.a) else try Context.initFrom(state.a, ctx);
    for (inc.context_bindings) |binding| {
        if (try ctx.resolveAlloc(binding.path, state.a)) |val|
            try child_ctx.put(binding.key, val);
    }
    child_ctx.attrs = inc_attrs;
    child_ctx.slots = child_slots;
    child_ctx.err_detail = ctx.err_detail;

    const indent = try state.a.dupe(u8, indent_mod.detectIndent(out.items));
    const lc = h.computeLineCol(state.template_source, inc.source_pos);
    const child_state = state.pushInclude(inc.template, tmpl_content, lc.line);
    const tmpl_parse = try Parser.parse(state.a, tmpl_content, .{ .err_detail = ctx.err_detail, .template_name = inc.template });
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
    for (defines) |def| {
        if (def.name.len == 0) {
            if (slots.get("")) |prev| {
                try slots.put(a, default_slot_super_key, prev);
            }
        }
        try slots.put(a, def.name, def.raw_source);
    }
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
    var current_source = try state.loader.getSource(state.a, initial_template) orelse {
        setRichError(state, ctx, source_pos, .template_not_found, initial_template);
        return error.TemplateNotFound;
    };
    const lc = h.computeLineCol(state.template_source, source_pos);
    var current_state = state.pushInclude(initial_template, current_source, lc.line);

    while (true) {
        const parent_parse = try Parser.parse(state.a, current_source, .{ .err_detail = ctx.err_detail, .template_name = current_state.template_name });
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
        current_source = try state.loader.getSource(state.a, parent_ext.template) orelse {
            setRichError(current_state, ctx, parent_ext.source_pos, .template_not_found, parent_ext.template);
            return error.TemplateNotFound;
        };
        const ext_lc = h.computeLineCol(current_state.template_source, parent_ext.source_pos);
        current_state = current_state.pushInclude(parent_ext.template, current_source, ext_lc.line);
    }
}

fn mergeDefines(a: Allocator, slots: *std.StringArrayHashMapUnmanaged([]const u8), defines: []const N.Define) RenderError!void {
    for (defines) |def| {
        if (!slots.contains(def.name)) try slots.put(a, def.name, def.raw_source);
    }
}

fn renderExtendLeaf(state: State, nodes: []const Node, ctx: *Context, slots: *std.StringArrayHashMapUnmanaged([]const u8), depth: usize) RenderError![]const u8 {
    var render_ctx = try Context.initFrom(state.a, ctx);
    render_ctx.slots = slots.*;
    return renderNodes(state, nodes, &render_ctx, depth);
}

fn renderConditional(state: State, cond: N.Conditional, ctx: *Context, depth: usize, out: *std.ArrayList(u8)) RenderError!void {
    for (cond.branches) |branch| {
        if (try evaluateCondition(state, branch.condition, ctx)) {
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

fn evaluateCondition(state: State, cond: N.Condition, ctx: *const Context) RenderError!bool {
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
    const resolved = try ctx.resolveAlloc(cond.name, state.a);
    const val_str = if (resolved) |rv| (try rv.toStringValue(state.a)) orelse "" else "";
    return switch (cond.comparison) {
        .exists => resolved != null,
        .not_exists => resolved == null,
        .equals => |expected| if (resolved != null) std.mem.eql(u8, val_str, expected) else false,
        .not_equals => |expected| if (resolved != null) !std.mem.eql(u8, val_str, expected) else true,
        .contains => |needle| if (resolved != null) std.mem.indexOf(u8, val_str, needle) != null else false,
        .starts_with => |pfx| if (resolved != null) std.mem.startsWith(u8, val_str, pfx) else false,
        .ends_with => |sfx| if (resolved != null) std.mem.endsWith(u8, val_str, sfx) else false,
        .matches => |pattern| if (resolved != null) globMatch(val_str, pattern) else false,
    };
}

fn evalComparison(comparison: N.Condition.Comparison, value: ?[]const u8) bool {
    const v = value orelse "";
    return switch (comparison) {
        .exists => value != null,
        .not_exists => value == null,
        .equals => |expected| if (value != null) std.mem.eql(u8, v, expected) else false,
        .not_equals => |expected| if (value != null) !std.mem.eql(u8, v, expected) else true,
        .contains => |needle| if (value != null) std.mem.indexOf(u8, v, needle) != null else false,
        .starts_with => |pfx| if (value != null) std.mem.startsWith(u8, v, pfx) else false,
        .ends_with => |sfx| if (value != null) std.mem.endsWith(u8, v, sfx) else false,
        .matches => |pattern| if (value != null) globMatch(v, pattern) else false,
    };
}

fn renderLoop(state: State, loop: N.Loop, ctx: *Context, depth: usize, out: *std.ArrayList(u8)) RenderError!void {
    const resolved = (try ctx.resolveAlloc(loop.collection, state.a)) orelse {
        if (loop.else_body.len > 0) try out.appendSlice(state.a, try renderNodes(state, loop.else_body, ctx, depth));
        return;
    };
    const list = blk: {
        if (resolved.asList()) |l| break :blk l;
        if (resolved.asMap()) |m| {
            if (m.get("items")) |iv| {
                if (iv.asList()) |items| break :blk items;
            }
        }
        if (loop.else_body.len > 0) try out.appendSlice(state.a, try renderNodes(state, loop.else_body, ctx, depth));
        return;
    };
    const items = try state.a.dupe(V.Value, list);
    if (loop.sort_field) |field| sortItems(items, field, loop.order_desc);
    const final = applyLimitOffset(items, loop.limit, loop.offset);

    if (final.len == 0) {
        if (loop.else_body.len > 0) try out.appendSlice(state.a, try renderNodes(state, loop.else_body, ctx, depth));
        return;
    }

    for (final, 0..) |item, idx| {
        var child_ctx = try Context.initFrom(state.a, ctx);
        try child_ctx.put(loop.item_prefix, item);
        if (loop.alias) |alias| try putAliasMetadata(state.a, &child_ctx, alias, idx, final.len);
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


fn putAliasMetadata(a: Allocator, ctx: *Context, alias: []const u8, idx: usize, total: usize) RenderError!void {
    var alias_map: V.Map = .{};
    try alias_map.put(a, "index", .{ .string = try std.fmt.allocPrint(a, "{d}", .{idx}) });
    try alias_map.put(a, "number", .{ .string = try std.fmt.allocPrint(a, "{d}", .{idx + 1}) });
    try alias_map.put(a, "length", .{ .string = try std.fmt.allocPrint(a, "{d}", .{total}) });
    if (idx == 0) try alias_map.put(a, "first", .{ .string = "true" });
    if (idx == total - 1) try alias_map.put(a, "last", .{ .string = "true" });
    try ctx.put(alias, .{ .map = alias_map });
}

fn renderBoundTag(state: State, bt: N.BoundTag, ctx: *const Context, out: *std.ArrayList(u8)) RenderError!void {
    for (bt.segments) |segment| {
        switch (segment) {
            .literal => |text| try out.appendSlice(state.a, text),
            .binding => |b| {
                const value = if (b.is_var)
                    (if (try ctx.resolveAlloc(b.ref_name, state.a)) |rv| try rv.toStringValue(state.a) else null)
                else
                    ctx.getAttr(b.ref_name);
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

// ---- Glob matching ----

fn globMatch(text: []const u8, pattern: []const u8) bool {
    var ti: usize = 0;
    var pi: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == text[ti])) {
            ti += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}
    return pi == pattern.len;
}

// ---- Debug rendering ----

fn renderDebug(state: State, ctx: *const Context, out: *std.ArrayList(u8)) RenderError!void {
    try out.appendSlice(state.a, "<div class=\"t-debug\"><h3>Template Context</h3>");
    try out.appendSlice(state.a, "<table><thead><tr><th>Variable</th><th>Value</th></tr></thead><tbody>");
    var it = ctx.data.iterator();
    while (it.next()) |entry| {
        try out.appendSlice(state.a, "<tr><td><code>");
        try h.appendEscaped(state.a, out, entry.key_ptr.*);
        try out.appendSlice(state.a, "</code></td><td><code>");
        try appendValueDebug(state.a, out, entry.value_ptr.*);
        try out.appendSlice(state.a, "</code></td></tr>");
    }
    try out.appendSlice(state.a, "</tbody></table></div>");
}

fn appendValueDebug(a: Allocator, out: *std.ArrayList(u8), value: V.Value) RenderError!void {
    switch (value) {
        .nil => try out.appendSlice(a, "nil"),
        .string => |s| try h.appendEscaped(a, out, s),
        .boolean => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .integer => |i| {
            const s = try std.fmt.allocPrint(a, "{d}", .{i});
            try out.appendSlice(a, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(a, "{d}", .{f});
            try out.appendSlice(a, s);
        },
        .list => |items| {
            try out.appendSlice(a, "[");
            for (items, 0..) |item, idx| {
                if (idx > 0) try out.appendSlice(a, ", ");
                try appendValueDebug(a, out, item);
            }
            try out.appendSlice(a, "]");
        },
        .map => |m| {
            try out.appendSlice(a, "{");
            var mit = m.iterator();
            var first = true;
            while (mit.next()) |entry| {
                if (!first) try out.appendSlice(a, ", ");
                first = false;
                try h.appendEscaped(a, out, entry.key_ptr.*);
                try out.appendSlice(a, ": ");
                try appendValueDebug(a, out, entry.value_ptr.*);
            }
            try out.appendSlice(a, "}");
        },
    }
}

// ---- Error helpers ----


fn setRichError(state: State, ctx: *Context, pos: usize, kind: Ctx.ErrorDetail.Kind, name: []const u8) void {
    diagnostic.setError(ctx.err_detail, state.template_source, pos, kind, name, state.template_name);
    if (ctx.err_detail) |ed| {
        ed.include_stack_len = state.include_stack_len;
        ed.include_stack_buf = state.include_stack_buf;
        if (kind == .undefined_variable) ed.suggestion = ed.store(findSuggestion(name, ctx));
    }
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
        const d = diagnostic.levenshtein(name, entry.key_ptr.*);
        if (d > 0 and d < best_dist) {
            best_dist = d;
            best = entry.key_ptr.*;
        }
    }
    return best;
}

// ---- Tests ----

const testing = std.testing;

test "render plain text" {
    const nodes = [_]Node{.{ .text = "hello" }};
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "render variable" {
    const nodes = [_]Node{.{ .variable = .{ .name = "title" } }};
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("title", .{ .string = "Hello" });
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello", result);
}

test "render variable escapes html" {
    const nodes = [_]Node{.{ .variable = .{ .name = "v" } }};
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("v", .{ .string = "<b>bold</b>" });
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("&lt;b&gt;bold&lt;/b&gt;", result);
}

test "render raw variable" {
    const nodes = [_]Node{.{ .raw_variable = .{ .name = "v" } }};
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("v", .{ .string = "<b>bold</b>" });
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("<b>bold</b>", result);
}

test "render undefined variable is error" {
    const nodes = [_]Node{.{ .variable = .{ .name = "missing" } }};
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const result = render(testing.allocator, &nodes, &ctx, resolver.loader(), .{});
    try testing.expectError(error.UndefinedVariable, result);
}

test "render variable with default body" {
    const default_body = [_]Node{.{ .text = "Fallback" }};
    const nodes = [_]Node{.{ .variable = .{ .name = "missing", .default_body = &default_body, .has_body = true } }};
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{});
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
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("show", .{ .string = "1" });
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{});
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
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{});
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
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("url", .{ .string = "/home" });
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("<a href=\"/home\">", result);
}

test "render comment produces no output" {
    const nodes = [_]Node{ .{ .text = "a" }, .comment, .{ .text = "b" } };
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("ab", result);
}

test "computeLineCol single line" {
    const lc = h.computeLineCol("hello world", 6);
    try testing.expectEqual(@as(usize, 1), lc.line);
    try testing.expectEqual(@as(usize, 7), lc.column);
}

test "computeLineCol multi line" {
    const lc = h.computeLineCol("abc\ndef\nghi", 8);
    try testing.expectEqual(@as(usize, 3), lc.line);
    try testing.expectEqual(@as(usize, 1), lc.column);
}

test "computeLineCol empty source" {
    const lc = h.computeLineCol("", 0);
    try testing.expectEqual(@as(usize, 1), lc.line);
    try testing.expectEqual(@as(usize, 1), lc.column);
}

test "strict false allows missing variables" {
    const nodes = [_]Node{
        .{ .text = "[" },
        .{ .variable = .{ .name = "missing" } },
        .{ .text = "]" },
    };
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{ .strict = false });
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("[]", result);
}

test "strict true errors on missing variables" {
    const nodes = [_]Node{.{ .variable = .{ .name = "missing" } }};
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const result = render(testing.allocator, &nodes, &ctx, resolver.loader(), .{ .strict = true });
    try testing.expectError(error.UndefinedVariable, result);
}

test "debug element renders context dump" {
    const nodes = [_]Node{.debug};
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("title", .{ .string = "Hello" });
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{ .debug = true });
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "t-debug") != null);
    try testing.expect(std.mem.indexOf(u8, result, "title") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Hello") != null);
}

test "debug element stripped when debug is false" {
    const nodes = [_]Node{ .{ .text = "a" }, .debug, .{ .text = "b" } };
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{ .debug = false });
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("ab", result);
}

test "glob match basic patterns" {
    try testing.expect(globMatch("hello", "hello"));
    try testing.expect(globMatch("hello", "*"));
    try testing.expect(globMatch("hello", "h*o"));
    try testing.expect(globMatch("hello", "h?llo"));
    try testing.expect(!globMatch("hello", "world"));
    try testing.expect(!globMatch("hello", "h?lo"));
    try testing.expect(globMatch("/blog/post-1", "/blog/*"));
    try testing.expect(!globMatch("/about", "/blog/*"));
    try testing.expect(globMatch("v2.0", "v?.0"));
    try testing.expect(!globMatch("v12.0", "v?.0"));
}

test "for-else renders else body on empty list" {
    const body = [_]Node{.{ .text = "item" }};
    const else_body = [_]Node{.{ .text = "empty" }};
    const nodes = [_]Node{.{ .loop = .{
        .item_prefix = "item",
        .collection = "items",
        .body = &body,
        .else_body = &else_body,
    } }};
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("items", .{ .list = &.{} });
    var resolver: Resolver = .{};
    const result = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("empty", result);
}

test "rich error populates ErrorDetail" {
    const source = "<t-var name=\"titl\" />";
    const nodes = [_]Node{.{ .variable = .{ .name = "titl", .source_pos = 0 } }};
    var ed: Ctx.ErrorDetail = .{};
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.err_detail = &ed;
    try ctx.put("title", .{ .string = "Hello" });
    var resolver: Resolver = .{};
    const result = render(testing.allocator, &nodes, &ctx, resolver.loader(), .{
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

test "renderToWriter matches render for text" {
    const nodes = [_]Node{.{ .text = "hello" }};
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const buffered = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{});
    defer testing.allocator.free(buffered);
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);
    try renderToWriter(testing.allocator, &nodes, &ctx, resolver.loader(), .{}, out.writer(testing.allocator));
    try testing.expectEqualStrings(buffered, out.items);
}

test "renderToWriter matches render for mixed nodes" {
    const default_body = [_]Node{.{ .text = "default" }};
    const body = [_]Node{.{ .text = "yes" }};
    const branches = [_]N.Branch{.{
        .condition = .{ .source = .variable, .name = "show" },
        .body = &body,
    }};
    const nodes = [_]Node{
        .{ .text = "<p>" },
        .{ .variable = .{ .name = "title" } },
        .{ .text = "</p>" },
        .comment,
        .{ .conditional = .{ .branches = &branches } },
        .{ .variable = .{ .name = "missing", .default_body = &default_body, .has_body = true } },
    };
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("title", .{ .string = "Hello" });
    try ctx.put("show", .{ .string = "1" });
    var resolver: Resolver = .{};

    const buffered = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{});
    defer testing.allocator.free(buffered);
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);
    try renderToWriter(testing.allocator, &nodes, &ctx, resolver.loader(), .{}, out.writer(testing.allocator));
    try testing.expectEqualStrings(buffered, out.items);
}

test "renderToWriter matches render with let binding" {
    const let_body = [_]Node{.{ .text = "captured" }};
    const nodes = [_]Node{
        .{ .let_binding = .{ .name = "x", .body = &let_body } },
        .{ .variable = .{ .name = "x" } },
    };
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};

    const buffered = try render(testing.allocator, &nodes, &ctx, resolver.loader(), .{});
    defer testing.allocator.free(buffered);
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);
    try renderToWriter(testing.allocator, &nodes, &ctx, resolver.loader(), .{}, out.writer(testing.allocator));
    try testing.expectEqualStrings(buffered, out.items);
}

// Regression: newline after `<t-slot />` is a separate text node; slot fill ending in `\n` plus
// `appendIndented` adds an extra blank line before the next markup. Parser should consume the
// newline with the slot tag; until then this test fails.
//
// Input (1) layout template source, (2) default slot fill (host body HTML):
//   template: "<body>\\n  <t-slot />\\n</body>"  — newline after `/>`, `</body>` flush with `<body>`
//   slot "":  "<section>x</section>\\n"         — trailing newline like Djot/Markdown output
test "no extra blank line: newline after t-slot plus slot fill ending with newline" {
    const template =
        \\<body>
        \\  <t-slot />
        \\</body>
    ;
    var parse_result = try Parser.parse(testing.allocator, template, .{});
    defer parse_result.deinit();

    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.setSlot("", "<section>x</section>\n");

    var resolver: Resolver = .{};
    const result = try render(testing.allocator, parse_result.nodes, &ctx, resolver.loader(), .{});
    defer testing.allocator.free(result);

    const expected =
        \\<body>
        \\  <section>x</section>
        \\</body>
    ;
    try testing.expectEqualStrings(expected, result);
}

test "rich error with include stack" {
    const child_source = "<t-var name=\"missing\" />";
    const parent_source = "<t-include template=\"child.html\" />";
    var ed: Ctx.ErrorDetail = .{};
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.err_detail = &ed;
    var resolver: Resolver = .{};
    try resolver.put(testing.allocator, "child.html", child_source);
    defer resolver.deinit(testing.allocator);
    const parent_nodes = [_]Node{.{ .include = .{ .template = "child.html", .source_pos = 0 } }};
    const result = render(testing.allocator, &parent_nodes, &ctx, resolver.loader(), .{
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
