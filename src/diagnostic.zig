const std = @import("std");
const Ctx = @import("Context.zig");
const h = @import("html.zig");

pub const ErrorDetail = Ctx.ErrorDetail;

pub fn setError(
    ed: ?*ErrorDetail,
    source: []const u8,
    pos: usize,
    kind: ErrorDetail.Kind,
    name: []const u8,
    template_name: []const u8,
) void {
    const detail = ed orelse return;
    const lc = h.computeLineCol(source, pos);
    detail.* = .{
        .kind = kind,
        .message = name,
        .source_file = template_name,
        .line = lc.line,
        .column = lc.column,
        .source_line = extractSourceLine(source, pos),
        .caret_len = computeCaretLen(source, pos),
    };
}

pub fn extractSourceLine(source: []const u8, pos: usize) []const u8 {
    if (source.len == 0) return "";
    const clamped = @min(pos, source.len - 1);
    var start = clamped;
    while (start > 0 and source[start - 1] != '\n') : (start -= 1) {}
    var end = clamped;
    while (end < source.len and source[end] != '\n') : (end += 1) {}
    return source[start..end];
}

pub fn computeCaretLen(source: []const u8, pos: usize) usize {
    if (pos >= source.len or source[pos] != '<') return 1;
    var i = pos + 1;
    while (i < source.len and source[i] != '>' and source[i] != '\n') : (i += 1) {}
    return if (i < source.len and source[i] == '>') i - pos + 1 else @max(i - pos, 1);
}

/// Stack-allocated Levenshtein distance. Returns std.math.maxInt(usize) when
/// either string exceeds the row buffer (255 chars). This is only used for
/// typo suggestions where a threshold of 3 makes long-name comparisons moot.
pub fn levenshtein(a_str: []const u8, b_str: []const u8) usize {
    const max_len = 255;
    if (a_str.len > max_len or b_str.len > max_len) return std.math.maxInt(usize);
    if (a_str.len == 0) return b_str.len;
    if (b_str.len == 0) return a_str.len;

    var row: [max_len + 1]usize = undefined;
    for (0..b_str.len + 1) |j| row[j] = j;

    for (a_str) |a_ch| {
        var prev_diag = row[0];
        row[0] += 1;
        for (b_str, 0..) |b_ch, j| {
            const temp = row[j + 1];
            const cost: usize = if (a_ch == b_ch) 0 else 1;
            row[j + 1] = @min(@min(row[j + 1] + 1, row[j] + 1), prev_diag + cost);
            prev_diag = temp;
        }
    }
    return row[b_str.len];
}

const testing = std.testing;

test "extractSourceLine returns correct line" {
    const src = "line1\nline2\nline3";
    try testing.expectEqualStrings("line2", extractSourceLine(src, 7));
}

test "extractSourceLine empty input" {
    try testing.expectEqualStrings("", extractSourceLine("", 0));
}

test "computeCaretLen full tag" {
    try testing.expectEqual(@as(usize, 9), computeCaretLen("<t-var />\nhello<t-for x>", 15));
}

test "computeCaretLen non-tag" {
    try testing.expectEqual(@as(usize, 1), computeCaretLen("hello", 2));
}

test "levenshtein identical" {
    try testing.expectEqual(@as(usize, 0), levenshtein("abc", "abc"));
}

test "levenshtein single edit" {
    try testing.expectEqual(@as(usize, 1), levenshtein("abc", "adc"));
}

test "levenshtein empty" {
    try testing.expectEqual(@as(usize, 3), levenshtein("", "abc"));
}

test "setError populates detail" {
    var ed: ErrorDetail = .{};
    const source = "hello\n<t-var name=\"x\" />";
    setError(&ed, source, 6, .undefined_variable, "x", "test.html");
    try testing.expectEqual(@as(usize, 2), ed.line);
    try testing.expectEqual(@as(usize, 1), ed.column);
    try testing.expectEqualStrings("x", ed.message);
    try testing.expectEqualStrings("test.html", ed.source_file);
    try testing.expectEqual(ErrorDetail.Kind.undefined_variable, ed.kind);
    try testing.expectEqualStrings("<t-var name=\"x\" />", ed.source_line);
}

test "setError null ed is no-op" {
    setError(null, "hello", 0, .undefined_variable, "x", "test.html");
}
