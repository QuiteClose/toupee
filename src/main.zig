const std = @import("std");

pub fn main() !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print("toupee: CLI not yet implemented\n", .{});
}
