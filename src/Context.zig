const std = @import("std");
const Allocator = std.mem.Allocator;
const V = @import("Value.zig");

pub const Value = V.Value;

pub const ErrorDetail = struct {
    line: usize = 0,
    column: usize = 0,
    source_file: []const u8 = "",
    message: []const u8 = "",
};

pub const Context = struct {
    data: V.Map = .{},
    attrs: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    slots: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    err_detail: ?*ErrorDetail = null,

    pub fn resolve(self: *const Context, path: []const u8) ?Value {
        const root: Value = .{ .map = self.data };
        return root.resolve(path);
    }

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

pub const RenderError = error{
    MalformedElement,
    TemplateNotFound,
    CircularReference,
    DuplicateSlotDefinition,
    UndefinedVariable,
    OutOfMemory,
};
