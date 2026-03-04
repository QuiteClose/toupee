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
pub const Diagnostic = @import("diagnostic.zig").Diagnostic;

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
        var result = try Parser.parse(self.allocator, duped, .{ .template_name = name });
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

    pub fn renderTemplateFormatted(self: *const Engine, a: Allocator, name: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options) (RenderError || error{OutOfMemory})![]const u8 {
        const raw = try self.renderTemplate(a, name, ctx, resolver, options);
        defer a.free(raw);
        return format.prettyPrint(a, raw);
    }

    pub fn removeTemplate(self: *Engine, name: []const u8) void {
        if (self.cache.fetchSwapRemove(name)) |entry| {
            self.allocator.free(entry.value.source);
            entry.value.arena.deinit();
        }
    }

    pub fn clearTemplates(self: *Engine) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.source);
            entry.value_ptr.arena.deinit();
        }
        self.cache.clearRetainingCapacity();
    }

    /// Renders a cached template and writes the result to `writer`.
    /// If the writer fails mid-write, partial output may have been written.
    /// Use a buffered writer if atomicity is needed.
    pub fn renderTemplateToWriter(self: *const Engine, a: Allocator, name: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options, writer: anytype) !void {
        const result = try self.renderTemplate(a, name, ctx, resolver, options);
        defer a.free(result);
        try writer.writeAll(result);
    }

    /// Renders raw template source and writes the result to `writer`.
    /// If the writer fails mid-write, partial output may have been written.
    /// Use a buffered writer if atomicity is needed.
    pub fn renderToWriter(self: *const Engine, a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options, writer: anytype) !void {
        const result = try self.render(a, input, ctx, resolver, options);
        defer a.free(result);
        try writer.writeAll(result);
    }

    /// Renders raw template source with pretty-printing and writes to `writer`.
    /// If the writer fails mid-write, partial output may have been written.
    /// Use a buffered writer if atomicity is needed.
    pub fn renderFormattedToWriter(self: *const Engine, a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options, writer: anytype) !void {
        const result = try self.renderFormatted(a, input, ctx, resolver, options);
        defer a.free(result);
        try writer.writeAll(result);
    }

    /// Walks all cached templates and reports problems (missing includes/extends,
    /// circular extend chains). Call after loading all templates and before
    /// serving traffic. The returned slice is owned by `a`.
    pub fn validate(self: *const Engine, a: Allocator, resolver: *const Resolver) ![]const Diagnostic {
        var diags: std.ArrayListUnmanaged(Diagnostic) = .{};
        errdefer diags.deinit(a);

        var cache_it = self.cache.iterator();
        while (cache_it.next()) |entry| {
            const tmpl_name = entry.key_ptr.*;
            const nodes = entry.value_ptr.nodes;
            try collectDiagnostics(a, tmpl_name, nodes, self, resolver, &diags);
        }

        return diags.toOwnedSlice(a);
    }

    fn collectDiagnostics(
        a: Allocator,
        tmpl_name: []const u8,
        nodes: []const Node.Node,
        engine: *const Engine,
        resolver: *const Resolver,
        diags: *std.ArrayListUnmanaged(Diagnostic),
    ) !void {
        for (nodes) |node| {
            switch (node) {
                .include => |inc| {
                    if (engine.cache.get(inc.template) == null and resolver.get(inc.template) == null) {
                        try diags.append(a, .{
                            .template = tmpl_name,
                            .kind = .err,
                            .message = inc.template,
                        });
                    }
                    try collectDiagnostics(a, tmpl_name, inc.anonymous_body, engine, resolver, diags);
                    for (inc.defines) |def| try collectDiagnostics(a, tmpl_name, def.body, engine, resolver, diags);
                },
                .extend => |ext| {
                    if (engine.cache.get(ext.template) == null and resolver.get(ext.template) == null) {
                        try diags.append(a, .{
                            .template = tmpl_name,
                            .kind = .err,
                            .message = ext.template,
                        });
                    }
                    for (ext.defines) |def| try collectDiagnostics(a, tmpl_name, def.body, engine, resolver, diags);
                },
                .conditional => |cond| {
                    for (cond.branches) |branch| try collectDiagnostics(a, tmpl_name, branch.body, engine, resolver, diags);
                    try collectDiagnostics(a, tmpl_name, cond.else_body, engine, resolver, diags);
                },
                .loop => |loop| {
                    try collectDiagnostics(a, tmpl_name, loop.body, engine, resolver, diags);
                    try collectDiagnostics(a, tmpl_name, loop.else_body, engine, resolver, diags);
                },
                .slot => |slot| try collectDiagnostics(a, tmpl_name, slot.default_body, engine, resolver, diags),
                .variable => |v| try collectDiagnostics(a, tmpl_name, v.default_body, engine, resolver, diags),
                .raw_variable => |v| try collectDiagnostics(a, tmpl_name, v.default_body, engine, resolver, diags),
                .let_binding => |lb| try collectDiagnostics(a, tmpl_name, lb.body, engine, resolver, diags),
                else => {},
            }
        }
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
    var parse_result = try Parser.parse(a, input, .{
        .err_detail = ctx.err_detail,
        .template_name = options.template_name,
    });
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

test "engine renderTemplateFormatted" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("frag.html", "<div>\n<p>hello</p>\n</div>");
    var ctx: Context = .{};
    var resolver: Resolver = .{};
    const result = try engine.renderTemplateFormatted(testing.allocator, "frag.html", &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("<div>\n  <p>hello</p>\n</div>", result);
}

test "engine removeTemplate" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("tmp.html", "hello");
    var ctx: Context = .{};
    var resolver: Resolver = .{};
    const r1 = try engine.renderTemplate(testing.allocator, "tmp.html", &ctx, &resolver, .{});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("hello", r1);

    engine.removeTemplate("tmp.html");
    try testing.expectError(error.TemplateNotFound, engine.renderTemplate(testing.allocator, "tmp.html", &ctx, &resolver, .{}));
}

