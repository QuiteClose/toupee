const std = @import("std");
const Parser = @import("Parser.zig");
const Renderer = @import("Renderer.zig");
const Ctx = @import("Context.zig");

pub const std_options: std.Options = .{
    .log_level = .err,
};

test "fuzz parser does not crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const result = Parser.parse(a, input, .{});
            if (result) |r| {
                var mutable = r;
                mutable.deinit();
            } else |_| {}
        }
    }.run, .{ .corpus = &.{
        "<t-var name=\"x\" />",
        "<t-for item in items><t-var name=\"item.name\" /></t-for>",
        "<t-if var=\"x\">yes<t-else />no</t-if>",
        "<t-extend template=\"base.html\"><t-define name=\"\">body</t-define>",
        "<t-include template=\"comp.html\" label=\"ok\" />",
        "<t-let name=\"y\" transform=\"upper\">hello</t-let>",
        "<t-comment>hidden</t-comment>",
        "<t-raw name=\"html\" />",
    } });
}

test "fuzz renderer does not crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const parse_result = Parser.parse(a, input, .{}) catch return;
            var ctx: Ctx.Context = .{};
            ctx.put(a, "x", .{ .string = "val" }) catch return;
            ctx.put(a, "y", .{ .string = "val2" }) catch return;
            var resolver: Ctx.Resolver = .{};
            const rendered = Renderer.render(a, parse_result.nodes, &ctx, resolver.loader(), .{});
            _ = rendered catch {};
        }
    }.run, .{ .corpus = &.{
        "<t-var name=\"x\" />",
        "plain text",
        "<p>hello <t-var name=\"y\">default</t-var></p>",
    } });
}
