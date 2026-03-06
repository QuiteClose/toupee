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
            .{ "js_escape", jsEscape },
            .{ "join", joinTransform },
            .{ "split", splitTransform },
            .{ "first", firstTransform },
            .{ "last", lastTransform },
            .{ "date", dateTransform },
            .{ "int", intTransform },
            .{ "float", floatTransform },
            .{ "decimal", decimalTransform },
            .{ "bool", boolTransform },
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
    const f = parseNumber(value);
    return formatMinimalFloat(a, @abs(f));
}

pub fn floorTransform(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    const f = parseNumber(value);
    return std.fmt.allocPrint(a, "{d}", .{floatToInt(@floor(f))});
}

pub fn ceilTransform(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    const f = parseNumber(value);
    return std.fmt.allocPrint(a, "{d}", .{floatToInt(@ceil(f))});
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

pub fn jsEscape(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    var out: std.ArrayList(u8) = .{};
    var i: usize = 0;
    while (i < value.len) {
        switch (value[i]) {
            '\\' => try out.appendSlice(a, "\\\\"),
            '"' => try out.appendSlice(a, "\\\""),
            '\'' => try out.appendSlice(a, "\\'"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => {
                // U+2028 LINE SEPARATOR: E2 80 A8
                if (i + 2 < value.len and value[i] == 0xE2 and value[i + 1] == 0x80 and value[i + 2] == 0xA8) {
                    try out.appendSlice(a, "\\u2028");
                    i += 3;
                    continue;
                }
                // U+2029 PARAGRAPH SEPARATOR: E2 80 A9
                if (i + 2 < value.len and value[i] == 0xE2 and value[i + 1] == 0x80 and value[i + 2] == 0xA9) {
                    try out.appendSlice(a, "\\u2029");
                    i += 3;
                    continue;
                }
                try out.append(a, value[i]);
            },
        }
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

pub fn dateTransform(a: Allocator, value: []const u8, args: []const []const u8) RenderError![]u8 {
    if (args.len == 0) return a.dupe(u8, value);
    const trimmed = std.mem.trim(u8, value, " \t\n\r");
    const date = parseIsoDate(trimmed) orelse return a.dupe(u8, value);
    return formatDate(a, date, args[0]);
}

const DateParts = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
};

fn parseIsoDate(s: []const u8) ?DateParts {
    if (s.len < 10) return null;
    if (s[4] != '-' or s[7] != '-') return null;
    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    var d = DateParts{ .year = year, .month = month, .day = day };
    if (s.len >= 19 and (s[10] == 'T' or s[10] == ' ')) {
        if (s[13] == ':' and s[16] == ':') {
            d.hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
            d.minute = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
            d.second = std.fmt.parseInt(u8, s[17..19], 10) catch return null;
        }
    }
    return d;
}

const month_names_full = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};
const month_names_abbr = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

fn formatDate(a: Allocator, d: DateParts, fmt: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .{};
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            switch (fmt[i + 1]) {
                'Y' => try appendPadded(&out, a, @intCast(d.year), 4),
                'm' => try appendPadded(&out, a, d.month, 2),
                'd' => try appendPadded(&out, a, d.day, 2),
                'e' => try appendNum(&out, a, d.day),
                'H' => try appendPadded(&out, a, d.hour, 2),
                'M' => try appendPadded(&out, a, d.minute, 2),
                'S' => try appendPadded(&out, a, d.second, 2),
                'B' => try out.appendSlice(a, month_names_full[d.month - 1]),
                'b' => try out.appendSlice(a, month_names_abbr[d.month - 1]),
                '%' => try out.append(a, '%'),
                else => {
                    try out.append(a, '%');
                    try out.append(a, fmt[i + 1]);
                },
            }
            i += 2;
        } else {
            try out.append(a, fmt[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

fn appendPadded(out: *std.ArrayList(u8), a: Allocator, val: u16, width: u8) Allocator.Error!void {
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch unreachable;
    var padding: u8 = 0;
    while (padding + s.len < width) : (padding += 1) try out.append(a, '0');
    try out.appendSlice(a, s);
}

fn appendNum(out: *std.ArrayList(u8), a: Allocator, val: u8) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch unreachable;
    try out.appendSlice(a, s);
}

/// Best-effort string-to-number coercion. Valid numbers parse normally,
/// "true" -> 1.0, "false" -> 0.0, anything else -> 0.0. Never errors.
fn parseNumber(value: []const u8) f64 {
    const trimmed = std.mem.trim(u8, value, " \t\n\r");
    return std.fmt.parseFloat(f64, trimmed) catch {
        if (std.mem.eql(u8, trimmed, "true")) return 1.0;
        if (std.mem.eql(u8, trimmed, "false")) return 0.0;
        return 0.0;
    };
}

pub fn intTransform(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    const f = parseNumber(value);
    const i = floatToInt(f);
    return std.fmt.allocPrint(a, "{d}", .{i});
}

pub fn floatTransform(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    const f = parseNumber(value);
    return formatMinimalFloat(a, f);
}

pub fn decimalTransform(a: Allocator, value: []const u8, args: []const []const u8) RenderError![]u8 {
    const places: usize = if (args.len > 0)
        std.fmt.parseInt(usize, args[0], 10) catch 2
    else
        2;
    const f = parseNumber(value);
    return formatDecimal(a, f, places);
}

pub fn boolTransform(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
    const trimmed = std.mem.trim(u8, value, " \t\n\r");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "false") or std.mem.eql(u8, trimmed, "0"))
        return a.dupe(u8, "false");
    return a.dupe(u8, "true");
}

/// Truncates f64 to i64, clamping to i64 range on overflow.
fn floatToInt(f: f64) i64 {
    if (std.math.isNan(f)) return 0;
    if (f >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return std.math.maxInt(i64);
    if (f <= @as(f64, @floatFromInt(std.math.minInt(i64)))) return std.math.minInt(i64);
    return @intFromFloat(f);
}

/// Formats an f64 with minimal representation (trailing zeros stripped).
fn formatMinimalFloat(a: Allocator, f: f64) Allocator.Error![]u8 {
    const buf = try std.fmt.allocPrint(a, "{d}", .{f});
    if (std.mem.indexOfScalar(u8, buf, '.')) |dot| {
        var end = buf.len;
        while (end > dot + 1 and buf[end - 1] == '0') end -= 1;
        if (end == dot + 1) end = dot;
        if (end < buf.len) return a.realloc(buf, end);
    }
    return buf;
}

/// Formats an f64 with exactly `places` decimal digits.
fn formatDecimal(a: Allocator, f: f64, places: usize) Allocator.Error![]u8 {
    const buf = try std.fmt.allocPrint(a, "{d}", .{f});
    if (std.mem.indexOfScalar(u8, buf, '.')) |dot| {
        const frac_len = buf.len - dot - 1;
        if (frac_len >= places) {
            const new_len = dot + 1 + places;
            if (places == 0) return a.realloc(buf, dot);
            return a.realloc(buf, new_len);
        }
        const padding = places - frac_len;
        const result = try a.realloc(buf, buf.len + padding);
        @memset(result[result.len - padding ..], '0');
        return result;
    } else {
        if (places == 0) return buf;
        const result = try a.realloc(buf, buf.len + 1 + places);
        result[buf.len] = '.';
        @memset(result[buf.len + 1 ..], '0');
        return result;
    }
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

test "js_escape backslash" {
    const result = try jsEscape(testing.allocator, "a\\b", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a\\\\b", result);
}

test "js_escape double quote" {
    const result = try jsEscape(testing.allocator, "say \"hello\"", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("say \\\"hello\\\"", result);
}

test "js_escape single quote" {
    const result = try jsEscape(testing.allocator, "it's", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("it\\'s", result);
}

test "js_escape newline and carriage return" {
    const result = try jsEscape(testing.allocator, "line1\nline2\rline3", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("line1\\nline2\\rline3", result);
}

test "js_escape tab" {
    const result = try jsEscape(testing.allocator, "col1\tcol2", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("col1\\tcol2", result);
}

test "js_escape unicode line/paragraph separators" {
    const result = try jsEscape(testing.allocator, "a\xe2\x80\xa8b\xe2\x80\xa9c", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a\\u2028b\\u2029c", result);
}

test "js_escape passthrough safe chars" {
    const result = try jsEscape(testing.allocator, "hello world 123", &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello world 123", result);
}

test "int transform" {
    const r1 = try intTransform(testing.allocator, "29.99", &.{});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("29", r1);

    const r2 = try intTransform(testing.allocator, "true", &.{});
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("1", r2);

    const r3 = try intTransform(testing.allocator, "hello", &.{});
    defer testing.allocator.free(r3);
    try testing.expectEqualStrings("0", r3);
}

test "float transform" {
    const r1 = try floatTransform(testing.allocator, "42", &.{});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("42", r1);

    const r2 = try floatTransform(testing.allocator, "29.990", &.{});
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("29.99", r2);
}

test "decimal transform" {
    const r1 = try decimalTransform(testing.allocator, "42", &.{"2"});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("42.00", r1);

    const r2 = try decimalTransform(testing.allocator, "29.999", &.{"2"});
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("29.99", r2);

    const r3 = try decimalTransform(testing.allocator, "3.1", &.{"4"});
    defer testing.allocator.free(r3);
    try testing.expectEqualStrings("3.1000", r3);
}

test "bool transform" {
    const r1 = try boolTransform(testing.allocator, "true", &.{});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("true", r1);

    const r2 = try boolTransform(testing.allocator, "false", &.{});
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("false", r2);

    const r3 = try boolTransform(testing.allocator, "0", &.{});
    defer testing.allocator.free(r3);
    try testing.expectEqualStrings("false", r3);

    const r4 = try boolTransform(testing.allocator, "hello", &.{});
    defer testing.allocator.free(r4);
    try testing.expectEqualStrings("true", r4);

    const r5 = try boolTransform(testing.allocator, "", &.{});
    defer testing.allocator.free(r5);
    try testing.expectEqualStrings("false", r5);
}

test "abs transform with float" {
    const r1 = try absTransform(testing.allocator, "-3.7", &.{});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("3.7", r1);

    const r2 = try absTransform(testing.allocator, "true", &.{});
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("1", r2);
}

test "floor and ceil with non-numeric" {
    const r1 = try floorTransform(testing.allocator, "hello", &.{});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("0", r1);

    const r2 = try ceilTransform(testing.allocator, "hello", &.{});
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("0", r2);
}

test "date transform with format" {
    const r1 = try dateTransform(testing.allocator, "2026-03-05", &.{"%B %e, %Y"});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("March 5, 2026", r1);

    const r2 = try dateTransform(testing.allocator, "2026-03-05", &.{"%d/%m/%Y"});
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("05/03/2026", r2);

    const r3 = try dateTransform(testing.allocator, "2026-01-15", &.{"%b %d"});
    defer testing.allocator.free(r3);
    try testing.expectEqualStrings("Jan 15", r3);
}

test "date transform with time" {
    const r1 = try dateTransform(testing.allocator, "2026-03-05T14:30:00", &.{"%Y-%m-%d %H:%M:%S"});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("2026-03-05 14:30:00", r1);
}

test "date transform invalid input passthrough" {
    const r1 = try dateTransform(testing.allocator, "not a date", &.{"%Y"});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("not a date", r1);
}

test "date transform literal percent" {
    const r1 = try dateTransform(testing.allocator, "2026-03-05", &.{"%%"});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("%", r1);
}

test "parseNumber best-effort" {
    try testing.expectEqual(@as(f64, 42.0), parseNumber("42"));
    try testing.expectEqual(@as(f64, 3.14), parseNumber("3.14"));
    try testing.expectEqual(@as(f64, 1.0), parseNumber("true"));
    try testing.expectEqual(@as(f64, 0.0), parseNumber("false"));
    try testing.expectEqual(@as(f64, 0.0), parseNumber("hello"));
    try testing.expectEqual(@as(f64, 0.0), parseNumber(""));
    try testing.expectEqual(@as(f64, -7.0), parseNumber(" -7 "));
}