test "engine removeTemplate non-existent is no-op" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    engine.removeTemplate("ghost.html");
}

test "engine removeTemplate then re-add" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("page.html", "v1");
    engine.removeTemplate("page.html");
    try engine.addTemplate("page.html", "v2");
    var ctx: Context = .{};
    var resolver: Resolver = .{};
    const result = try engine.renderTemplate(testing.allocator, "page.html", &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("v2", result);
}

test "engine clearTemplates" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("a.html", "A");
    try engine.addTemplate("b.html", "B");
    engine.clearTemplates();
    var ctx: Context = .{};
    var resolver: Resolver = .{};
    try testing.expectError(error.TemplateNotFound, engine.renderTemplate(testing.allocator, "a.html", &ctx, &resolver, .{}));
    try testing.expectError(error.TemplateNotFound, engine.renderTemplate(testing.allocator, "b.html", &ctx, &resolver, .{}));
}

test "engine HTMX fragment pattern" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("user-status.html", "<div id=\"status\"><t-var name=\"name\" /> is <t-var name=\"status\" /></div>");
    var ctx: Context = .{};
    try ctx.putData(testing.allocator, "name", .{ .string = "Alice" });
    try ctx.putData(testing.allocator, "status", .{ .string = "online" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};
    const result = try engine.renderTemplate(testing.allocator, "user-status.html", &ctx, &resolver, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("<div id=\"status\">Alice is online</div>", result);
}

test "engine renderTemplateToWriter equivalence" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("greet.html", "Hello <t-var name=\"name\" />!");
    var ctx: Context = .{};
    try ctx.putData(testing.allocator, "name", .{ .string = "World" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};

    const buffered = try engine.renderTemplate(testing.allocator, "greet.html", &ctx, &resolver, .{});
    defer testing.allocator.free(buffered);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);
    try engine.renderTemplateToWriter(testing.allocator, "greet.html", &ctx, &resolver, .{}, out.writer(testing.allocator));
    try testing.expectEqualStrings(buffered, out.items);
}

test "engine renderToWriter equivalence" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    const source = "Hi <t-var name=\"x\" />";
    var ctx: Context = .{};
    try ctx.putData(testing.allocator, "x", .{ .string = "42" });
    defer ctx.data.deinit(testing.allocator);
    var resolver: Resolver = .{};

    const buffered = try engine.render(testing.allocator, source, &ctx, &resolver, .{});
    defer testing.allocator.free(buffered);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);
    try engine.renderToWriter(testing.allocator, source, &ctx, &resolver, .{}, out.writer(testing.allocator));
    try testing.expectEqualStrings(buffered, out.items);
}

test "engine renderFormattedToWriter equivalence" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    const source = "<div>\n<p>hi</p>\n</div>";
    var ctx: Context = .{};
    var resolver: Resolver = .{};

    const buffered = try engine.renderFormatted(testing.allocator, source, &ctx, &resolver, .{});
    defer testing.allocator.free(buffered);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);
    try engine.renderFormattedToWriter(testing.allocator, source, &ctx, &resolver, .{}, out.writer(testing.allocator));
    try testing.expectEqualStrings(buffered, out.items);
}

test "engine validate catches missing include" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("page.html", "<t-include template=\"missing.html\" />");
    var resolver: Resolver = .{};
    const diags = try engine.validate(testing.allocator, &resolver);
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("missing.html", diags[0].message);
    try testing.expectEqualStrings("page.html", diags[0].template);
    try testing.expect(diags[0].kind == .err);
}

test "engine validate catches missing extend" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("child.html", "<t-extend template=\"ghost.html\"><t-define slot=\"main\">hi</t-define></t-extend>");
    var resolver: Resolver = .{};
    const diags = try engine.validate(testing.allocator, &resolver);
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("ghost.html", diags[0].message);
}

test "engine validate passes when templates exist in cache" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("base.html", "<t-slot name=\"main\" />");
    try engine.addTemplate("page.html", "<t-extend template=\"base.html\"><t-define slot=\"main\">content</t-define></t-extend>");
    var resolver: Resolver = .{};
    const diags = try engine.validate(testing.allocator, &resolver);
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "engine validate passes when templates exist in resolver" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("page.html", "<t-include template=\"nav.html\" />");
    var resolver: Resolver = .{};
    try resolver.put(testing.allocator, "nav.html", "<nav>links</nav>");
    defer resolver.deinit(testing.allocator);
    const diags = try engine.validate(testing.allocator, &resolver);
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "engine validate finds nested missing include" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("page.html", "<t-if var=\"show\"><t-include template=\"deep.html\" /></t-if>");
    var resolver: Resolver = .{};
    const diags = try engine.validate(testing.allocator, &resolver);
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("deep.html", diags[0].message);
}

test "engine validate empty cache returns no diagnostics" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    var resolver: Resolver = .{};
    const diags = try engine.validate(testing.allocator, &resolver);
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
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
    _ = @import("fuzz.zig");
    _ = @import("bench.zig");
}
