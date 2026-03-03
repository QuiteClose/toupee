const std = @import("std");
const Allocator = std.mem.Allocator;
const RenderError = @import("Context.zig").RenderError;

pub const TransformFn = *const fn (Allocator, []const u8, []const []const u8) RenderError![]u8;

pub const Registry = struct {
    map: std.StringArrayHashMapUnmanaged(TransformFn) = .{},

    pub fn register(self: *Registry, a: Allocator, name: []const u8, func: TransformFn) !void {
        try self.map.put(a, name, func);
    }

    pub fn get(self: *const Registry, name: []const u8) ?TransformFn {
        return self.map.get(name);
    }

    pub fn registerBuiltins(self: *Registry, a: Allocator) !void {
        const builtins = .{
            .{ "upper", upper },
            .{ "lower", lower },
            .{ "capitalize", capitalize },
            .{ "trim", trimTransform },
            .{ "slugify", slugify },
            .{ "truncate", truncate },
            .{ "replace", replaceTransform },
            .{ "default", defaultTransform },
        };
        inline for (builtins) |entry| try self.register(a, entry[0], entry[1]);
    }

    pub fn deinit(self: *Registry, a: Allocator) void {
        self.map.deinit(a);
    }
};

// ---- Built-in transforms ----

pub fn upper(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    const buf = try a.alloc(u8, value.len);
    for (buf, value) |*b, c| b.* = std.ascii.toUpper(c);
    return buf;
}

pub fn lower(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    const buf = try a.alloc(u8, value.len);
    for (buf, value) |*b, c| b.* = std.ascii.toLower(c);
    return buf;
}

pub fn capitalize(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    const buf = try a.alloc(u8, value.len);
    var prev_space = true;
    for (buf, value) |*b, c| {
        b.* = if (prev_space and std.ascii.isAlphabetic(c)) std.ascii.toUpper(c) else c;
        prev_space = c == ' ' or c == '\t' or c == '\n';
    }
    return buf;
}

pub fn trimTransform(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    return a.dupe(u8, std.mem.trim(u8, value, " \t\n\r"));
}

pub fn slugify(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    var result: std.ArrayList(u8) = .{};
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

pub fn truncate(a: Allocator, value: []const u8, args: []const []const u8) RenderError![]u8 {
    if (args.len == 0) return error.MalformedElement;
    const n = std.fmt.parseInt(usize, args[0], 10) catch return error.MalformedElement;
    return a.dupe(u8, if (value.len <= n) value else value[0..n]);
}

pub fn replaceTransform(a: Allocator, value: []const u8, args: []const []const u8) RenderError![]u8 {
    if (args.len < 1) return error.MalformedElement;
    const old = args[0];
    const new = if (args.len > 1) args[1] else "";
    var result: std.ArrayList(u8) = .{};
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

pub fn defaultTransform(a: Allocator, value: []const u8, args: []const []const u8) RenderError![]u8 {
    const def = if (args.len > 0) args[0] else "";
    return a.dupe(u8, if (value.len == 0) def else value);
}

// ---- Tests ----

const testing = std.testing;

test "registry builtins" {
    var reg: Registry = .{};
    try reg.registerBuiltins(testing.allocator);
    defer reg.deinit(testing.allocator);

    try testing.expect(reg.get("upper") != null);
    try testing.expect(reg.get("lower") != null);
    try testing.expect(reg.get("capitalize") != null);
    try testing.expect(reg.get("trim") != null);
    try testing.expect(reg.get("slugify") != null);
    try testing.expect(reg.get("truncate") != null);
    try testing.expect(reg.get("replace") != null);
    try testing.expect(reg.get("default") != null);
    try testing.expect(reg.get("nonexistent") == null);
}

test "registry custom transform" {
    const reverse = struct {
        fn call(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
            const buf = try a.alloc(u8, value.len);
            for (buf, 0..) |*b, i| b.* = value[value.len - 1 - i];
            return buf;
        }
    }.call;

    var reg: Registry = .{};
    try reg.register(testing.allocator, "reverse", reverse);
    defer reg.deinit(testing.allocator);

    const func = reg.get("reverse").?;
    const result = try func(testing.allocator, "abc", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("cba", result);
}

test "upper transform" {
    const result = try upper(testing.allocator, "hello", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("HELLO", result);
}

test "slugify transform" {
    const result = try slugify(testing.allocator, "Hello World!", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello-world", result);
}
