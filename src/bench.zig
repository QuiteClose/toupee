const std = @import("std");
const Parser = @import("Parser.zig");
const Renderer = @import("Renderer.zig");
const Ctx = @import("Context.zig");
const V = @import("Value.zig");
const toupee = @import("root.zig");

const template_source =
    \\<html>
    \\<head><title><t-var name="site.title" /></title></head>
    \\<body>
    \\<header><t-var name="site.name" /></header>
    \\<main>
    \\<h1><t-var name="page.title" /></h1>
    \\<t-for post in posts>
    \\<article>
    \\<h2><t-var name="post.title" /></h2>
    \\<p><t-var name="post.summary" /></p>
    \\<t-if var="post.tags">
    \\<t-for tag in post.tags>
    \\<span><t-var name="tag" /></span>
    \\</t-for>
    \\</t-if>
    \\</article>
    \\</t-for>
    \\</main>
    \\</body>
    \\</html>
;

fn buildContext(a: std.mem.Allocator) !Ctx.Context {
    var ctx: Ctx.Context = .{};
    var site: V.Map = .{};
    try site.put(a, "title", .{ .string = "My Blog" });
    try site.put(a, "name", .{ .string = "QuiteClose" });
    try ctx.putData(a, "site", .{ .map = site });
    var page: V.Map = .{};
    try page.put(a, "title", .{ .string = "Home" });
    try ctx.putData(a, "page", .{ .map = page });
    const post_count = 10;
    const posts = try a.alloc(V.Value, post_count);
    for (posts, 0..) |*post, i| {
        var m: V.Map = .{};
        var buf: [32]u8 = undefined;
        const title = std.fmt.bufPrint(&buf, "Post {d}", .{i + 1}) catch "Post";
        try m.put(a, "title", .{ .string = try a.dupe(u8, title) });
        try m.put(a, "summary", .{ .string = "Lorem ipsum dolor sit amet" });
        const tags = try a.alloc(V.Value, 3);
        tags[0] = .{ .string = "css" };
        tags[1] = .{ .string = "html" };
        tags[2] = .{ .string = "zig" };
        try m.put(a, "tags", .{ .list = tags });
        post.* = .{ .map = m };
    }
    try ctx.putData(a, "posts", .{ .list = posts });
    return ctx;
}

fn benchParse(a: std.mem.Allocator) !void {
    const iterations = 1000;
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        var result = try Parser.parse(a, template_source, .{});
        result.deinit();
    }
    const elapsed = timer.read();
    const ns_per_op = elapsed / iterations;
    std.debug.print("  parse:          {d} ns/op ({d} ops/sec)\n", .{
        ns_per_op,
        if (ns_per_op > 0) @as(u64, 1_000_000_000) / ns_per_op else 0,
    });
}

fn benchRender(a: std.mem.Allocator, nodes: []const @import("Node.zig").Node, ctx: *const Ctx.Context) !void {
    const iterations = 1000;
    var resolver: Ctx.Resolver = .{};
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const result = try Renderer.render(a, nodes, ctx, resolver.loader(), .{});
        a.free(result);
    }
    const elapsed = timer.read();
    const ns_per_op = elapsed / iterations;
    std.debug.print("  render:         {d} ns/op ({d} ops/sec)\n", .{
        ns_per_op,
        if (ns_per_op > 0) @as(u64, 1_000_000_000) / ns_per_op else 0,
    });
}

fn benchCachedRender(a: std.mem.Allocator, ctx: *const Ctx.Context) !void {
    const iterations = 1000;
    var engine = try toupee.Engine.init(a);
    defer engine.deinit();
    try engine.addTemplate("bench.html", template_source);
    var resolver: Ctx.Resolver = .{};
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const result = try engine.renderTemplate(a, "bench.html", ctx, resolver.loader(), .{});
        a.free(result);
    }
    const elapsed = timer.read();
    const ns_per_op = elapsed / iterations;
    std.debug.print("  cached render:  {d} ns/op ({d} ops/sec)\n", .{
        ns_per_op,
        if (ns_per_op > 0) @as(u64, 1_000_000_000) / ns_per_op else 0,
    });
}

fn benchFullPipeline(a: std.mem.Allocator, ctx: *const Ctx.Context) !void {
    const iterations = 1000;
    var resolver: Ctx.Resolver = .{};
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const result = try toupee.render(a, template_source, ctx, resolver.loader(), .{});
        a.free(result);
    }
    const elapsed = timer.read();
    const ns_per_op = elapsed / iterations;
    std.debug.print("  full pipeline:  {d} ns/op ({d} ops/sec)\n", .{
        ns_per_op,
        if (ns_per_op > 0) @as(u64, 1_000_000_000) / ns_per_op else 0,
    });
}

test "benchmark suite" {
    const a = std.testing.allocator;
    std.debug.print("\n--- Toupee Benchmarks ---\n", .{});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var ctx = try buildContext(aa);

    try benchParse(a);

    var parse_result = try Parser.parse(a, template_source, .{});
    defer parse_result.deinit();
    try benchRender(a, parse_result.nodes, &ctx);

    try benchCachedRender(a, &ctx);
    try benchFullPipeline(a, &ctx);

    std.debug.print("--- End Benchmarks ---\n\n", .{});
}
