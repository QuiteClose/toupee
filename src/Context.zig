const std = @import("std");
const Allocator = std.mem.Allocator;
const V = @import("Value.zig");

pub const Value = V.Value;

/// One frame in the include stack trace. Used by ErrorDetail for error reporting.
pub const IncludeEntry = struct {
    template: []const u8 = "",
    line: usize = 0,
};

/// Rich error context populated by the Renderer (or Parser) on failure. Caller must allocate
/// and pass a pointer via `ctx.err_detail`. String fields are copied into an inline buffer
/// so they remain valid after the render arena is freed.
pub const ErrorDetail = struct {
    line: usize = 0,
    column: usize = 0,
    source_file: []const u8 = "",
    message: []const u8 = "",
    source_line: []const u8 = "",
    caret_len: usize = 0,
    kind: Kind = .none,
    suggestion: []const u8 = "",
    include_stack_len: u8 = 0,
    /// Most recent 16 include frames for error context. Smaller than max_depth
    /// by design: error messages only need the innermost frames.
    include_stack_buf: [16]IncludeEntry = [_]IncludeEntry{.{}} ** 16,
    string_buf: [2048]u8 = undefined,
    string_used: usize = 0,

    pub const Kind = enum {
        none,
        undefined_variable,
        template_not_found,
        circular_reference,
        malformed_element,
        duplicate_slot,
    };

    /// Copies `s` into the inline buffer and returns a slice into it. If the
    /// buffer is full, falls back to returning the original (borrowed) slice.
    pub fn store(self: *ErrorDetail, s: []const u8) []const u8 {
        if (s.len == 0) return s;
        if (self.string_used + s.len > self.string_buf.len) return s;
        const start = self.string_used;
        @memcpy(self.string_buf[start .. start + s.len], s);
        self.string_used += s.len;
        return self.string_buf[start .. start + s.len];
    }

    /// Returns the include stack slice (innermost frames first).
    pub fn includeStack(self: *const ErrorDetail) []const IncludeEntry {
        return self.include_stack_buf[0..self.include_stack_len];
    }

    /// Produces a human-readable error message with location and include stack.
    pub fn formatError(self: *const ErrorDetail, a: Allocator) Allocator.Error![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        try writeHeader(a, &buf, self.kind, self.message, self.source_file);
        if (self.source_file.len > 0 and self.line > 0)
            try writeLocation(a, &buf, self.source_file, self.line, self.column);
        if (self.source_line.len > 0)
            try writeExcerpt(a, &buf, self.line, self.source_line, self.column, self.caret_len);
        if (self.suggestion.len > 0) {
            try buf.appendSlice(a, "   |\n   = did you mean '");
            try buf.appendSlice(a, self.suggestion);
            try buf.appendSlice(a, "'?\n");
        }
        for (self.includeStack()) |entry| try writeStackEntry(a, &buf, entry);
        return buf.toOwnedSlice(a);
    }
};

fn writeHeader(
    a: Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    kind: ErrorDetail.Kind,
    message: []const u8,
    source_file: []const u8,
) Allocator.Error!void {
    try buf.appendSlice(a, "error: ");
    switch (kind) {
        .undefined_variable => {
            try buf.appendSlice(a, "undefined variable '");
            try buf.appendSlice(a, message);
            try buf.append(a, '\'');
        },
        .template_not_found => {
            try buf.appendSlice(a, "template '");
            try buf.appendSlice(a, message);
            try buf.appendSlice(a, "' not found");
        },
        .circular_reference => {
            try buf.appendSlice(a, "circular reference in template '");
            try buf.appendSlice(a, message);
            try buf.append(a, '\'');
        },
        .malformed_element => try buf.appendSlice(a, "malformed template element"),
        .duplicate_slot => {
            try buf.appendSlice(a, "duplicate slot definition '");
            try buf.appendSlice(a, message);
            try buf.append(a, '\'');
        },
        .none => try buf.appendSlice(a, message),
    }
    if (source_file.len > 0) {
        try buf.appendSlice(a, " in '");
        try buf.appendSlice(a, source_file);
        try buf.append(a, '\'');
    }
    try buf.append(a, '\n');
}

