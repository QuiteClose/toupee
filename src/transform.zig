const std = @import("std");
const Allocator = std.mem.Allocator;
const RenderError = @import("Context.zig").RenderError;

pub fn hasDefaultTransform(transform_spec: []const u8) bool {
    var pipe_iter = std.mem.splitScalar(u8, transform_spec, '|');
    while (pipe_iter.next()) |t| {
        if (std.mem.startsWith(u8, t, "default:") or std.mem.eql(u8, t, "default")) {
            return true;
        }
    }
    return false;
}

pub fn applyTransforms(a: Allocator, value: []const u8, transform_spec: []const u8) RenderError![]u8 {
    var current = try a.dupe(u8, value);
    errdefer a.free(current);

    var pipe_iter = std.mem.splitScalar(u8, transform_spec, '|');
    while (pipe_iter.next()) |transform| {
        if (transform.len == 0) continue;

        var colon_iter = std.mem.splitScalar(u8, transform, ':');
        const name = colon_iter.next().?;

        const next = try applyOne(a, current, name, &colon_iter);
        if (next.ptr != current.ptr) {
            a.free(current);
        }
        current = next;
    }

    return current;
}

fn applyOne(a: Allocator, value: []const u8, name: []const u8, args: *std.mem.SplitIterator(u8, .scalar)) RenderError![]u8 {
    if (std.mem.eql(u8, name, "upper")) {
        const buf = try a.alloc(u8, value.len);
        for (buf, value) |*b, c| b.* = std.ascii.toUpper(c);
        return buf;
    }
    if (std.mem.eql(u8, name, "lower")) {
        const buf = try a.alloc(u8, value.len);
        for (buf, value) |*b, c| b.* = std.ascii.toLower(c);
        return buf;
    }
    if (std.mem.eql(u8, name, "capitalize")) {
        const buf = try a.alloc(u8, value.len);
        var prev_space = true;
        for (buf, value) |*b, c| {
            b.* = if (prev_space and std.ascii.isAlphabetic(c)) std.ascii.toUpper(c) else c;
            prev_space = c == ' ' or c == '\t' or c == '\n';
        }
        return buf;
    }
    if (std.mem.eql(u8, name, "trim")) {
        return try a.dupe(u8, std.mem.trim(u8, value, " \t\n\r"));
    }
    if (std.mem.eql(u8, name, "slugify")) {
        var out: std.ArrayList(u8) = .{};
        errdefer out.deinit(a);
        var prev_hyphen = true;
        for (value) |c| {
            if (std.ascii.isAlphanumeric(c)) {
                try out.append(a, std.ascii.toLower(c));
                prev_hyphen = false;
            } else if (!prev_hyphen) {
                try out.append(a, '-');
                prev_hyphen = true;
            }
        }
        if (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
        return try out.toOwnedSlice(a);
    }
    if (std.mem.eql(u8, name, "truncate")) {
        const n_str = args.next() orelse return error.MalformedElement;
        const n = std.fmt.parseInt(usize, n_str, 10) catch return error.MalformedElement;
        if (value.len <= n) return try a.dupe(u8, value);
        return try a.dupe(u8, value[0..n]);
    }
    if (std.mem.eql(u8, name, "replace")) {
        const old = args.next() orelse return error.MalformedElement;
        const new = args.next() orelse "";
        var out: std.ArrayList(u8) = .{};
        errdefer out.deinit(a);
        var i: usize = 0;
        while (i < value.len) {
            if (old.len > 0 and i + old.len <= value.len and
                std.mem.eql(u8, value[i .. i + old.len], old))
            {
                try out.appendSlice(a, new);
                i += old.len;
            } else {
                try out.append(a, value[i]);
                i += 1;
            }
        }
        return try out.toOwnedSlice(a);
    }
    if (std.mem.eql(u8, name, "default")) {
        const def = args.next() orelse "";
        return try a.dupe(u8, if (value.len == 0) def else value);
    }
    return error.MalformedElement;
}
