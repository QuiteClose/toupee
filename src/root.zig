const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Context = @import("Context.zig").Context;
pub const Value = @import("Context.zig").Value;
pub const Resolver = @import("Context.zig").Resolver;
pub const ErrorDetail = @import("Context.zig").ErrorDetail;
pub const IncludeEntry = @import("Context.zig").IncludeEntry;
pub const RenderError = @import("Context.zig").RenderError;
pub const Options = @import("Renderer.zig").Options;

pub const Node = @import("Node.zig");
pub const Parser = @import("Parser.zig");
pub const Renderer = @import("Renderer.zig");

const format = @import("format.zig");

pub fn render(a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options) RenderError![]const u8 {
    var parse_result = try Parser.parse(a, input);
    defer parse_result.deinit();
    var opts = options;
    if (opts.template_source.len == 0) opts.template_source = input;
    return Renderer.render(a, parse_result.nodes, ctx, resolver, opts);
}

pub fn renderFormatted(a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options) (RenderError || error{OutOfMemory})![]const u8 {
    const raw = try render(a, input, ctx, resolver, options);
    defer a.free(raw);
    return format.prettyPrint(a, raw);
}

test {
    _ = @import("test_runner.zig");
    _ = @import("indent.zig");
    _ = @import("format.zig");
    _ = @import("Node.zig");
    _ = @import("Parser.zig");
    _ = @import("Renderer.zig");
    _ = @import("Value.zig");
}