fn writeLocation(a: Allocator, buf: *std.ArrayListUnmanaged(u8), file: []const u8, line: usize, col: usize) Allocator.Error!void {
    try buf.appendSlice(a, "  --> ");
    try buf.appendSlice(a, file);
    try buf.append(a, ':');
    try appendUsize(a, buf, line);
    try buf.append(a, ':');
    try appendUsize(a, buf, col);
    try buf.append(a, '\n');
}

fn writeExcerpt(
    a: Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    line: usize,
    source_line: []const u8,
    col: usize,
    caret_len: usize,
) Allocator.Error!void {
    try buf.appendSlice(a, "   |\n");
    var num_buf: [20]u8 = undefined;
    const line_str = std.fmt.bufPrint(&num_buf, "{d}", .{line}) catch "?";
    var j: usize = 0;
    while (j + line_str.len < 4) : (j += 1) try buf.append(a, ' ');
    try buf.appendSlice(a, line_str);
    try buf.appendSlice(a, " | ");
    try buf.appendSlice(a, source_line);
    try buf.appendSlice(a, "\n     | ");
    j = 0;
    while (j + 1 < col) : (j += 1) try buf.append(a, ' ');
    const width = @max(caret_len, 1);
    j = 0;
    while (j < width) : (j += 1) try buf.append(a, '^');
    try buf.append(a, '\n');
}

fn writeStackEntry(a: Allocator, buf: *std.ArrayListUnmanaged(u8), entry: IncludeEntry) Allocator.Error!void {
    try buf.appendSlice(a, "   = included from '");
    try buf.appendSlice(a, entry.template);
    try buf.append(a, ':');
    try appendUsize(a, buf, entry.line);
    try buf.appendSlice(a, "'\n");
}

fn appendUsize(a: Allocator, buf: *std.ArrayListUnmanaged(u8), value: usize) Allocator.Error!void {
    var num_buf: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch "?";
    try buf.appendSlice(a, s);
}

