const std = @import("std");
const Allocator = std.mem.Allocator;

/// Data context for template rendering: variables (dot-path resolution) and slots.
pub const Context = @import("Context.zig").Context;
/// Tagged union for template values: string, boolean, integer, list, map, nil.
pub const Value = @import("Context.zig").Value;
/// Maps template names to source strings for `<t-include>` and `<t-extend>`.
pub const Resolver = @import("Context.zig").Resolver;
/// Runtime-polymorphic template source provider (fat-pointer pattern).
pub const Loader = @import("Context.zig").Loader;
/// Loads templates from a filesystem directory.
pub const FileSystemLoader = @import("FileSystemLoader.zig");
/// Tries multiple loaders in order, returning the first match.
pub const ChainLoader = @import("ChainLoader.zig");
/// Rich error context: line/column, source excerpt, template stack, typo suggestions.
pub const ErrorDetail = @import("Context.zig").ErrorDetail;
/// Resolved include entry for error reporting and debugging.
pub const IncludeEntry = @import("Context.zig").IncludeEntry;
/// Union of all render-time errors (undefined variable, template not found, etc.).
pub const RenderError = @import("Context.zig").RenderError;
/// Render options: template name, registry, strict mode, debug, max depth.
pub const Options = @import("Renderer.zig").Options;

/// Owned render output. `output` is allocated by the allocator passed to the render function.
/// Call `deinit` to free; the allocator is stored for that purpose.
pub const RenderResult = struct {
    output: []const u8,
    allocator: Allocator,

    /// Frees `output` using the stored allocator.
    pub fn deinit(self: RenderResult) void {
        self.allocator.free(self.output);
    }
};

/// IR node types: tagged union for template elements (var, raw, if, for, extend, include, etc.).
pub const Node = @import("Node.zig");
/// Parses template source into `[]Node` IR.
pub const Parser = @import("Parser.zig");
/// Renders `[]Node` IR against a context to produce output.
pub const Renderer = @import("Renderer.zig");

const format = @import("format.zig");
/// Transform registry and built-in transforms (upper, lower, truncate, etc.).
pub const transform = @import("transform.zig");
/// Validation diagnostic: template name, kind (err/warn), message.
pub const Diagnostic = @import("diagnostic.zig").Diagnostic;

