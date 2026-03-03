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
pub const transform = @import("transform.zig");

pub const Engine = struct {
    allocator: Allocator,
    registry: transform.Registry,

    pub fn init(a: Allocator) !Engine {
        var reg: transform.Registry = .{};
        try reg.registerBuiltins(a);
        return .{ .allocator = a, .registry = reg };
    }

    pub fn deinit(self: *Engine) void {
        self.registry.deinit(self.allocator);
    }

    pub fn registerTransform(self: *Engine, name: []const u8, func: transform.TransformFn) !void {
        try self.registry.register(self.allocator, name, func);
    }

    pub fn render(self: *const Engine, a: Allocator, input: []const u8, ctx: *const Context, resolver: *const Resolver, options: Options) RenderError![]const u8 {
        var opts = options;
        opts.registry = &self.registry;
        return renderImpl(a, input, ctx, resolver, opts);
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
