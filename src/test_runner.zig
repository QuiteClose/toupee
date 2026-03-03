const std = @import("std");
const Allocator = std.mem.Allocator;
const Ctx = @import("Context.zig");
const Context = Ctx.Context;
const Resolver = Ctx.Resolver;
const RenderError = Ctx.RenderError;
const V = @import("Value.zig");
const toupee = @import("root.zig");

const TestResults = struct {
    passed: usize = 0,
    failed: usize = 0,

    fn total(self: TestResults) usize {
        return self.passed + self.failed;
    }

    fn add(self: *TestResults, other: TestResults) void {
        self.passed += other.passed;
        self.failed += other.failed;
    }
};

const TestCase = struct {
    name: []const u8,
    templates: std.ArrayListUnmanaged(Template) = .{},
    input: ?[]const u8 = null,
    context_json: ?[]const u8 = null,
    expected_output: ?[]const u8 = null,
    expected_error: ?[]const u8 = null,
};

const Template = struct {
    name: []const u8,
    content: []const u8,
};

const Section = enum { none, in_named, in_anon, context, out };

pub fn runTestFile(a: Allocator, dir: std.fs.Dir, filename: []const u8) !TestResults {
    const content = try dir.readFileAlloc(a, filename, 1024 * 1024);
    defer a.free(content);

    var results = TestResults{};
    var cases: std.ArrayListUnmanaged(TestCase) = .{};
    defer {
        for (cases.items) |*c| c.templates.deinit(a);
        cases.deinit(a);
    }

    try parseTestCases(a, content, &cases);

    for (cases.items) |*tc| {
        if (runOneCase(a, tc)) {
            results.passed += 1;
        } else |_| {
            results.failed += 1;
        }
    }

    return results;
}

fn runOneCase(backing_allocator: Allocator, tc: *const TestCase) !void {
    const template_input = tc.input orelse {
        std.debug.print("    SKIP (no input): {s}\n", .{tc.name});
        return;
    };

    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var resolver: Resolver = .{};
    for (tc.templates.items) |tmpl| {
        try resolver.put(a, tmpl.name, tmpl.content);
    }

    var ctx: Context = .{};

    if (tc.context_json) |json_str| {
        if (json_str.len > 0) {
            try parseContextJson(a, json_str, &ctx, &resolver);
        }
    }

    if (tc.expected_error) |err_name| {
        const result = toupee.render(a, template_input, &ctx, &resolver, .{});
        if (result) |_| {
            std.debug.print("    FAIL [{s}]: expected error '{s}' but got success\n", .{ tc.name, err_name });
            return error.TestExpectedError;
        } else |err| {
            const actual_name = @errorName(err);
            if (!std.mem.eql(u8, actual_name, err_name)) {
                std.debug.print("    FAIL [{s}]: expected error '{s}' but got '{s}'\n", .{ tc.name, err_name, actual_name });
                return error.TestWrongError;
            }
        }
    } else if (tc.expected_output) |expected| {
        const result = toupee.render(a, template_input, &ctx, &resolver, .{}) catch |err| {
            std.debug.print("    FAIL [{s}]: unexpected error: {s}\n", .{ tc.name, @errorName(err) });
            return err;
        };

        if (!std.mem.eql(u8, result, expected)) {
            std.debug.print("\n    FAIL [{s}]:\n    --- expected ({d} bytes) ---\n{s}\n    --- actual ({d} bytes) ---\n{s}\n    --- end ---\n", .{
                tc.name,
                expected.len,
                expected,
                result.len,
                result,
            });
            return error.TestUnexpectedResult;
        }
    }
}

fn parseTestCases(a: Allocator, content: []const u8, cases: *std.ArrayListUnmanaged(TestCase)) !void {
    var current: ?*TestCase = null;
    var section: Section = .none;
    var section_start: usize = 0;
    var template_name: []const u8 = "";

    var i: usize = 0;
    while (i < content.len) {
        const line_start = i;
        const line_end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const line = content[line_start..line_end];
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (std.mem.startsWith(u8, trimmed, "<!-- test: ")) {
            if (current) |c| finishSection(a, content, section, section_start, line_start, template_name, c);
            const name_start = "<!-- test: ".len;
            const name_end = std.mem.indexOf(u8, trimmed[name_start..], " -->") orelse trimmed.len - name_start;
            const tc = try cases.addOne(a);
            tc.* = .{
                .name = trimmed[name_start .. name_start + name_end],
            };
            current = tc;
            section = .none;
        } else if (std.mem.startsWith(u8, trimmed, "<!-- in:")) {
            if (current) |c| finishSection(a, content, section, section_start, line_start, template_name, c);
            const after = "<!-- in:".len;
            const end = std.mem.indexOf(u8, trimmed[after..], " -->") orelse trimmed.len - after;
            template_name = std.mem.trim(u8, trimmed[after .. after + end], " \t");
            section = .in_named;
            section_start = line_end + 1;
        } else if (std.mem.eql(u8, trimmed, "<!-- in -->")) {
            if (current) |c| finishSection(a, content, section, section_start, line_start, template_name, c);
            section = .in_anon;
            section_start = line_end + 1;
        } else if (std.mem.eql(u8, trimmed, "<!-- context -->")) {
            if (current) |c| finishSection(a, content, section, section_start, line_start, template_name, c);
            section = .context;
            section_start = line_end + 1;
        } else if (std.mem.eql(u8, trimmed, "<!-- out -->")) {
            if (current) |c| finishSection(a, content, section, section_start, line_start, template_name, c);
            section = .out;
            section_start = line_end + 1;
        } else if (std.mem.startsWith(u8, trimmed, "<!-- error: ")) {
            if (current) |c| {
                finishSection(a, content, section, section_start, line_start, template_name, c);
                const after = "<!-- error: ".len;
                const end = std.mem.indexOf(u8, trimmed[after..], " -->") orelse trimmed.len - after;
                c.expected_error = trimmed[after .. after + end];
            }
            section = .none;
        }

        i = if (line_end < content.len) line_end + 1 else content.len;
    }

    if (current) |c| finishSection(a, content, section, section_start, content.len, template_name, c);
}