/// Template engine with pre-parsed template cache and transform registry.
///
/// **Threading model -- two-phase usage:**
///
/// - **Setup phase** (mutable `*Engine`): call `addTemplate`, `removeTemplate`,
///   `clearTemplates`, `registerTransform`. These mutate `cache` and `registry`
///   and must not be called concurrently with rendering or with each other.
///
/// - **Serve phase** (immutable `*const Engine`): call `renderTemplate`,
///   `renderTemplateToWriter`, `renderTemplateFormatted`, `render`,
///   `renderToWriter`, `renderFormatted`, `renderFormattedToWriter`,
///   `validate`. These take `*const Engine` and only read from `cache` and
///   `registry`. They are safe to call concurrently from multiple threads
///   because each call allocates its own arena and passes State by value.
pub const Engine = struct {
    allocator: Allocator,
    registry: transform.Registry,
    cache: std.StringArrayHashMapUnmanaged(CacheEntry) = .{},

    const CacheEntry = struct {
        nodes: []const Node.Node,
        source: []const u8,
        arena: std.heap.ArenaAllocator,
    };

    /// Creates an engine with built-in transforms registered. Caller owns the returned engine.
    pub fn init(a: Allocator) !Engine {
        var reg: transform.Registry = .{};
        try reg.registerBuiltins(a);
        return .{ .allocator = a, .registry = reg };
    }

    /// Frees all cached templates and the transform registry.
    pub fn deinit(self: *Engine) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.source);
            entry.value_ptr.arena.deinit();
        }
        self.cache.deinit(self.allocator);
        self.registry.deinit(self.allocator);
    }

    /// Registers a custom transform. Setup-phase only; not thread-safe.
    pub fn registerTransform(self: *Engine, name: []const u8, func: transform.TransformFn) !void {
        try self.registry.register(self.allocator, name, func);
    }

    /// Parses `source` and caches the IR under `name`. Replaces existing entry if present.
    /// The engine dupes both `name` and `source`; callers need not keep them alive.
    /// Setup-phase only; not thread-safe.
    pub fn addTemplate(self: *Engine, name: []const u8, source: []const u8) !void {
        const duped_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(duped_name);
        const duped_source = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(duped_source);
        var result = try Parser.parse(self.allocator, duped_source, .{ .template_name = duped_name });
        errdefer result.deinit();
        const gop = try self.cache.getOrPut(self.allocator, duped_name);
        if (gop.found_existing) {
            self.allocator.free(gop.key_ptr.*);
            self.allocator.free(gop.value_ptr.source);
            gop.value_ptr.arena.deinit();
        }
        gop.key_ptr.* = duped_name;
        gop.value_ptr.* = .{ .nodes = result.nodes, .source = duped_source, .arena = result.arena };
    }

    /// Renders a cached template by name. Uses pre-parsed IR; no parse cost per call.
    /// Returns output owned by `a`; caller must free. Serve-phase; safe for concurrent use.
    pub fn renderTemplate(self: *const Engine, a: Allocator, name: []const u8, ctx: *const Context, loader: Loader, options: Options) RenderError![]const u8 {
        const entry = self.cache.get(name) orelse return error.TemplateNotFound;
        var opts = options;
        opts.registry = &self.registry;
        opts.template_name = name;
        opts.template_source = entry.source;
        return Renderer.render(a, entry.nodes, ctx, loader, opts);
    }

    /// Renders raw template source. Parses `input` on every call; use `renderTemplate` for cached templates.
    /// Returns output owned by `a`; caller must free. Serve-phase; safe for concurrent use.
    pub fn render(self: *const Engine, a: Allocator, input: []const u8, ctx: *const Context, loader: Loader, options: Options) RenderError![]const u8 {
        var opts = options;
        opts.registry = &self.registry;
        return renderImpl(a, input, ctx, loader, opts);
    }

    /// Like `render` but returns a `RenderResult`; call `result.deinit()` to free output.
    pub fn renderOwned(self: *const Engine, a: Allocator, input: []const u8, ctx: *const Context, loader: Loader, options: Options) RenderError!RenderResult {
        return .{ .output = try self.render(a, input, ctx, loader, options), .allocator = a };
    }

    /// Like `renderTemplate` but returns a `RenderResult`; call `result.deinit()` to free output.
    pub fn renderTemplateOwned(self: *const Engine, a: Allocator, name: []const u8, ctx: *const Context, loader: Loader, options: Options) RenderError!RenderResult {
        return .{ .output = try self.renderTemplate(a, name, ctx, loader, options), .allocator = a };
    }

    /// Renders raw source then applies pretty-print (re-indentation of existing newlines, no new ones inserted).
    /// Returns output owned by `a`; caller must free.
    pub fn renderFormatted(self: *const Engine, a: Allocator, input: []const u8, ctx: *const Context, loader: Loader, options: Options) (RenderError || error{OutOfMemory})![]const u8 {
        const raw = try self.render(a, input, ctx, loader, options);
        defer a.free(raw);
        return format.prettyPrint(a, raw);
    }

    /// Renders cached template then applies pretty-print (re-indentation of existing newlines, no new ones inserted).
    /// Returns output owned by `a`; caller must free.
    pub fn renderTemplateFormatted(self: *const Engine, a: Allocator, name: []const u8, ctx: *const Context, loader: Loader, options: Options) (RenderError || error{OutOfMemory})![]const u8 {
        const raw = try self.renderTemplate(a, name, ctx, loader, options);
        defer a.free(raw);
        return format.prettyPrint(a, raw);
    }

    /// Removes a template from the cache. No-op if not present. Setup-phase only; not thread-safe.
    pub fn removeTemplate(self: *Engine, name: []const u8) void {
        if (self.cache.fetchSwapRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.source);
            entry.value.arena.deinit();
        }
    }

    /// Empties the template cache. Setup-phase only; not thread-safe.
    pub fn clearTemplates(self: *Engine) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.source);
            entry.value_ptr.arena.deinit();
        }
        self.cache.clearRetainingCapacity();
    }

    /// Recursively scans `base_path` and loads all files matching `extension` into
    /// the template cache. Template names are paths relative to `base_path`
    /// (e.g. `"layouts/page.html"`). Files are loaded in sorted order for
    /// deterministic results. Setup-phase only; not thread-safe.
    pub fn loadFromDirectory(self: *Engine, base_path: []const u8, extension: []const u8) !void {
        var dir = try std.fs.cwd().openDir(base_path, .{ .iterate = true });
        defer dir.close();

        var paths: std.ArrayListUnmanaged([]const u8) = .{};
        defer {
            for (paths.items) |p| self.allocator.free(p);
            paths.deinit(self.allocator);
        }

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, extension)) continue;
            try paths.append(self.allocator, try self.allocator.dupe(u8, entry.path));
        }

        std.mem.sortUnstable([]const u8, paths.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (paths.items) |rel_path| {
            const contents = try dir.readFileAlloc(self.allocator, rel_path, FileSystemLoader.max_template_size);
            defer self.allocator.free(contents);
            try self.addTemplate(rel_path, contents);
        }
    }

    /// Renders a cached template, streaming output to `writer` as each top-level node completes.
    /// If the writer fails mid-write, partial output may have been written.
    /// Use a buffered writer if atomicity is needed.
    pub fn renderTemplateToWriter(self: *const Engine, a: Allocator, name: []const u8, ctx: *const Context, loader: Loader, options: Options, writer: anytype) !void {
        const entry = self.cache.get(name) orelse return error.TemplateNotFound;
        var opts = options;
        opts.registry = &self.registry;
        opts.template_name = name;
        opts.template_source = entry.source;
        try Renderer.renderToWriter(a, entry.nodes, ctx, loader, opts, writer);
    }

    /// Renders raw template source, streaming output to `writer` as each top-level node completes.
    /// If the writer fails mid-write, partial output may have been written.
    /// Use a buffered writer if atomicity is needed.
    pub fn renderToWriter(self: *const Engine, a: Allocator, input: []const u8, ctx: *const Context, loader: Loader, options: Options, writer: anytype) !void {
        var opts = options;
        opts.registry = &self.registry;
        try renderImplToWriter(a, input, ctx, loader, opts, writer);
    }

    /// Renders raw template source with pretty-printing and writes to `writer`.
    /// If the writer fails mid-write, partial output may have been written.
    /// Use a buffered writer if atomicity is needed.
    pub fn renderFormattedToWriter(self: *const Engine, a: Allocator, input: []const u8, ctx: *const Context, loader: Loader, options: Options, writer: anytype) !void {
        const result = try self.renderFormatted(a, input, ctx, loader, options);
        defer a.free(result);
        try writer.writeAll(result);
    }

    /// Walks cached template IR and reports problems (missing includes/extends, circular extend chains).
    /// Checks both engine cache and loader. Call after loading all templates and before serving.
    /// Returns diagnostics owned by `a`; caller must free.
    pub fn validate(self: *const Engine, a: Allocator, loader: Loader) ![]const Diagnostic {
        var diags: std.ArrayListUnmanaged(Diagnostic) = .{};
        errdefer diags.deinit(a);

        var cache_it = self.cache.iterator();
        while (cache_it.next()) |entry| {
            const tmpl_name = entry.key_ptr.*;
            const nodes = entry.value_ptr.nodes;
            try collectDiagnostics(a, tmpl_name, nodes, self, loader, &diags);
        }

        return diags.toOwnedSlice(a);
    }

    fn collectDiagnostics(
        a: Allocator,
        tmpl_name: []const u8,
        nodes: []const Node.Node,
        engine: *const Engine,
        loader: Loader,
        diags: *std.ArrayListUnmanaged(Diagnostic),
    ) !void {
        for (nodes) |node| {
            switch (node) {
                .include => |inc| {
                    if (engine.cache.get(inc.template) == null and (try loader.getSource(a, inc.template)) == null) {
                        try diags.append(a, .{
                            .template = tmpl_name,
                            .kind = .err,
                            .message = inc.template,
                        });
                    }
                    try collectDiagnostics(a, tmpl_name, inc.anonymous_body, engine, loader, diags);
                    for (inc.defines) |def| try collectDiagnostics(a, tmpl_name, def.body, engine, loader, diags);
                },
                .extend => |ext| {
                    if (engine.cache.get(ext.template) == null and (try loader.getSource(a, ext.template)) == null) {
                        try diags.append(a, .{
                            .template = tmpl_name,
                            .kind = .err,
                            .message = ext.template,
                        });
                    }
                    for (ext.defines) |def| try collectDiagnostics(a, tmpl_name, def.body, engine, loader, diags);
                },
                .conditional => |cond| {
                    for (cond.branches) |branch| try collectDiagnostics(a, tmpl_name, branch.body, engine, loader, diags);
                    try collectDiagnostics(a, tmpl_name, cond.else_body, engine, loader, diags);
                },
                .loop => |loop| {
                    try collectDiagnostics(a, tmpl_name, loop.body, engine, loader, diags);
                    try collectDiagnostics(a, tmpl_name, loop.else_body, engine, loader, diags);
                },
                .slot => |slot| try collectDiagnostics(a, tmpl_name, slot.default_body, engine, loader, diags),
                .variable => |v| try collectDiagnostics(a, tmpl_name, v.default_body, engine, loader, diags),
                .raw_variable => |v| try collectDiagnostics(a, tmpl_name, v.default_body, engine, loader, diags),
                .let_binding => |lb| try collectDiagnostics(a, tmpl_name, lb.body, engine, loader, diags),
                else => {},
            }
        }
    }
};

