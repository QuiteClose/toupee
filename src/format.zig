const std = @import("std");
const Allocator = std.mem.Allocator;
const RenderError = @import("Context.zig").RenderError;

const void_elements = [_][]const u8{
    "area", "base", "br", "col", "embed", "hr", "img",
    "input", "link", "meta", "param", "source", "track", "wbr",
};

fn isVoidElement(name: []const u8) bool {
    for (&void_elements) |ve| {
        if (std.mem.eql(u8, name, ve)) return true;
    }
    return false;
}

fn extractTagName(tag: []const u8) ?[]const u8 {
    if (tag.len < 2 or tag[0] != '<') return null;
    const start: usize = if (tag[1] == '/') 2 else 1;
    var end = start;
    while (end < tag.len and tag[end] != ' ' and tag[end] != '>' and tag[end] != '/') : (end += 1) {}
    if (end == start) return null;
    return tag[start..end];
}

/// Post-render HTML pretty-printer. Reformats rendered HTML with consistent
/// 2-space indentation. Operates on the final output string.
pub fn prettyPrint(a: Allocator, input: []const u8) RenderError![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(a);

    var depth: usize = 0;
    var i: usize = 0;
    var at_line_start = true;

    while (i < input.len) {
        if (input[i] == '\n') {
            try out.append(a, '\n');
            at_line_start = true;
            i += 1;
            while (i < input.len and (input[i] == ' ' or input[i] == '\t')) : (i += 1) {}
            continue;
        }

        if (input[i] == '<') {
            const tag_start = i;
            var j = i + 1;
            while (j < input.len and input[j] != '>') : (j += 1) {}
            if (j < input.len) j += 1;
            const tag = input[tag_start..j];

            const is_close = tag.len > 1 and tag[1] == '/';
            const is_self_closing = tag.len > 2 and tag[tag.len - 2] == '/';
            const is_doctype = tag.len > 1 and tag[1] == '!';
            const tag_name = extractTagName(tag);

            if (is_close) {
                if (depth > 0) depth -= 1;
            }

            if (at_line_start) {
                for (0..depth * 2) |_| try out.append(a, ' ');
            }

            try out.appendSlice(a, tag);

            if (!is_close and !is_self_closing and !is_doctype) {
                if (tag_name) |name| {
                    if (!isVoidElement(name)) depth += 1;
                }
            }

            at_line_start = false;
            i = j;
        } else {
            if (at_line_start) {
                for (0..depth * 2) |_| try out.append(a, ' ');
                at_line_start = false;
            }
            try out.append(a, input[i]);
            i += 1;
        }
    }

    return try out.toOwnedSlice(a);
}

// ---- Tests ----

const testing = std.testing;

test "prettyPrint: simple nested tags" {
    const a = testing.allocator;
    const result = try prettyPrint(a, "<div>\n<p>hello</p>\n</div>");
    defer a.free(result);
    try testing.expectEqualStrings("<div>\n  <p>hello</p>\n</div>", result);
}

test "prettyPrint: void elements don't increase depth" {
    const a = testing.allocator;
    const result = try prettyPrint(a, "<div>\n<br>\n<p>text</p>\n</div>");
    defer a.free(result);
    try testing.expectEqualStrings("<div>\n  <br>\n  <p>text</p>\n</div>", result);
}

test "prettyPrint: self-closing tags" {
    const a = testing.allocator;
    const result = try prettyPrint(a, "<div>\n<img />\n</div>");
    defer a.free(result);
    try testing.expectEqualStrings("<div>\n  <img />\n</div>", result);
}

test "prettyPrint: strips existing indentation" {
    const a = testing.allocator;
    const result = try prettyPrint(a, "<div>\n      <p>text</p>\n</div>");
    defer a.free(result);
    try testing.expectEqualStrings("<div>\n  <p>text</p>\n</div>", result);
}

test "prettyPrint: doctype doesn't increase depth" {
    const a = testing.allocator;
    const result = try prettyPrint(a, "<!DOCTYPE html>\n<html>\n<head>\n</head>\n</html>");
    defer a.free(result);
    try testing.expectEqualStrings("<!DOCTYPE html>\n<html>\n  <head>\n  </head>\n</html>", result);
}

test "prettyPrint: deeply nested" {
    const a = testing.allocator;
    const result = try prettyPrint(a, "<div>\n<ul>\n<li>item</li>\n</ul>\n</div>");
    defer a.free(result);
    try testing.expectEqualStrings("<div>\n  <ul>\n    <li>item</li>\n  </ul>\n</div>", result);
}

test "prettyPrint: inline content preserved" {
    const a = testing.allocator;
    const result = try prettyPrint(a, "<p>Hello <strong>world</strong></p>");
    defer a.free(result);
    try testing.expectEqualStrings("<p>Hello <strong>world</strong></p>", result);
}