/// Render context holding data, attributes, slots, and optional error detail.
/// Owns an `ArenaAllocator` for all internal data; `deinit()` frees everything at once.
/// The Renderer copies data into child contexts, so the original is safe to reuse across render calls.
pub const Context = struct {
    arena: std.heap.ArenaAllocator,
    /// Nested variable tree.
    data: V.Map = .{},
    attrs: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    slots: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    /// If non-null, populated on render/parse error. Caller allocates and passes; fields valid only after error.
    err_detail: ?*ErrorDetail = null,

    /// Creates a new context backed by `backing` allocator.
    pub fn init(backing: Allocator) Context {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    /// Creates a child context backed by `backing` allocator, copying data from `parent`.
    /// `data` entries are shallow-copied into the child's arena. `attrs`, `slots`, and
    /// `err_detail` are shared by reference -- the child and parent point to the same
    /// underlying storage. Callers must not mutate `attrs` or `slots` through the child
    /// without first reassigning them to a freshly-built map (as the Renderer does).
    pub fn initFrom(backing: Allocator, parent: *const Context) Allocator.Error!Context {
        var child = init(backing);
        const a = child.allocator();
        var it = parent.data.iterator();
        while (it.next()) |kv| try child.data.put(a, kv.key_ptr.*, kv.value_ptr.*);
        child.attrs = parent.attrs;
        child.slots = parent.slots;
        child.err_detail = parent.err_detail;
        return child;
    }

    fn allocator(self: *Context) Allocator {
        return self.arena.allocator();
    }

    /// Frees all data owned by this context.
    pub fn deinit(self: *Context) void {
        self.arena.deinit();
    }

    /// Looks up a dot-separated path in `data` (e.g. `page.title`).
    pub fn resolve(self: *const Context, path: []const u8) ?Value {
        const root: Value = .{ .map = self.data };
        return root.resolve(path);
    }

    /// Resolves path and returns the string payload, or null if not found or not a string.
    pub fn resolveString(self: *const Context, path: []const u8) ?[]const u8 {
        const val = self.resolve(path) orelse return null;
        return val.asString();
    }

    /// Inserts a value at a top-level key in `data`.
    pub fn put(self: *Context, key: []const u8, value: Value) !void {
        try self.data.put(self.allocator(), key, value);
    }

    /// Inserts a value at a dot-separated path, creating intermediate maps as needed.
    /// `"page.title"` ensures a `"page"` map exists in `data`, then puts `"title"` into it.
    /// Returns `error.PathConflict` if an intermediate key exists but is not a `.map`.
    /// Empty path is a no-op.
    pub fn putAt(self: *Context, path: []const u8, value: Value) (Allocator.Error || error{PathConflict})!void {
        if (path.len == 0) return;

        const a = self.allocator();
        var current_map: *V.Map = &self.data;
        var it = std.mem.splitScalar(u8, path, '.');

        var segment = it.next().?;
        while (it.peek() != null) {
            if (current_map.getPtr(segment)) |val_ptr| {
                switch (val_ptr.*) {
                    .map => |*m| current_map = m,
                    else => return error.PathConflict,
                }
            } else {
                try current_map.put(a, segment, .{ .map = .{} });
                current_map = &current_map.getPtr(segment).?.map;
            }
            segment = it.next().?;
        }

        try current_map.put(a, segment, value);
    }

    /// Sets an attribute (string key-value pair for included templates).
    pub fn setAttr(self: *Context, key: []const u8, value: []const u8) !void {
        try self.attrs.put(self.allocator(), key, value);
    }

    pub fn getAttr(self: *const Context, key: []const u8) ?[]const u8 {
        return self.attrs.get(key);
    }

    /// Sets a slot (pre-rendered content for slot filling).
    pub fn setSlot(self: *Context, key: []const u8, value: []const u8) !void {
        try self.slots.put(self.allocator(), key, value);
    }

    pub fn getSlot(self: *const Context, key: []const u8) ?[]const u8 {
        return self.slots.get(key);
    }

    pub fn hasSlot(self: *const Context, key: []const u8) bool {
        return self.slots.contains(key);
    }
};

/// Runtime-polymorphic template source provider. Fat-pointer pattern matching `std.mem.Allocator`.
/// Implementations: `Resolver.loader()` (in-memory map), `FileSystemLoader`, `ChainLoader`.
pub const Loader = struct {
    ptr: *const anyopaque,
    getSourceFn: *const fn (*const anyopaque, Allocator, []const u8) Allocator.Error!?[]const u8,

    /// Returns the template source for `name`, or null if not found.
    /// **Ownership:** The returned slice is allocated using `a` and owned by the caller.
    /// The caller must free it with `a.free(result)` when done (or let an arena handle it).
    pub fn getSource(self: Loader, a: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
        return self.getSourceFn(self.ptr, a, name);
    }
};

/// Maps template names to source strings. Used by `<t-include>` and `<t-extend>` at render time.
pub const Resolver = struct {
    templates: std.StringArrayHashMapUnmanaged([]const u8) = .{},

    pub fn put(self: *Resolver, a: Allocator, name: []const u8, content: []const u8) !void {
        try self.templates.put(a, name, content);
    }

    pub fn get(self: *const Resolver, name: []const u8) ?[]const u8 {
        return self.templates.get(name);
    }

    pub fn deinit(self: *Resolver, a: Allocator) void {
        self.templates.deinit(a);
    }

    /// Returns a `Loader` backed by this resolver's in-memory map.
    pub fn loader(self: *const Resolver) Loader {
        return .{
            .ptr = @ptrCast(self),
            .getSourceFn = resolverGetSource,
        };
    }

    fn resolverGetSource(ptr: *const anyopaque, a: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
        const self: *const Resolver = @ptrCast(@alignCast(ptr));
        const source = self.get(name) orelse return null;
        return try a.dupe(u8, source);
    }
};

/// Error set returned by rendering operations.
pub const RenderError = error{
    MalformedElement,
    TemplateNotFound,
    CircularReference,
    DuplicateSlotDefinition,
    UndefinedVariable,
    OutOfMemory,
};

const testing = std.testing;

test "Resolver.loader returns stored source" {
    var resolver: Resolver = .{};
    try resolver.put(testing.allocator, "page.html", "<p>hello</p>");
    defer resolver.deinit(testing.allocator);

    const l = resolver.loader();
    const source = (try l.getSource(testing.allocator, "page.html")).?;
    defer testing.allocator.free(source);
    try testing.expectEqualStrings("<p>hello</p>", source);
}

test "Resolver.loader returns null for missing template" {
    var resolver: Resolver = .{};
    const l = resolver.loader();
    const source = try l.getSource(testing.allocator, "missing.html");
    try testing.expect(source == null);
}

test "Resolver.loader returns owned copies" {
    var resolver: Resolver = .{};
    try resolver.put(testing.allocator, "x.html", "content");
    defer resolver.deinit(testing.allocator);

    const l = resolver.loader();
    const s1 = (try l.getSource(testing.allocator, "x.html")).?;
    defer testing.allocator.free(s1);
    const s2 = (try l.getSource(testing.allocator, "x.html")).?;
    defer testing.allocator.free(s2);
    try testing.expectEqualStrings(s1, s2);
    try testing.expect(s1.ptr != s2.ptr);
}

test "putAt simple key" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("title", .{ .string = "Hello" });
    try testing.expectEqualStrings("Hello", ctx.resolve("title").?.asString().?);
}