fn finishSection(a: Allocator, content: []const u8, section: Section, start: usize, end: usize, template_name: []const u8, tc: *TestCase) void {
    if (section == .none) return;
    if (start > content.len) return;
    const clamped_end = @min(end, content.len);
    if (start >= clamped_end) return;

    const raw = content[start..clamped_end];
    const trimmed = trimEnds(raw);

    switch (section) {
        .in_named => tc.templates.append(a, .{ .name = template_name, .content = trimmed }) catch {},
        .in_anon => tc.input = trimmed,
        .context => tc.context_json = std.mem.trim(u8, raw, " \t\r\n"),
        .out => tc.expected_output = trimmed,
        .none => {},
    }
}

fn trimEnds(s: []const u8) []const u8 {
    var start: usize = 0;
    if (start < s.len and s[start] == '\n') start += 1;
    var end = s.len;
    while (end > start and (s[end - 1] == '\n' or s[end - 1] == '\r' or
        s[end - 1] == ' ' or s[end - 1] == '\t')) : (end -= 1)
    {}
    return s[start..end];
}

/// Merges a JSON object into ctx.data, converting nested objects to Value.Map.
fn mergeJsonObjectIntoData(a: Allocator, target: *V.Map, obj: std.json.ObjectMap) std.mem.Allocator.Error!void {
    var it = obj.iterator();
    while (it.next()) |kv| {
        const key = try a.dupe(u8, kv.key_ptr.*);
        const val = try jsonValueToToupeeValue(a, kv.value_ptr.*);
        try target.put(a, key, val);
    }
}

fn jsonValueToToupeeValue(a: Allocator, jv: std.json.Value) std.mem.Allocator.Error!V.Value {
    return switch (jv) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .object => |obj| {
            var m: V.Map = .{};
            try mergeJsonObjectIntoData(a, &m, obj);
            return .{ .map = m };
        },
        .array => |arr| {
            const items = try a.alloc(V.Value, arr.items.len);
            for (arr.items, items) |item, *out| {
                out.* = try jsonValueToToupeeValue(a, item);
            }
            return .{ .list = items };
        },
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .integer = i },
        else => .{ .string = "" },
    };
}

fn parseContextJson(a: Allocator, json_str: []const u8, ctx: *Context, resolver: *Resolver) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json_str, .{
        .allocate = .alloc_always,
    }) catch |err| {
        std.debug.print("JSON parse error: {any}\n", .{err});
        return err;
    };
    defer parsed.deinit();
    const root = parsed.value;

    if (root != .object) return;

    if (root.object.get("data")) |data_val| {
        if (data_val == .object) {
            try mergeJsonObjectIntoData(a, &ctx.data, data_val.object);
        }
    }

    if (root.object.get("attrs")) |attrs_val| {
        if (attrs_val == .object) {
            var it = attrs_val.object.iterator();
            while (it.next()) |kv| {
                try ctx.putAttr(a, try a.dupe(u8, kv.key_ptr.*), switch (kv.value_ptr.*) {
                    .string => |s| try a.dupe(u8, s),
                    else => try a.dupe(u8, ""),
                });
            }
        }
    }

    if (root.object.get("slots")) |slots_val| {
        if (slots_val == .object) {
            var it = slots_val.object.iterator();
            while (it.next()) |kv| {
                try ctx.putSlot(a, try a.dupe(u8, kv.key_ptr.*), switch (kv.value_ptr.*) {
                    .string => |s| try a.dupe(u8, s),
                    else => try a.dupe(u8, ""),
                });
            }
        }
    }

    if (root.object.get("templates")) |templates_val| {
        if (templates_val == .object) {
            var it = templates_val.object.iterator();
            while (it.next()) |kv| {
                try resolver.put(a, try a.dupe(u8, kv.key_ptr.*), switch (kv.value_ptr.*) {
                    .string => |s| try a.dupe(u8, s),
                    else => try a.dupe(u8, ""),
                });
            }
        }
    }
}

const test_file_names = [_][]const u8{
    "var.test",
    "raw.test",
    "transform.test",
    "slot.test",
    "extend.test",
    "include.test",
    "conditional.test",
    "loop.test",
    "let.test",
    "comment.test",
    "bind.test",
    "nesting.test",
    "error.test",
    "integration.test",
};

test "toupee test suite" {
    var test_dir = std.fs.cwd().openDir("test", .{}) catch |err| {
        std.debug.print("\nCould not open test directory: {}\n", .{err});
        return err;
    };
    defer test_dir.close();

    var total = TestResults{};
    var any_failed = false;

    for (test_file_names) |filename| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const results = runTestFile(arena.allocator(), test_dir, filename) catch |err| {
            std.debug.print("  {s}: ERROR ({})\n", .{ filename, err });
            total.failed += 1;
            any_failed = true;
            continue;
        };

        const dot_pos = std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len;
        const name = filename[0..dot_pos];
        std.debug.print("  {s}: {d}/{d} passed\n", .{ name, results.passed, results.total() });
        if (results.failed > 0) any_failed = true;
        total.add(results);
    }

    std.debug.print("\n  Total: {d}/{d} passed\n\n", .{ total.passed, total.total() });

    if (any_failed) return error.TestSuiteFailure;
}
