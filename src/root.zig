const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Context = @import("Context.zig").Context;
pub const Entry = @import("Context.zig").Entry;
pub const Resolver = @import("Context.zig").Resolver;
pub const ErrorDetail = @import("Context.zig").ErrorDetail;
pub const RenderError = @import("Context.zig").RenderError;

const Engine = @import("Engine.zig");
const format = @import("format.zig");

pub fn render(a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver) RenderError![]const u8 {
    return Engine.render(a, input, ctx, resolver);
}

pub fn renderFormatted(a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver) (RenderError || error{OutOfMemory})![]const u8 {
    const raw = try Engine.render(a, input, ctx, resolver);
    defer a.free(raw);
    return format.prettyPrint(a, raw);
}

test {
    _ = @import("test_runner.zig");
    _ = @import("indent.zig");
    _ = @import("format.zig");
}