/// Validates template source at compile time. Produces a `@compileError` for
/// malformed templates: unknown element names, unclosed block elements, and
/// missing required attributes. Validation only -- does not build IR.
///
/// Shares element name and attribute rules with the runtime parser.
///
/// ```zig
/// const page = comptime blk: {
///     const src = @embedFile("templates/page.html");
///     validateTemplate(src);
///     break :blk src;
/// };
/// ```
pub fn validateTemplate(comptime source: []const u8) void {
    comptime {
        @setEvalBranchQuota(@max(source.len * 100, 10000));
        var depth: usize = 0;
        var stack: [64][]const u8 = undefined;
        var i: usize = 0;
        while (i < source.len) {
            if (source[i] != '<') {
                i += 1;
                continue;
            }
            if (i + 3 < source.len and source[i + 1] == '/' and source[i + 2] == 't' and source[i + 3] == '-') {
                const close_start = i + 4;
                var close_end = close_start;
                while (close_end < source.len and source[close_end] != '>') : (close_end += 1) {}
                if (close_end >= source.len) @compileError("unclosed closing tag");
                const close_name = source[close_start..close_end];
                if (!isValidElement(close_name)) @compileError("unknown element: t-" ++ close_name);
                if (depth == 0) @compileError("unexpected closing tag: </t-" ++ close_name ++ ">");
                const expected = stack[depth - 1];
                if (!std.mem.eql(u8, close_name, expected))
                    @compileError("mismatched closing tag: expected </t-" ++ expected ++ ">, found </t-" ++ close_name ++ ">");
                depth -= 1;
                i = close_end + 1;
                continue;
            }
            if (i + 2 < source.len and source[i + 1] == 't' and source[i + 2] == '-') {
                const name_start = i + 3;
                var name_end = name_start;
                while (name_end < source.len and source[name_end] != ' ' and source[name_end] != '>' and source[name_end] != '/') : (name_end += 1) {}
                if (name_end == name_start) {
                    i += 1;
                    continue;
                }
                const elem_name = source[name_start..name_end];
                if (!isValidElement(elem_name)) @compileError("unknown element: t-" ++ elem_name);
                var tag_end = name_end;
                while (tag_end < source.len and source[tag_end] != '>') : (tag_end += 1) {}
                if (tag_end >= source.len) @compileError("unclosed tag: <t-" ++ elem_name);
                const is_self_closing = source[tag_end - 1] == '/';
                const tag_content = source[i..tag_end + 1];
                if (requiresName(elem_name) and !comptimeContainsAttr(tag_content, "name") and !comptimeContainsAttr(tag_content, "slot")) {
                    @compileError("missing 'name' attribute on <t-" ++ elem_name ++ ">");
                }
                if (requiresTemplate(elem_name) and !comptimeContainsAttr(tag_content, "template")) {
                    @compileError("missing 'template' attribute on <t-" ++ elem_name ++ ">");
                }
                if (!is_self_closing and isBlockElement(elem_name)) {
                    if (depth >= 64) @compileError("template nesting too deep (>64 levels)");
                    stack[depth] = elem_name;
                    depth += 1;
                }
                i = tag_end + 1;
                continue;
            }
            i += 1;
        }
        if (depth > 0) @compileError("unclosed element: <t-" ++ stack[depth - 1] ++ ">");
    }
}

