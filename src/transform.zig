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
            .{ "length", lengthTransform },
            .{ "abs", absTransform },
            .{ "floor", floorTransform },
            .{ "ceil", ceilTransform },
            .{ "escape", escapeTransform },
            .{ "url_encode", urlEncode },
            .{ "url_decode", urlDecode },
            .{ "join", joinTransform },
            .{ "split", splitTransform },
            .{ "first", firstTransform },
            .{ "last", lastTransform },
            .{ "date", dateTransform },
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

pub fn lengthTransform(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    return std.fmt.allocPrint(a, "{d}", .{value.len});
}

pub fn absTransform(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    const trimmed = std.mem.trim(u8, value, " \t\n\r");
    const n = std.fmt.parseInt(i64, trimmed, 10) catch return error.MalformedElement;
    return std.fmt.allocPrint(a, "{d}", .{if (n < 0) @as(u64, @intCast(-n)) else @as(u64, @intCast(n))});
}

pub fn floorTransform(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    const trimmed = std.mem.trim(u8, value, " \t\n\r");
    const f = std.fmt.parseFloat(f64, trimmed) catch return error.MalformedElement;
    return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(@floor(f)))});
}

pub fn ceilTransform(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    const trimmed = std.mem.trim(u8, value, " \t\n\r");
    const f = std.fmt.parseFloat(f64, trimmed) catch return error.MalformedElement;
    return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(@ceil(f)))});
}

pub fn escapeTransform(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    var out: std.ArrayList(u8) = .{};
    for (value) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\'' => try out.appendSlice(a, "&#x27;"),
        else => try out.append(a, c),
    };
    return out.toOwnedSlice(a);
}

pub fn urlEncode(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    var out: std.ArrayList(u8) = .{};
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(a, c);
        } else {
            try out.append(a, '%');
            try out.append(a, hexDigit(c >> 4));
            try out.append(a, hexDigit(c & 0x0f));
        }
    }
    return out.toOwnedSlice(a);
}

pub fn urlDecode(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    var out: std.ArrayList(u8) = .{};
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '%' and i + 2 < value.len) {
            const hi = hexVal(value[i + 1]);
            const lo = hexVal(value[i + 2]);
            if (hi != null and lo != null) {
                try out.append(a, (@as(u8, hi.?) << 4) | @as(u8, lo.?));
                i += 3;
                continue;
            }
        }
        try out.append(a, value[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

pub fn joinTransform(a: Allocator, value: []const u8, args: []const []const u8) RenderError![]u8 {
    const sep = if (args.len > 0) args[0] else " ";
    var out: std.ArrayList(u8) = .{};
    var first = true;
    var it = std.mem.splitScalar(u8, value, '\n');
    while (it.next()) |line| {
        if (!first) try out.appendSlice(a, sep);
        try out.appendSlice(a, line);
        first = false;
    }
    return out.toOwnedSlice(a);
}

pub fn splitTransform(a: Allocator, value: []const u8, args: []const []const u8) RenderError![]u8 {
    if (args.len == 0) return error.MalformedElement;
    const sep = args[0];
    if (sep.len == 0) return a.dupe(u8, value);
    var out: std.ArrayList(u8) = .{};
    var i: usize = 0;
    var first = true;
    while (i < value.len) {
        if (i + sep.len <= value.len and std.mem.eql(u8, value[i .. i + sep.len], sep)) {
            if (!first) try out.append(a, '\n');
            first = false;
            i += sep.len;
        } else {
            if (first) first = false;
            try out.append(a, value[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

pub fn firstTransform(a: Allocator, value: []const u8, args: []const []const u8) RenderError![]u8 {
    const n = if (args.len > 0)
        std.fmt.parseInt(usize, args[0], 10) catch return error.MalformedElement
    else
        1;
    return a.dupe(u8, value[0..@min(n, value.len)]);
}

pub fn lastTransform(a: Allocator, value: []const u8, args: []const []const u8) RenderError![]u8 {
    const n = if (args.len > 0)
        std.fmt.parseInt(usize, args[0], 10) catch return error.MalformedElement
    else
        1;
    const start = if (n >= value.len) 0 else value.len - n;
    return a.dupe(u8, value[start..]);
}

pub fn dateTransform(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    return a.dupe(u8, value);
}

fn hexDigit(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'A' + nibble - 10;
}

fn hexVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
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

test "length transform" {
    const result = try lengthTransform(testing.allocator, "hello", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("5", result);
}

test "abs transform" {
    const r1 = try absTransform(testing.allocator, "-42", &.{});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("42", r1);

    const r2 = try absTransform(testing.allocator, "7", &.{});
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("7", r2);
}

test "floor transform" {
    const result = try floorTransform(testing.allocator, "3.7", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("3", result);
}

test "ceil transform" {
    const result = try ceilTransform(testing.allocator, "3.2", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("4", result);
}

test "escape transform" {
    const result = try escapeTransform(testing.allocator, "<b>\"hi\"</b>", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("&lt;b&gt;&quot;hi&quot;&lt;/b&gt;", result);
}

test "url_encode transform" {
    const result = try urlEncode(testing.allocator, "hello world&foo=bar", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello%20world%26foo%3Dbar", result);
}

test "url_decode transform" {
    const result = try urlDecode(testing.allocator, "hello%20world%26foo", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello world&foo", result);
}

test "join transform" {
    const result = try joinTransform(testing.allocator, "a\nb\nc", &.{", "});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a, b, c", result);
}

test "split transform" {
    const result = try splitTransform(testing.allocator, "a, b, c", &.{", "});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a\nb\nc", result);
}

test "first transform" {
    const r1 = try firstTransform(testing.allocator, "hello", &.{});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("h", r1);

    const r2 = try firstTransform(testing.allocator, "hello", &.{"3"});
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("hel", r2);
}

test "last transform" {
    const r1 = try lastTransform(testing.allocator, "hello", &.{});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("o", r1);

    const r2 = try lastTransform(testing.allocator, "hello", &.{"3"});
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("llo", r2);
}

test "date transform passthrough" {
    const result = try dateTransform(testing.allocator, "2026-03-03", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("2026-03-03", result);
}