test "putAt two-level path" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("page.title", .{ .string = "My Page" });
    try testing.expectEqualStrings("My Page", ctx.resolve("page.title").?.asString().?);
}

test "putAt three-level path" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("page.meta.description", .{ .string = "A page" });
    try testing.expectEqualStrings("A page", ctx.resolve("page.meta.description").?.asString().?);
}

test "putAt intermediate map already exists" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("page.title", .{ .string = "Title" });
    try ctx.putAt("page.author", .{ .string = "QuiteClose" });
    try testing.expectEqualStrings("Title", ctx.resolve("page.title").?.asString().?);
    try testing.expectEqualStrings("QuiteClose", ctx.resolve("page.author").?.asString().?);
}

test "putAt intermediate key wrong type" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("page", .{ .string = "flat" });
    try testing.expectError(error.PathConflict, ctx.putAt("page.title", .{ .string = "nested" }));
}

test "putAt empty path is no-op" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("", .{ .string = "ignored" });
    try testing.expectEqual(@as(usize, 0), ctx.data.count());
}

test "putAt multiple puts to same parent" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("site.name", .{ .string = "My Site" });
    try ctx.putAt("site.url", .{ .string = "https://example.com" });
    try ctx.putAt("site.version", .{ .integer = 3 });
    try testing.expectEqualStrings("My Site", ctx.resolve("site.name").?.asString().?);
    try testing.expectEqualStrings("https://example.com", ctx.resolve("site.url").?.asString().?);
    try testing.expectEqual(@as(i64, 3), ctx.resolve("site.version").?.integer);
}

// -- Overwrite behaviour --

test "putAt overwrites existing top-level value" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("title", .{ .string = "First" });
    try ctx.putAt("title", .{ .string = "Second" });
    try testing.expectEqualStrings("Second", ctx.resolve("title").?.asString().?);
}

test "putAt overwrites existing leaf via path" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("page.title", .{ .string = "Draft" });
    try ctx.putAt("page.title", .{ .string = "Final" });
    try testing.expectEqualStrings("Final", ctx.resolve("page.title").?.asString().?);
}

test "putAt overwrite preserves siblings" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("page.title", .{ .string = "Title" });
    try ctx.putAt("page.draft", .{ .boolean = true });
    try ctx.putAt("page.title", .{ .string = "New Title" });
    try testing.expectEqualStrings("New Title", ctx.resolve("page.title").?.asString().?);
    try testing.expectEqual(true, ctx.resolve("page.draft").?.boolean);
}

// -- PathConflict with each non-map Value type --

test "putAt conflict with boolean intermediate" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("flag", .{ .boolean = true });
    try testing.expectError(error.PathConflict, ctx.putAt("flag.sub", .{ .string = "x" }));
}

test "putAt conflict with integer intermediate" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("count", .{ .integer = 42 });
    try testing.expectError(error.PathConflict, ctx.putAt("count.sub", .{ .string = "x" }));
}

test "putAt conflict with list intermediate" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("items", .{ .list = &.{} });
    try testing.expectError(error.PathConflict, ctx.putAt("items.sub", .{ .string = "x" }));
}

test "putAt conflict with nil intermediate" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("empty", .nil);
    try testing.expectError(error.PathConflict, ctx.putAt("empty.sub", .{ .string = "x" }));
}