fn isValidElement(comptime name: []const u8) bool {
    inline for (Parser.valid_element_names) |valid| {
        if (comptime std.mem.eql(u8, name, valid)) return true;
    }
    return false;
}

fn isBlockElement(comptime name: []const u8) bool {
    inline for (Parser.block_elements) |block| {
        if (comptime std.mem.eql(u8, name, block)) return true;
    }
    return false;
}

fn requiresName(comptime name: []const u8) bool {
    inline for (Parser.name_required) |req| {
        if (comptime std.mem.eql(u8, name, req)) return true;
    }
    return false;
}

fn requiresTemplate(comptime name: []const u8) bool {
    inline for (Parser.template_required) |req| {
        if (comptime std.mem.eql(u8, name, req)) return true;
    }
    return false;
}

fn comptimeContainsAttr(comptime tag: []const u8, comptime attr: []const u8) bool {
    const needle = attr ++ "=";
    var i: usize = 0;
    while (i + needle.len <= tag.len) : (i += 1) {
        if (comptime std.mem.eql(u8, tag[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// One-shot render: parses `input` each time, creates a temporary transform registry.
/// Output is owned by the allocator `a`.
pub fn render(a: Allocator, input: []const u8, ctx: *const Context, loader: Loader, options: Options) RenderError![]const u8 {
    if (options.registry != null) return renderImpl(a, input, ctx, loader, options);
    var reg: transform.Registry = .{};
    try reg.registerBuiltins(a);
    defer reg.deinit(a);
    var opts = options;
    opts.registry = &reg;
    return renderImpl(a, input, ctx, loader, opts);
}

/// One-shot streaming render: parses `input`, then writes output to `writer` node-by-node.
/// Creates a temporary transform registry each call. Output is not buffered in full.
pub fn renderToWriter(a: Allocator, input: []const u8, ctx: *const Context, loader: Loader, options: Options, writer: anytype) !void {
    if (options.registry != null) return renderImplToWriter(a, input, ctx, loader, options, writer);
    var reg: transform.Registry = .{};
    try reg.registerBuiltins(a);
    defer reg.deinit(a);
    var opts = options;
    opts.registry = &reg;
    return renderImplToWriter(a, input, ctx, loader, opts, writer);
}

/// One-shot render with pretty-print (re-indentation of existing newlines, no new ones inserted).
/// Returns output owned by `a`; caller must free.
pub fn renderFormatted(a: Allocator, input: []const u8, ctx: *const Context, loader: Loader, options: Options) (RenderError || error{OutOfMemory})![]const u8 {
    const raw = try render(a, input, ctx, loader, options);
    defer a.free(raw);
    return format.prettyPrint(a, raw);
}

fn renderImpl(a: Allocator, input: []const u8, ctx: *const Context, loader: Loader, options: Options) RenderError![]const u8 {
    var parse_result = try Parser.parse(a, input, .{
        .err_detail = ctx.err_detail,
        .template_name = options.template_name,
    });
    defer parse_result.deinit();
    var opts = options;
    if (opts.template_source.len == 0) opts.template_source = input;
    return Renderer.render(a, parse_result.nodes, ctx, loader, opts);
}

fn renderImplToWriter(a: Allocator, input: []const u8, ctx: *const Context, loader: Loader, options: Options, writer: anytype) !void {
    var parse_result = try Parser.parse(a, input, .{
        .err_detail = ctx.err_detail,
        .template_name = options.template_name,
    });
    defer parse_result.deinit();
    var opts = options;
    if (opts.template_source.len == 0) opts.template_source = input;
    try Renderer.renderToWriter(a, parse_result.nodes, ctx, loader, opts, writer);
}

// ---- Tests ----

const testing = std.testing;

test "engine render raw source" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("name", .{ .string = "world" });
    var resolver: Resolver = .{};
    const result = try engine.render(testing.allocator, "Hello <t-var name=\"name\" />!", &ctx, resolver.loader(), .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello world!", result);
}

test "engine addTemplate and renderTemplate" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("greeting.html", "Hello <t-var name=\"name\" />!");

    var ctx1 = Context.init(testing.allocator);
    defer ctx1.deinit();
    try ctx1.put("name", .{ .string = "Alice" });
    var resolver: Resolver = .{};
    const r1 = try engine.renderTemplate(testing.allocator, "greeting.html", &ctx1, resolver.loader(), .{});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("Hello Alice!", r1);

    var ctx2 = Context.init(testing.allocator);
    defer ctx2.deinit();
    try ctx2.put("name", .{ .string = "Bob" });
    const r2 = try engine.renderTemplate(testing.allocator, "greeting.html", &ctx2, resolver.loader(), .{});
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("Hello Bob!", r2);
}

test "engine renderTemplate not found" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const result = engine.renderTemplate(testing.allocator, "missing.html", &ctx, resolver.loader(), .{});
    try testing.expectError(error.TemplateNotFound, result);
}

test "engine custom transform via registry" {
    const reverse = struct {
        fn call(a: Allocator, value: []const u8, _: []const []const u8) RenderError![]u8 {
            const buf = try a.alloc(u8, value.len);
            for (buf, 0..) |*b, i| b.* = value[value.len - 1 - i];
            return buf;
        }
    }.call;

    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.registerTransform("reverse", reverse);
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("msg", .{ .string = "abc" });
    var resolver: Resolver = .{};
    const result = try engine.render(testing.allocator, "<t-var name=\"msg\" transform=\"reverse\" />", &ctx, resolver.loader(), .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("cba", result);
}

test "engine renderOwned returns RenderResult" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("x", .{ .string = "42" });
    var resolver: Resolver = .{};
    const result = try engine.renderOwned(testing.allocator, "<t-var name=\"x\" />", &ctx, resolver.loader(), .{});
    defer result.deinit();
    try testing.expectEqualStrings("42", result.output);
}

test "engine renderTemplateFormatted" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("frag.html", "<div>\n<p>hello</p>\n</div>");
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const result = try engine.renderTemplateFormatted(testing.allocator, "frag.html", &ctx, resolver.loader(), .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("<div>\n  <p>hello</p>\n</div>", result);
}

test "engine removeTemplate" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("tmp.html", "hello");
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const r1 = try engine.renderTemplate(testing.allocator, "tmp.html", &ctx, resolver.loader(), .{});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("hello", r1);

    engine.removeTemplate("tmp.html");
    try testing.expectError(error.TemplateNotFound, engine.renderTemplate(testing.allocator, "tmp.html", &ctx, resolver.loader(), .{}));
}

test "engine removeTemplate non-existent is no-op" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    engine.removeTemplate("ghost.html");
}

test "engine removeTemplate then re-add" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("page.html", "v1");
    engine.removeTemplate("page.html");
    try engine.addTemplate("page.html", "v2");
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const result = try engine.renderTemplate(testing.allocator, "page.html", &ctx, resolver.loader(), .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("v2", result);
}

test "engine clearTemplates" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("a.html", "A");
    try engine.addTemplate("b.html", "B");
    engine.clearTemplates();
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    try testing.expectError(error.TemplateNotFound, engine.renderTemplate(testing.allocator, "a.html", &ctx, resolver.loader(), .{}));
    try testing.expectError(error.TemplateNotFound, engine.renderTemplate(testing.allocator, "b.html", &ctx, resolver.loader(), .{}));
}

