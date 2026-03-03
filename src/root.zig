const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Context = @import("Context.zig").Context;
pub const Value = @import("Context.zig").Value;
pub const Resolver = @import("Context.zig").Resolver;
pub const ErrorDetail = @import("Context.zig").ErrorDetail;
pub const IncludeEntry = @import("Context.zig").IncludeEntry;
pub const RenderError = @import("Context.zig").RenderError;
pub const Options = @import("Renderer.zig").Options;

pub const RenderResult = struct {
    output: []const u8,
    allocator: Allocator,

    pub fn deinit(self: RenderResult) void {
        self.allocator.free(self.output);
    }
};

pub const Node = @import("Node.zig");
pub const Parser = @import("Parser.zig");
pub const Renderer = @import("Renderer.zig");

const format = @import("format.zig");
pub const transform = @import("transform.zig");

pub const Engine = struct {
    allocator: Allocator,
    registry: transform.Registry,
    cache: std.StringArrayHashMapUnmanaged(CacheEntry) = .{},

    const CacheEntry = struct {
        nodes: []const Node.Node,
        source: []const u8,
        arena: std.heap.ArenaAllocator,
    };

    pub fn init(a: Allocator) !Engine {
        var reg: transform.Registry = .{};
        try reg.registerBuiltins(a);
        return .{ .allocator = a, .registry = reg };
    }

    pub fn deinit(self: *Engine) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.source);
            entry.value_ptr.arena.deinit();
        }
        self.cache.deinit(self.allocator);
        self.registry.deinit(self.allocator);
    }

    pub fn registerTransform(self: *Engine, name: []const u8, func: transform.TransformFn) !void {
        try self.registry.register(self.allocator, name, func);
    }

    pub fn addTemplate(self: *Engine, name: []const u8, source: []const u8) !void {
        const duped = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(duped);
        var result = try Parser.parse(self.allocator, duped);
        errdefer result.deinit();
        const gop = try self.cache.getOrPut(self.allocator, name);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.source);
            gop.value_ptr.arena.deinit();
        }
        gop.value_ptr.* = .{ .nodes = result.nodes, .source = duped, .arena = result.arena };
    }

    pub fn renderTemplate(self: *const Engine, a: Allocator, name: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options) RenderError![]const u8 {
        const entry = self.cache.get(name) orelse return error.TemplateNotFound;
        var opts = options;
        opts.registry = &self.registry;
        opts.template_name = name;
        opts.template_source = entry.source;
        return Renderer.render(a, entry.nodes, ctx, resolver, opts);
    }

    pub fn render(self: *const Engine, a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options) RenderError![]const u8 {
        var opts = options;
        opts.registry = &self.registry;
        return renderImpl(a, input, ctx, resolver, opts);
    }

    pub fn renderOwned(self: *const Engine, a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options) RenderError!RenderResult {
        return .{ .output = try self.render(a, input, ctx, resolver, options), .allocator = a };
    }

    pub fn renderTemplateOwned(self: *const Engine, a: Allocator, name: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options) RenderError!RenderResult {
        return .{ .output = try self.renderTemplate(a, name, ctx, resolver, options), .allocator = a };
    }

    pub fn renderFormatted(self: *const Engine, a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options) (RenderError || error{OutOfMemory})![]const u8 {
        const raw = try self.render(a, input, ctx, resolver, options);
        defer a.free(raw);
        return format.prettyPrint(a, raw);
    }
};

pub fn render(a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options) RenderError![]const u8 {
    if (options.registry != null) return renderImpl(a, input, ctx, resolver, options);
    var reg: transform.Registry = .{};
    try reg.registerBuiltins(a);
    defer reg.deinit(a);
    var opts = options;
    opts.registry = &reg;
    return renderImpl(a, input, ctx, resolver, opts);
}

pub fn renderFormatted(a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options) (RenderError || error{OutOfMemory})![]const u8 {
    const raw = try render(a, input, ctx, resolver, options);
    defer a.free(raw);
    return format.prettyPrint(a, raw);
}

fn renderImpl(a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options) RenderError![]const u8 {
    var parse_result = try Parser.parse(a, input);
    defer parse_result.deinit();
    var opts = options;
    if (opts.template_source.len == 0) opts.template_source = input;
    return Renderer.render(a, parse_result.nodes, ctx, resolver, opts);
}

// ---- Tests ----

const testing = std.testing;

test "engine render raw source" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    var ctx: Context = .{};
    try ctx.putData(testing.allocator, "name", .{ .string = "world" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};
    const result = try engine.render(testing.allocator, "Hello <t-var name=\"name\" />!", &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello world!", result);
}

test "engine addTemplate and renderTemplate" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("greeting.html", "Hello <t-var name=\"name\" />!");

    var ctx1: Context = .{};
    try ctx1.putData(testing.allocator, "name", .{ .string = "Alice" });
    defer ctx1.data.deinit(testing.allocator);
    var resolver: Resolver = .{};
    const r1 = try engine.renderTemplate(testing.allocator, "greeting.html", &ctx1, &resolver, .{});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("Hello Alice!", r1);

    var ctx2: Context = .{};
    try ctx2.putData(testing.allocator, "name", .{ .string = "Bob" });
    defer ctx2.data.deinit(testing.allocator);
    const r2 = try engine.renderTemplate(testing.allocator, "greeting.html", &ctx2, &resolver, .{});
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("Hello Bob!", r2);
}

test "engine renderTemplate not found" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    var ctx: Context = .{};
    var resolver: Resolver = .{};
    const result = engine.renderTemplate(testing.allocator, "missing.html", &ctx, &resolver, .{});
    try testing.expectError(error.TemplateNotFound, result);
}

test "engine custom transform via registry" {
    const reverse = struct {
        fn call(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
            const buf = try a.alloc(u8, value.len);
            for (buf, 0..) |*b, i| b.* = value[value.len - 1 - i];
            return buf;
        }
    }.call;

    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.registerTransform("reverse", reverse);
    var ctx: Context = .{};
    try ctx.putData(testing.allocator, "msg", .{ .string = "abc" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};
    const result = try engine.render(testing.allocator, "<t-var name=\"msg\" transform=\"reverse\" />", &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("cba", result);
}

test "engine renderOwned returns RenderResult" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    var ctx: Context = .{};
    try ctx.putData(testing.allocator, "x", .{ .string = "42" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};
    const result = try engine.renderOwned(testing.allocator, "<t-var name=\"x\" />", &ctx, &resolver, .{});
    defer result.deinit();
    try testing.expectEqualStrings("42", result.output);
}

test "engine addTemplate replaces existing" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("page.html", "v1");
    try engine.addTemplate("page.html", "v2");
    var ctx: Context = .{};
    var resolver: Resolver = .{};
    const result = try engine.renderTemplate(testing.allocator, "page.html", &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("v2", result);
}

test {
    _ = @import("test_runner.zig");
    _ = @import("indent.zig");
    _ = @import("format.zig");
    _ = @import("Node.zig");
    _ = @import("Parser.zig");
    _ = @import("Renderer.zig");
    _ = @import("Value.zig");
    _ = @import("transform.zig");
}