test "putAt conflict at second intermediate" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("a.b", .{ .string = "leaf" });
    try testing.expectError(error.PathConflict, ctx.putAt("a.b.c", .{ .string = "x" }));
}

// -- All Value types as leaf values --

test "putAt leaf is boolean" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("page.draft", .{ .boolean = true });
    try testing.expectEqual(true, ctx.resolve("page.draft").?.boolean);
}

test "putAt leaf is integer" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("page.order", .{ .integer = 7 });
    try testing.expectEqual(@as(i64, 7), ctx.resolve("page.order").?.integer);
}

test "putAt leaf is list" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const items = &[_]Value{ .{ .string = "a" }, .{ .string = "b" } };
    try ctx.putAt("page.tags", .{ .list = items });
    const list = ctx.resolve("page.tags").?.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("a", list[0].asString().?);
    try testing.expectEqualStrings("b", list[1].asString().?);
}

test "putAt leaf is map" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var inner: V.Map = .{};
    try inner.put(ctx.allocator(), "x", .{ .string = "y" });
    try ctx.putAt("page.extra", .{ .map = inner });
    try testing.expectEqualStrings("y", ctx.resolve("page.extra.x").?.asString().?);
}

test "putAt leaf is nil" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("page.empty", .nil);
    try testing.expectEqual(Value.nil, ctx.resolve("page.empty").?);
}

// -- Interaction with put --

test "putAt navigates into map created by put" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var page: V.Map = .{};
    try page.put(ctx.allocator(), "existing", .{ .string = "keep" });
    try ctx.put("page", .{ .map = page });
    try ctx.putAt("page.added", .{ .string = "new" });
    try testing.expectEqualStrings("keep", ctx.resolve("page.existing").?.asString().?);
    try testing.expectEqualStrings("new", ctx.resolve("page.added").?.asString().?);
}

test "putAt into map created by put then extended by putAt" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var page: V.Map = .{};
    try page.put(ctx.allocator(), "title", .{ .string = "Original" });
    try ctx.put("page", .{ .map = page });
    try ctx.putAt("page.draft", .{ .boolean = true });
    try ctx.putAt("page.title", .{ .string = "Updated" });
    try testing.expectEqualStrings("Updated", ctx.resolve("page.title").?.asString().?);
    try testing.expectEqual(true, ctx.resolve("page.draft").?.boolean);
}

test "put overwrites subtree created by putAt" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("page.title", .{ .string = "Hello" });
    try ctx.putAt("page.meta.description", .{ .string = "A page" });
    try ctx.put("page", .{ .string = "flat" });
    try testing.expectEqualStrings("flat", ctx.resolve("page").?.asString().?);
}

// -- Deep nesting --

test "putAt five levels deep" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("a.b.c.d.e", .{ .string = "deep" });
    try testing.expectEqualStrings("deep", ctx.resolve("a.b.c.d.e").?.asString().?);
    try testing.expect(ctx.resolve("a").?.map.count() == 1);
    try testing.expect(ctx.resolve("a.b").?.map.count() == 1);
    try testing.expect(ctx.resolve("a.b.c").?.map.count() == 1);
    try testing.expect(ctx.resolve("a.b.c.d").?.map.count() == 1);
}

// -- Edge-case dot patterns --

test "putAt trailing dot creates empty-string leaf key" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("page.", .{ .string = "val" });
    const page_map = ctx.resolve("page").?.map;
    try testing.expectEqualStrings("val", page_map.get("").?.asString().?);
}

test "putAt leading dot creates empty-string intermediate" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt(".title", .{ .string = "val" });
    const empty_map = ctx.data.get("").?.map;
    try testing.expectEqualStrings("val", empty_map.get("title").?.asString().?);
}

test "putAt consecutive dots create empty-string intermediates" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt("a..b", .{ .string = "val" });
    const a_map = ctx.resolve("a").?.map;
    const empty_map = a_map.get("").?.map;
    try testing.expectEqualStrings("val", empty_map.get("b").?.asString().?);
}

test "putAt single dot creates two empty-string segments" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.putAt(".", .{ .string = "val" });
    const empty_map = ctx.data.get("").?.map;
    try testing.expectEqualStrings("val", empty_map.get("").?.asString().?);
}