test "engine HTMX fragment pattern" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("user-status.html", "<div id=\"status\"><t-var name=\"name\" /> is <t-var name=\"status\" /></div>");
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("name", .{ .string = "Alice" });
    try ctx.put("status", .{ .string = "online" });
    var resolver: Resolver = .{};
    const result = try engine.renderTemplate(testing.allocator, "user-status.html", &ctx, resolver.loader(), .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("<div id=\"status\">Alice is online</div>", result);
}

test "engine renderTemplateToWriter equivalence" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("greet.html", "Hello <t-var name=\"name\" />!");
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("name", .{ .string = "World" });
    var resolver: Resolver = .{};

    const buffered = try engine.renderTemplate(testing.allocator, "greet.html", &ctx, resolver.loader(), .{});
    defer testing.allocator.free(buffered);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);
    try engine.renderTemplateToWriter(testing.allocator, "greet.html", &ctx, resolver.loader(), .{}, out.writer(testing.allocator));
    try testing.expectEqualStrings(buffered, out.items);
}

test "engine renderToWriter equivalence" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    const source = "Hi <t-var name=\"x\" />";
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("x", .{ .string = "42" });
    var resolver: Resolver = .{};

    const buffered = try engine.render(testing.allocator, source, &ctx, resolver.loader(), .{});
    defer testing.allocator.free(buffered);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);
    try engine.renderToWriter(testing.allocator, source, &ctx, resolver.loader(), .{}, out.writer(testing.allocator));
    try testing.expectEqualStrings(buffered, out.items);
}

