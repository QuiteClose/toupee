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
/// and pass a pointer via `ctx.err_detail`. Fields are only valid after a render or parse error.
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

    pub const Kind = enum {
        none,
        undefined_variable,
        template_not_found,
        circular_reference,
        malformed_element,
        duplicate_slot,
    };

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

/// Render context holding data, attributes, slots, and optional error detail. `data` is caller-owned;
/// the Renderer copies data on entry to child contexts, so the original is safe to reuse across render calls.
pub const Context = struct {
    /// Nested variable tree. Caller populates; Renderer copies for child contexts.
    data: V.Map = .{},
    attrs: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    slots: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    /// If non-null, populated on render/parse error. Caller allocates and passes; fields valid only after error.
    err_detail: ?*ErrorDetail = null,

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

    pub fn putData(self: *Context, a: Allocator, key: []const u8, value: Value) !void {
        try self.data.put(a, key, value);
    }

    pub fn putAttr(self: *Context, a: Allocator, key: []const u8, value: []const u8) !void {
        try self.attrs.put(a, key, value);
    }

    pub fn getAttr(self: *const Context, key: []const u8) ?[]const u8 {
        return self.attrs.get(key);
    }

    pub fn putSlot(self: *Context, a: Allocator, key: []const u8, value: []const u8) !void {
        try self.slots.put(a, key, value);
    }

    pub fn getSlot(self: *const Context, key: []const u8) ?[]const u8 {
        return self.slots.get(key);
    }

    pub fn hasSlot(self: *const Context, key: []const u8) bool {
        return self.slots.contains(key);
    }

    pub fn deinit(self: *Context, a: Allocator) void {
        self.data.deinit(a);
        self.attrs.deinit(a);
        self.slots.deinit(a);
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
