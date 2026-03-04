const std = @import("std");
const Allocator = std.mem.Allocator;

/// String-keyed map of Value. Keys are unique; key ownership follows the allocator that inserted them.
pub const Map = std.StringArrayHashMapUnmanaged(Value);

/// Tagged union of string, boolean, integer, list, map, or nil. `resolve()` navigates dot-separated
/// paths through nested maps and list indices (e.g. `"page.title"`, `"items.0.name"`).
pub const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    list: []const Value,
    map: Map,
    nil,

    /// Follows a dot-separated path (e.g. `"page.title"`, `"items.0"`) through nested maps and list indices.
    pub fn resolve(self: Value, path: []const u8) ?Value {
        if (path.len == 0) return self;
        return switch (self) {
            .map => |m| {
                if (std.mem.indexOfScalar(u8, path, '.')) |dot| {
                    const child = m.get(path[0..dot]) orelse return null;
                    return child.resolve(path[dot + 1 ..]);
                }
                return m.get(path);
            },
            .list => |items| {
                if (std.mem.indexOfScalar(u8, path, '.')) |dot| {
                    const idx = std.fmt.parseInt(usize, path[0..dot], 10) catch return null;
                    if (idx >= items.len) return null;
                    return items[idx].resolve(path[dot + 1 ..]);
                }
                const idx = std.fmt.parseInt(usize, path, 10) catch return null;
                if (idx >= items.len) return null;
                return items[idx];
            },
            else => null,
        };
    }

    /// Type narrowing: returns the string payload if this Value is .string, else null.
    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    /// Type narrowing: returns the list payload if this Value is .list, else null.
    pub fn asList(self: Value) ?[]const Value {
        return switch (self) {
            .list => |l| l,
            else => null,
        };
    }

    /// Type narrowing: returns the map payload if this Value is .map, else null.
    pub fn asMap(self: Value) ?Map {
        return switch (self) {
            .map => |m| m,
            else => null,
        };
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .string => |s| s.len > 0,
            .boolean => |b| b,
            .integer => |i| i != 0,
            .list => |l| l.len > 0,
            .map => |m| m.count() > 0,
            .nil => false,
        };
    }

    pub fn toStringValue(self: Value, a: Allocator) !?[]const u8 {
        return switch (self) {
            .string => |s| s,
            .boolean => |b| if (b) "true" else "false",
            .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
            .nil => null,
            .list, .map => null,
        };
    }

    pub fn eql(self: Value, other: Value) bool {
        const Tag = std.meta.Tag(Value);
        if (@as(Tag, self) != @as(Tag, other)) return false;
        return switch (self) {
            .string => |s| std.mem.eql(u8, s, other.string),
            .boolean => |b| b == other.boolean,
            .integer => |i| i == other.integer,
            .nil => true,
            .list => |l| {
                if (l.len != other.list.len) return false;
                for (l, other.list) |a_item, b_item| {
                    if (!a_item.eql(b_item)) return false;
                }
                return true;
            },
            .map => false,
        };
    }
};

/// Builds a Value.map from a slice of key-value pairs. Caller owns the returned map's memory.
pub fn mapFromSlice(a: Allocator, pairs: []const struct { []const u8, Value }) !Value {
    var m: Map = .{};
    for (pairs) |pair| try m.put(a, pair[0], pair[1]);
    return .{ .map = m };
}

// ---- Tests ----

const testing = std.testing;

test "string value" {
    const v: Value = .{ .string = "hello" };
    try testing.expectEqualStrings("hello", v.asString().?);
    try testing.expect(v.isTruthy());
}

test "empty string is falsy" {
    const v: Value = .{ .string = "" };
    try testing.expect(!v.isTruthy());
}

test "boolean values" {
    const t: Value = .{ .boolean = true };
    const f: Value = .{ .boolean = false };
    try testing.expect(t.isTruthy());
    try testing.expect(!f.isTruthy());
}

test "integer values" {
    const pos: Value = .{ .integer = 42 };
    const zero: Value = .{ .integer = 0 };
    try testing.expect(pos.isTruthy());
    try testing.expect(!zero.isTruthy());
}

test "nil is falsy" {
    const v: Value = .nil;
    try testing.expect(!v.isTruthy());
    try testing.expect(v.asString() == null);
}

test "list value" {
    const items = [_]Value{ .{ .string = "a" }, .{ .string = "b" } };
    const v: Value = .{ .list = &items };
    try testing.expectEqual(@as(usize, 2), v.asList().?.len);
    try testing.expect(v.isTruthy());
}

test "empty list is falsy" {
    const v: Value = .{ .list = &.{} };
    try testing.expect(!v.isTruthy());
}

test "map value" {
    var m: Map = .{};
    defer m.deinit(testing.allocator);
    try m.put(testing.allocator, "key", .{ .string = "val" });
    const v: Value = .{ .map = m };
    try testing.expect(v.isTruthy());
    try testing.expect(v.asMap() != null);
}

test "empty map is falsy" {
    const m: Map = .{};
    const v: Value = .{ .map = m };
    try testing.expect(!v.isTruthy());
}

test "resolve simple key" {
    var m: Map = .{};
    defer m.deinit(testing.allocator);
    try m.put(testing.allocator, "title", .{ .string = "Hello" });
    const root: Value = .{ .map = m };
    const result = root.resolve("title") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Hello", result.asString().?);
}