test "engine renderFormattedToWriter equivalence" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    const source = "<div>\n<p>hi</p>\n</div>";
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};

    const buffered = try engine.renderFormatted(testing.allocator, source, &ctx, resolver.loader(), .{});
    defer testing.allocator.free(buffered);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);
    try engine.renderFormattedToWriter(testing.allocator, source, &ctx, resolver.loader(), .{}, out.writer(testing.allocator));
    try testing.expectEqualStrings(buffered, out.items);
}

test "engine validate catches missing include" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("page.html", "<t-include template=\"missing.html\" />");
    var resolver: Resolver = .{};
    const diags = try engine.validate(testing.allocator, resolver.loader());
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("missing.html", diags[0].message);
    try testing.expectEqualStrings("page.html", diags[0].template);
    try testing.expect(diags[0].kind == .err);
}

test "engine validate catches missing extend" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("child.html", "<t-extend template=\"ghost.html\"><t-define slot=\"main\">hi</t-define></t-extend>");
    var resolver: Resolver = .{};
    const diags = try engine.validate(testing.allocator, resolver.loader());
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("ghost.html", diags[0].message);
}

test "engine validate passes when templates exist in cache" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("base.html", "<t-slot name=\"main\" />");
    try engine.addTemplate("page.html", "<t-extend template=\"base.html\"><t-define slot=\"main\">content</t-define></t-extend>");
    var resolver: Resolver = .{};
    const diags = try engine.validate(testing.allocator, resolver.loader());
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "engine validate passes when templates exist in resolver" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("page.html", "<t-include template=\"nav.html\" />");
    var resolver: Resolver = .{};
    try resolver.put(testing.allocator, "nav.html", "<nav>links</nav>");
    defer resolver.deinit(testing.allocator);
    const diags = try engine.validate(testing.allocator, resolver.loader());
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "engine validate finds nested missing include" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("page.html", "<t-if var=\"show\"><t-include template=\"deep.html\" /></t-if>");
    var resolver: Resolver = .{};
    const diags = try engine.validate(testing.allocator, resolver.loader());
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("deep.html", diags[0].message);
}

