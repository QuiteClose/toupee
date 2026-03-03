const std = @import("std");
const Allocator = std.mem.Allocator;
const RenderError = @import("Context.zig").RenderError;

/// Find the position of the closing `>` for a tag, respecting quoted attributes.
pub fn findTagEnd(input: []const u8) ?usize {
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '"') {
            i += 1;
            while (i < input.len and input[i] != '"') : (i += 1) {}
        } else if (input[i] == '>') {
            return i;
        }
    }
    return null;
}

/// Extract the value of a named attribute from a tag string.
/// Returns the content between quotes for `name="value"`.
/// Matches whole attribute names only (must be preceded by a space or tag start).
pub fn extractAttrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) {
        if (std.mem.startsWith(u8, tag[i..], name)) {
            if (i > 0 and tag[i - 1] != ' ') {
                i += 1;
                continue;
            }
            const after = i + name.len;
            if (after + 1 < tag.len and tag[after] == '=' and tag[after + 1] == '"') {
                const val_start = after + 2;
                if (std.mem.indexOfScalar(u8, tag[val_start..], '"')) |end| {
                    return tag[val_start .. val_start + end];
                }
            }
        }
        i += 1;
    }
    return null;
}

/// Check whether a boolean attribute (no value) is present in a tag.
/// Matches ` name` followed by space, `/`, or `>`, skipping quoted regions.
pub fn hasBoolAttr(tag: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (i < tag.len) {
        if (tag[i] == '"') {
            i += 1;
            while (i < tag.len and tag[i] != '"') : (i += 1) {}
            if (i < tag.len) i += 1;
        } else if (tag[i] == ' ' and i + 1 + name.len <= tag.len and
            std.mem.eql(u8, tag[i + 1 .. i + 1 + name.len], name))
        {
            const after = i + 1 + name.len;
            if (after >= tag.len or tag[after] == ' ' or
                tag[after] == '/' or tag[after] == '>')
            {
                return true;
            }
            i += 1;
        } else {
            i += 1;
        }
    }
    return false;
}

/// Append HTML-escaped text to an output buffer.
pub fn appendEscaped(a: Allocator, out: *std.ArrayList(u8), value: []const u8) RenderError!void {
    for (value) |c| {
        switch (c) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '"' => try out.appendSlice(a, "&quot;"),
            else => try out.append(a, c),
        }
    }
}

/// Parse all attributes from a tag, excluding the `template` attribute.
/// Used for extracting include attributes passed to child templates.
pub fn parseTagAttrs(a: Allocator, tag: []const u8) RenderError!std.StringArrayHashMapUnmanaged([]const u8) {
    var attrs: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    errdefer attrs.deinit(a);

    var i: usize = 1;
    while (i < tag.len and tag[i] != ' ' and tag[i] != '/' and tag[i] != '>') : (i += 1) {}

    while (i < tag.len) {
        while (i < tag.len and tag[i] == ' ') : (i += 1) {}
        if (i >= tag.len or tag[i] == '/' or tag[i] == '>') break;

        const name_start = i;
        while (i < tag.len and tag[i] != '=' and tag[i] != ' ' and tag[i] != '/' and tag[i] != '>') : (i += 1) {}
        const attr_name = tag[name_start..i];

        if (i < tag.len and tag[i] == '=') {
            i += 1;
            if (i < tag.len and tag[i] == '"') {
                i += 1;
                const val_start = i;
                while (i < tag.len and tag[i] != '"') : (i += 1) {}
                const attr_value = tag[val_start..i];
                if (i < tag.len) i += 1;

                if (!std.mem.eql(u8, attr_name, "template")) {
                    try attrs.put(a, attr_name, attr_value);
                }
            }
        } else {
            if (!std.mem.eql(u8, attr_name, "template")) {
                try attrs.put(a, attr_name, "");
            }
        }
    }

    return attrs;
}

/// Find the matching close tag for a nesting-aware search.
/// open_tag is the prefix that increments nesting (e.g. `<t-for `).
/// close_tag is the exact string to match at nesting zero.
pub fn findMatchingClose(input: []const u8, open_tag: []const u8, close_tag: []const u8) ?usize {
    var nesting: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], open_tag)) {
            nesting += 1;
            i += open_tag.len;
        } else if (std.mem.startsWith(u8, input[i..], close_tag)) {
            if (nesting == 0) return i;
            nesting -= 1;
            i += close_tag.len;
        } else {
            i += 1;
        }
    }
    return null;
}

pub fn computeLineCol(input: []const u8, pos: usize) struct { line: usize, column: usize } {
    var line: usize = 1;
    var col: usize = 1;
    const limit = @min(pos, input.len);
    for (input[0..limit]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .column = col };
}

pub fn skipWhitespace(input: []const u8) usize {
    var i: usize = 0;
    while (i < input.len and (input[i] == ' ' or input[i] == '\t' or
        input[i] == '\n' or input[i] == '\r')) : (i += 1)
    {}
    return i;
}

pub fn isContentLine(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return true;
    }
    return false;
}
