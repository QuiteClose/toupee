const std = @import("std");
const Allocator = std.mem.Allocator;
const RenderError = @import("Context.zig").RenderError;
const html = @import("html.zig");

pub const IndentResult = struct {
    slice: []const u8,
    allocated: bool,
};

/// Detect the current indentation from the output buffer.
/// Looks backwards from the end for the last newline, returns the
/// whitespace between it and the current position.
pub fn detectIndent(output: []const u8) []const u8 {
    if (output.len == 0) return "";
    var i = output.len;
    while (i > 0) {
        i -= 1;
        if (output[i] == '\n') {
            const after = output[i + 1 ..];
            var ws: usize = 0;
            while (ws < after.len and (after[ws] == ' ' or after[ws] == '\t')) : (ws += 1) {}
            if (ws == after.len) return after;
            return "";
        }
    }
    return "";
}

/// Append content with indentation applied to all lines after the first.
/// If content is empty, strips trailing whitespace from output (up to last newline).
pub fn appendIndented(a: Allocator, out: *std.ArrayList(u8), content: []const u8, indent: []const u8) RenderError!void {
    if (content.len == 0) {
        while (out.items.len > 0 and
            (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\t'))
        {
            _ = out.pop();
        }
        return;
    }
    if (indent.len == 0) {
        try out.appendSlice(a, content);
        return;
    }
    var first = true;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        if (i == content.len or content[i] == '\n') {
            const line = content[line_start..i];
            if (first) {
                try out.appendSlice(a, line);
                first = false;
            } else {
                try out.append(a, '\n');
                if (line.len > 0) {
                    try out.appendSlice(a, indent);
                    try out.appendSlice(a, line);
                }
            }
            line_start = i + 1;
        }
    }
}

/// Strip the common leading whitespace from a block of content.
/// Trims leading/trailing blank lines, then removes the minimum shared indent.
pub fn stripCommonIndent(a: Allocator, content: []const u8) RenderError!IndentResult {
    if (content.len == 0) return .{ .slice = "", .allocated = false };

    var lines = try splitLines(a, content);
    defer lines.deinit(a);

    const content_lines = trimBlankLines(lines.items);
    if (content_lines.len == 0) return .{ .slice = "", .allocated = false };

    const strip = findMinIndent(content_lines);
    if (strip == 0 and content_lines.len == 1) return .{ .slice = content_lines[0], .allocated = false };
    return .{ .slice = try joinLinesStripped(a, content_lines, strip), .allocated = true };
}

fn splitLines(a: Allocator, content: []const u8) !std.ArrayList([]const u8) {
    var lines: std.ArrayList([]const u8) = .{};
    var line_start: usize = 0;
    var j: usize = 0;
    while (j <= content.len) : (j += 1) {
        if (j == content.len or content[j] == '\n') {
            try lines.append(a, content[line_start..j]);
            line_start = j + 1;
        }
    }
    return lines;
}

fn trimBlankLines(lines: []const []const u8) []const []const u8 {
    var first: usize = 0;
    while (first < lines.len) : (first += 1) {
        if (html.isContentLine(lines[first])) break;
    }
    var last: usize = lines.len;
    while (last > first) {
        last -= 1;
        if (html.isContentLine(lines[last])) {
            last += 1;
            break;
        }
    }
    if (first >= last) return lines[0..0];
    return lines[first..last];
}

fn findMinIndent(lines: []const []const u8) usize {
    var min_indent: ?usize = null;
    for (lines) |line| {
        if (!html.isContentLine(line)) continue;
        var ws: usize = 0;
        while (ws < line.len and (line[ws] == ' ' or line[ws] == '\t')) : (ws += 1) {}
        if (min_indent == null or ws < min_indent.?) min_indent = ws;
    }
    return min_indent orelse 0;
}

fn joinLinesStripped(a: Allocator, lines: []const []const u8, strip: usize) RenderError![]const u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(a);
    for (lines, 0..) |line, idx| {
        if (idx > 0) try out.append(a, '\n');
        if (strip > 0 and html.isContentLine(line)) {
            if (line.len > strip) try out.appendSlice(a, line[strip..]);
        } else {
            try out.appendSlice(a, line);
        }
    }
    return try out.toOwnedSlice(a);
}

// ---- Tests ----

const testing = std.testing;

test "detectIndent: empty buffer" {
    try testing.expectEqualStrings("", detectIndent(""));
}

test "detectIndent: no newline" {
    try testing.expectEqualStrings("", detectIndent("hello"));
}

test "detectIndent: trailing indent" {
    try testing.expectEqualStrings("  ", detectIndent("hello\n  "));
}

test "detectIndent: trailing indent with tabs" {
    try testing.expectEqualStrings("\t\t", detectIndent("hello\n\t\t"));
}

test "detectIndent: no trailing whitespace after newline" {
    try testing.expectEqualStrings("", detectIndent("hello\nworld"));
}

test "appendIndented: empty content strips trailing ws" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(a);
    try out.appendSlice(a, "hello\n    ");
    try appendIndented(a, &out, "", "    ");
    try testing.expectEqualStrings("hello\n", out.items);
}

test "appendIndented: no indent passes through" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(a);
    try appendIndented(a, &out, "line1\nline2", "");
    try testing.expectEqualStrings("line1\nline2", out.items);
}

test "appendIndented: applies indent to subsequent lines" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(a);
    try appendIndented(a, &out, "line1\nline2\nline3", "  ");
    try testing.expectEqualStrings("line1\n  line2\n  line3", out.items);
}

test "appendIndented: empty lines get no indent" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(a);
    try appendIndented(a, &out, "a\n\nb", "  ");
    try testing.expectEqualStrings("a\n\n  b", out.items);
}

test "stripCommonIndent: empty string" {
    const a = testing.allocator;
    const result = try stripCommonIndent(a, "");
    try testing.expectEqualStrings("", result.slice);
    try testing.expect(!result.allocated);
}

test "stripCommonIndent: no indent" {
    const a = testing.allocator;
    const result = try stripCommonIndent(a, "hello");
    try testing.expectEqualStrings("hello", result.slice);
    try testing.expect(!result.allocated);
}

test "stripCommonIndent: uniform indent" {
    const a = testing.allocator;
    const result = try stripCommonIndent(a, "    line1\n    line2");
    defer if (result.allocated) a.free(result.slice);
    try testing.expectEqualStrings("line1\nline2", result.slice);
}

test "stripCommonIndent: mixed indent strips minimum" {
    const a = testing.allocator;
    const result = try stripCommonIndent(a, "  line1\n    line2");
    defer if (result.allocated) a.free(result.slice);
    try testing.expectEqualStrings("line1\n  line2", result.slice);
}

test "stripCommonIndent: trims leading blank lines" {
    const a = testing.allocator;
    const result = try stripCommonIndent(a, "\n\n  hello\n  world\n\n");
    defer if (result.allocated) a.free(result.slice);
    try testing.expectEqualStrings("hello\nworld", result.slice);
}