test "engine validate empty cache returns no diagnostics" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    var resolver: Resolver = .{};
    const diags = try engine.validate(testing.allocator, resolver.loader());
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "engine addTemplate replaces existing" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.addTemplate("page.html", "v1");
    try engine.addTemplate("page.html", "v2");
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const result = try engine.renderTemplate(testing.allocator, "page.html", &ctx, resolver.loader(), .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("v2", result);
}

test "comptime validateTemplate accepts valid templates" {
    comptime {
        validateTemplate("<t-var name=\"x\" />");
        validateTemplate("<t-var name=\"x\">default</t-var>");
        validateTemplate("<t-if var=\"x\"><t-var name=\"y\" /></t-if>");
        validateTemplate("<t-for item in items><t-var name=\"item\" /></t-for>");
        validateTemplate("<t-include template=\"card.html\" />");
        validateTemplate("<t-extend template=\"base.html\"><t-define name=\"main\">content</t-define></t-extend>");
        validateTemplate("<t-comment>ignored</t-comment>");
        validateTemplate("<t-let name=\"x\">captured</t-let>");
        validateTemplate("plain text with no elements");
        validateTemplate("");
    }
}

test "engine loadFromDirectory loads matching files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(.{ .sub_path = "header.html", .data = "<header>H</header>" }) catch unreachable;
    tmp.dir.writeFile(.{ .sub_path = "footer.html", .data = "<footer>F</footer>" }) catch unreachable;
    tmp.dir.writeFile(.{ .sub_path = "nav.html", .data = "<nav>N</nav>" }) catch unreachable;

    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);

    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.loadFromDirectory(path, ".html");

    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const r1 = try engine.renderTemplate(testing.allocator, "header.html", &ctx, resolver.loader(), .{});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("<header>H</header>", r1);

    const r2 = try engine.renderTemplate(testing.allocator, "footer.html", &ctx, resolver.loader(), .{});
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("<footer>F</footer>", r2);

    const r3 = try engine.renderTemplate(testing.allocator, "nav.html", &ctx, resolver.loader(), .{});
    defer testing.allocator.free(r3);
    try testing.expectEqualStrings("<nav>N</nav>", r3);
}