test "resolve dot-path" {
    var inner: Map = .{};
    defer inner.deinit(testing.allocator);
    try inner.put(testing.allocator, "title", .{ .string = "My Page" });
    var outer: Map = .{};
    defer outer.deinit(testing.allocator);
    try outer.put(testing.allocator, "page", .{ .map = inner });
    const root: Value = .{ .map = outer };
    const result = root.resolve("page.title") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("My Page", result.asString().?);
}

test "resolve deeply nested path" {
    var l3: Map = .{};
    defer l3.deinit(testing.allocator);
    try l3.put(testing.allocator, "name", .{ .string = "deep" });
    var l2: Map = .{};
    defer l2.deinit(testing.allocator);
    try l2.put(testing.allocator, "c", .{ .map = l3 });
    var l1: Map = .{};
    defer l1.deinit(testing.allocator);
    try l1.put(testing.allocator, "b", .{ .map = l2 });
    var root_map: Map = .{};
    defer root_map.deinit(testing.allocator);
    try root_map.put(testing.allocator, "a", .{ .map = l1 });

    const root: Value = .{ .map = root_map };
    const result = root.resolve("a.b.c.name") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("deep", result.asString().?);
}

test "resolve missing key returns null" {
    var m: Map = .{};
    defer m.deinit(testing.allocator);
    try m.put(testing.allocator, "title", .{ .string = "Hello" });
    const root: Value = .{ .map = m };
    try testing.expect(root.resolve("missing") == null);
}

test "resolve missing nested key returns null" {
    var inner: Map = .{};
    defer inner.deinit(testing.allocator);
    try inner.put(testing.allocator, "title", .{ .string = "Hello" });
    var outer: Map = .{};
    defer outer.deinit(testing.allocator);
    try outer.put(testing.allocator, "page", .{ .map = inner });
    const root: Value = .{ .map = outer };
    try testing.expect(root.resolve("page.missing") == null);
    try testing.expect(root.resolve("missing.title") == null);
}

test "resolve through non-map returns null" {
    var m: Map = .{};
    defer m.deinit(testing.allocator);
    try m.put(testing.allocator, "name", .{ .string = "hello" });
    const root: Value = .{ .map = m };
    try testing.expect(root.resolve("name.sub") == null);
}

test "resolve on non-map root returns null" {
    const v: Value = .{ .string = "hello" };
    try testing.expect(v.resolve("key") == null);
}

test "resolve empty path returns self" {
    const v: Value = .{ .string = "hello" };
    const result = v.resolve("") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("hello", result.asString().?);
}

test "resolve list by index" {
    const items = [_]Value{ .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" } };
    const v: Value = .{ .list = &items };
    const result = v.resolve("1") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("b", result.asString().?);
}

test "resolve list index out of bounds" {
    const items = [_]Value{ .{ .string = "a" } };
    const v: Value = .{ .list = &items };
    try testing.expect(v.resolve("5") == null);
}

test "resolve nested through list" {
    var inner: Map = .{};
    defer inner.deinit(testing.allocator);
    try inner.put(testing.allocator, "name", .{ .string = "first" });
    const items = [_]Value{.{ .map = inner }};
    const v: Value = .{ .list = &items };
    const result = v.resolve("0.name") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("first", result.asString().?);
}

test "toStringValue conversions" {
    const str: Value = .{ .string = "hello" };
    try testing.expectEqualStrings("hello", (try str.toStringValue(testing.allocator)).?);

    const t: Value = .{ .boolean = true };
    try testing.expectEqualStrings("true", (try t.toStringValue(testing.allocator)).?);

    const f: Value = .{ .boolean = false };
    try testing.expectEqualStrings("false", (try f.toStringValue(testing.allocator)).?);

    const n: Value = .nil;
    try testing.expect((try n.toStringValue(testing.allocator)) == null);

    const i: Value = .{ .integer = 42 };
    const i_str = (try i.toStringValue(testing.allocator)).?;
    defer testing.allocator.free(i_str);
    try testing.expectEqualStrings("42", i_str);
}

test "value equality" {
    try testing.expect((Value{ .string = "a" }).eql(.{ .string = "a" }));
    try testing.expect(!(Value{ .string = "a" }).eql(.{ .string = "b" }));
    try testing.expect((Value{ .boolean = true }).eql(.{ .boolean = true }));
    try testing.expect(!(Value{ .boolean = true }).eql(.{ .boolean = false }));
    try testing.expect((Value{ .integer = 5 }).eql(.{ .integer = 5 }));
    try testing.expect((Value{ .nil = {} }).eql(.nil));
    try testing.expect(!(Value{ .string = "a" }).eql(.nil));
}

test "list equality" {
    const a = [_]Value{ .{ .string = "x" }, .{ .integer = 1 } };
    const b = [_]Value{ .{ .string = "x" }, .{ .integer = 1 } };
    const c = [_]Value{ .{ .string = "y" }, .{ .integer = 1 } };
    try testing.expect((Value{ .list = &a }).eql(.{ .list = &b }));
    try testing.expect(!(Value{ .list = &a }).eql(.{ .list = &c }));
}
