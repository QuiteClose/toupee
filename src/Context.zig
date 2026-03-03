const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    values: std.StringArrayHashMapUnmanaged([]const u8) = .{},

    pub fn get(self: *const Entry, key: []const u8) ?[]const u8 {
        return self.values.get(key);
    }
};

pub const ErrorDetail = struct {
    line: usize = 0,
    column: usize = 0,
    source_file: []const u8 = "",
    message: []const u8 = "",
};

pub const Context = struct {
    vars: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    attrs: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    slots: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    collections: std.StringArrayHashMapUnmanaged([]const Entry) = .{},
    err_detail: ?*ErrorDetail = null,

    pub fn putVar(self: *Context, a: Allocator, key: []const u8, value: []const u8) !void {
        try self.vars.put(a, key, value);
    }

    pub fn getVar(self: *const Context, key: []const u8) ?[]const u8 {
        return self.vars.get(key);
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

    pub fn putCollection(self: *Context, a: Allocator, name: []const u8, entries: []const Entry) !void {
        try self.collections.put(a, name, entries);
    }

    pub fn getCollection(self: *const Context, name: []const u8) ?[]const Entry {
        return self.collections.get(name);
    }

    pub fn deinit(self: *Context, a: Allocator) void {
        self.vars.deinit(a);
        self.attrs.deinit(a);
        self.slots.deinit(a);
        self.collections.deinit(a);
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

/// Errors that can occur during template rendering.
pub const RenderError = error{
    MalformedElement,
    TemplateNotFound,
    CircularReference,
    DuplicateSlotDefinition,
    UndefinedVariable,
    OutOfMemory,
};