test "engine loadFromDirectory filters by extension" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(.{ .sub_path = "page.html", .data = "<p>yes</p>" }) catch unreachable;
    tmp.dir.writeFile(.{ .sub_path = "style.css", .data = "body {}" }) catch unreachable;
    tmp.dir.writeFile(.{ .sub_path = "data.json", .data = "{}" }) catch unreachable;

    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);

    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.loadFromDirectory(path, ".html");

    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};
    const r = try engine.renderTemplate(testing.allocator, "page.html", &ctx, resolver.loader(), .{});
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("<p>yes</p>", r);

    try testing.expectError(error.TemplateNotFound, engine.renderTemplate(testing.allocator, "style.css", &ctx, resolver.loader(), .{}));
    try testing.expectError(error.TemplateNotFound, engine.renderTemplate(testing.allocator, "data.json", &ctx, resolver.loader(), .{}));
}

test "engine loadFromDirectory nested subdirectories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.makePath("layouts/default") catch unreachable;
    tmp.dir.writeFile(.{ .sub_path = "layouts/base.html", .data = "base" }) catch unreachable;
    tmp.dir.writeFile(.{ .sub_path = "layouts/default/page.html", .data = "page" }) catch unreachable;

    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);

    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.loadFromDirectory(path, ".html");

    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var resolver: Resolver = .{};

    const r1 = try engine.renderTemplate(testing.allocator, "layouts/base.html", &ctx, resolver.loader(), .{});
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("base", r1);

    const r2 = try engine.renderTemplate(testing.allocator, "layouts/default/page.html", &ctx, resolver.loader(), .{});
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("page", r2);
}

test "engine loadFromDirectory empty directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);

    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    try engine.loadFromDirectory(path, ".html");

    try testing.expectEqual(@as(usize, 0), engine.cache.count());
}

test "engine loadFromDirectory non-existent directory" {
    var engine = try Engine.init(testing.allocator);
    defer engine.deinit();
    const result = engine.loadFromDirectory("/tmp/toupee-nonexistent-dir-test", ".html");
    try testing.expect(std.meta.isError(result));
}

test {
    _ = @import("test_runner.zig");
    _ = @import("indent.zig");
    _ = @import("format.zig");
    _ = @import("Context.zig");
    _ = @import("Node.zig");
    _ = @import("Parser.zig");
    _ = @import("Renderer.zig");
    _ = @import("Value.zig");
    _ = @import("transform.zig");
    _ = @import("FileSystemLoader.zig");
    _ = @import("ChainLoader.zig");
    _ = @import("fuzz.zig");
    _ = @import("bench.zig");
}
