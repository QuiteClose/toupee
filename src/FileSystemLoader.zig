const std = @import("std");
const Allocator = std.mem.Allocator;
const Loader = @import("Context.zig").Loader;

/// Loads template sources from the filesystem relative to a base directory.
/// Returns null for missing or unreadable files; propagates allocation failures.
/// Memory for loaded content is owned by the allocator passed to `getSource`.
pub const FileSystemLoader = @This();

base_path: []const u8,

const max_template_size = 10 * 1024 * 1024;

/// Returns a `Loader` backed by this filesystem directory.
pub fn loader(self: *const FileSystemLoader) Loader {
    return .{
        .ptr = @ptrCast(self),
        .getSourceFn = getSource,
    };
}

fn getSource(ptr: *const anyopaque, a: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
    const self: *const FileSystemLoader = @ptrCast(@alignCast(ptr));
    const full_path = try std.fs.path.join(a, &.{ self.base_path, name });
    defer a.free(full_path);
    const file = std.fs.cwd().openFile(full_path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(a, max_template_size) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

const testing = std.testing;

test "FileSystemLoader returns file contents" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(.{ .sub_path = "hello.html", .data = "<p>hello</p>" }) catch unreachable;

    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);

    const fsl = FileSystemLoader{ .base_path = path };
    const source = try fsl.loader().getSource(testing.allocator, "hello.html");
    defer if (source) |s| testing.allocator.free(s);
    try testing.expectEqualStrings("<p>hello</p>", source.?);
}

test "FileSystemLoader returns null for missing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);

    const fsl = FileSystemLoader{ .base_path = path };
    const source = try fsl.loader().getSource(testing.allocator, "ghost.html");
    try testing.expect(source == null);
}

test "FileSystemLoader reads nested paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.makeDir("sub") catch unreachable;
    tmp.dir.writeFile(.{ .sub_path = "sub/nested.html", .data = "nested" }) catch unreachable;

    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);

    const fsl = FileSystemLoader{ .base_path = path };
    const source = try fsl.loader().getSource(testing.allocator, "sub/nested.html");
    defer if (source) |s| testing.allocator.free(s);
    try testing.expectEqualStrings("nested", source.?);
}
