const std = @import("std");
const Allocator = std.mem.Allocator;
const Loader = @import("Context.zig").Loader;

/// Tries multiple loaders in order, returning the first match.
/// Useful for layering an in-memory override map on top of a filesystem loader.
pub const ChainLoader = @This();

loaders: []const Loader,

/// Returns a `Loader` that delegates to each child loader in order.
pub fn loader(self: *const ChainLoader) Loader {
    return .{
        .ptr = @ptrCast(self),
        .getSourceFn = getSource,
    };
}

fn getSource(ptr: *const anyopaque, a: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
    const self: *const ChainLoader = @ptrCast(@alignCast(ptr));
    for (self.loaders) |l| {
        if (try l.getSource(a, name)) |source| return source;
    }
    return null;
}

const testing = std.testing;
const Resolver = @import("Context.zig").Resolver;

test "ChainLoader returns first match" {
    var r1: Resolver = .{};
    try r1.put(testing.allocator, "a.html", "from-r1");
    defer r1.deinit(testing.allocator);

    var r2: Resolver = .{};
    try r2.put(testing.allocator, "a.html", "from-r2");
    try r2.put(testing.allocator, "b.html", "from-r2");
    defer r2.deinit(testing.allocator);

    const chain = ChainLoader{ .loaders = &.{ r1.loader(), r2.loader() } };
    const a_src = (try chain.loader().getSource(testing.allocator, "a.html")).?;
    defer testing.allocator.free(a_src);
    try testing.expectEqualStrings("from-r1", a_src);

    const b_src = (try chain.loader().getSource(testing.allocator, "b.html")).?;
    defer testing.allocator.free(b_src);
    try testing.expectEqualStrings("from-r2", b_src);
}

test "ChainLoader returns null when no loader matches" {
    var r1: Resolver = .{};
    const chain = ChainLoader{ .loaders = &.{r1.loader()} };
    const source = try chain.loader().getSource(testing.allocator, "ghost.html");
    try testing.expect(source == null);
}

test "ChainLoader with empty loaders returns null" {
    const chain = ChainLoader{ .loaders = &.{} };
    const source = try chain.loader().getSource(testing.allocator, "any.html");
    try testing.expect(source == null);
}
