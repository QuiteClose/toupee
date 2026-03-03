const std = @import("std");

pub const Node = union(enum) {
    text: []const u8,
    variable: Variable,
    raw_variable: Variable,
    let_binding: LetBinding,
    comment,
    slot: Slot,
    include: Include,
    extend: Extend,
    conditional: Conditional,
    loop: Loop,
    bound_tag: BoundTag,
    attr_output: AttrOutput,
};

pub const Variable = struct {
    name: []const u8,
    transform: []const TransformStep = &.{},
    default_body: []const Node = &.{},
    has_body: bool = false,
};

pub const LetBinding = struct {
    name: []const u8,
    transform: []const TransformStep = &.{},
    body: []const Node,
};

pub const AttrOutput = struct {
    name: []const u8,
};

pub const Slot = struct {
    name: []const u8,
    default_body: []const Node = &.{},
};

pub const Include = struct {
    template: []const u8,
    attrs: []const Attr = &.{},
    defines: []const Define = &.{},
    anonymous_body: []const Node = &.{},
    anonymous_body_source: []const u8 = "",
};

pub const Extend = struct {
    template: []const u8,
    defines: []const Define = &.{},
};

pub const Conditional = struct {
    branches: []const Branch,
    else_body: []const Node = &.{},
};

pub const Branch = struct {
    condition: Condition,
    body: []const Node,
};

pub const Condition = struct {
    source: Source,
    name: []const u8,
    comparison: Comparison = .exists,

    pub const Source = enum { variable, attr, slot };

    pub const Comparison = union(enum) {
        exists,
        not_exists,
        equals: []const u8,
        not_equals: []const u8,
    };
};

pub const Loop = struct {
    item_prefix: []const u8,
    collection: []const u8,
    alias: ?[]const u8 = null,
    sort_field: ?[]const u8 = null,
    order_desc: bool = false,
    limit: ?usize = null,
    offset: ?usize = null,
    body: []const Node,
};

pub const BoundTag = struct {
    segments: []const Segment,
};

pub const Segment = union(enum) {
    literal: []const u8,
    binding: Binding,
};

pub const Binding = struct {
    html_attr: []const u8,
    ref_name: []const u8,
    is_var: bool,
};

pub const TransformStep = struct {
    name: []const u8,
    args: []const []const u8 = &.{},
};

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Define = struct {
    name: []const u8,
    body: []const Node,
    raw_source: []const u8 = "",
};

test "text node" {
    const node: Node = .{ .text = "hello" };
    try std.testing.expectEqualStrings("hello", node.text);
}

test "variable node with defaults" {
    const node: Node = .{ .variable = .{ .name = "title" } };
    try std.testing.expectEqualStrings("title", node.variable.name);
    try std.testing.expectEqual(@as(usize, 0), node.variable.transform.len);
    try std.testing.expectEqual(@as(usize, 0), node.variable.default_body.len);
}

test "raw_variable node" {
    const node: Node = .{ .raw_variable = .{ .name = "content" } };
    try std.testing.expectEqualStrings("content", node.raw_variable.name);
}

test "variable with transform steps" {
    const steps = [_]TransformStep{
        .{ .name = "upper" },
        .{ .name = "truncate", .args = &.{"10"} },
    };
    const node: Node = .{ .variable = .{
        .name = "title",
        .transform = &steps,
    } };
    try std.testing.expectEqual(@as(usize, 2), node.variable.transform.len);
    try std.testing.expectEqualStrings("upper", node.variable.transform[0].name);
    try std.testing.expectEqualStrings("truncate", node.variable.transform[1].name);
    try std.testing.expectEqualStrings("10", node.variable.transform[1].args[0]);
}

test "variable with default body" {
    const default_nodes = [_]Node{.{ .text = "Untitled" }};
    const node: Node = .{ .variable = .{
        .name = "title",
        .default_body = &default_nodes,
    } };
    try std.testing.expectEqual(@as(usize, 1), node.variable.default_body.len);
    try std.testing.expectEqualStrings("Untitled", node.variable.default_body[0].text);
}

test "let_binding node" {
    const body = [_]Node{.{ .text = "captured" }};
    const node: Node = .{ .let_binding = .{
        .name = "snippet",
        .body = &body,
    } };
    try std.testing.expectEqualStrings("snippet", node.let_binding.name);
    try std.testing.expectEqual(@as(usize, 1), node.let_binding.body.len);
}

test "comment node" {
    const node: Node = .comment;
    try std.testing.expect(node == .comment);
}

test "attr_output node" {
    const node: Node = .{ .attr_output = .{ .name = "href" } };
    try std.testing.expectEqualStrings("href", node.attr_output.name);
}

test "slot node with default body" {
    const default_nodes = [_]Node{.{ .text = "default content" }};
    const node: Node = .{ .slot = .{
        .name = "main",
        .default_body = &default_nodes,
    } };
    try std.testing.expectEqualStrings("main", node.slot.name);
    try std.testing.expectEqual(@as(usize, 1), node.slot.default_body.len);
}

test "include node with attrs and defines" {
    const define_body = [_]Node{.{ .text = "slot content" }};
    const defines = [_]Define{.{ .name = "header", .body = &define_body }};
    const attrs = [_]Attr{.{ .name = "class", .value = "wide" }};
    const node: Node = .{ .include = .{
        .template = "card.html",
        .attrs = &attrs,
        .defines = &defines,
    } };
    try std.testing.expectEqualStrings("card.html", node.include.template);
    try std.testing.expectEqual(@as(usize, 1), node.include.attrs.len);
    try std.testing.expectEqual(@as(usize, 1), node.include.defines.len);
    try std.testing.expectEqualStrings("header", node.include.defines[0].name);
}

test "extend node" {
    const node: Node = .{ .extend = .{ .template = "base.html" } };
    try std.testing.expectEqualStrings("base.html", node.extend.template);
    try std.testing.expectEqual(@as(usize, 0), node.extend.defines.len);
}

test "conditional with branches and else" {
    const if_body = [_]Node{.{ .text = "yes" }};
    const else_body = [_]Node{.{ .text = "no" }};
    const branches = [_]Branch{.{
        .condition = .{
            .source = .variable,
            .name = "show",
        },
        .body = &if_body,
    }};
    const node: Node = .{ .conditional = .{
        .branches = &branches,
        .else_body = &else_body,
    } };
    try std.testing.expectEqual(@as(usize, 1), node.conditional.branches.len);
    try std.testing.expectEqual(Condition.Source.variable, node.conditional.branches[0].condition.source);
    try std.testing.expectEqual(@as(usize, 1), node.conditional.else_body.len);
}

test "conditional with equals comparison" {
    const body = [_]Node{.{ .text = "matched" }};
    const branches = [_]Branch{.{
        .condition = .{
            .source = .variable,
            .name = "theme",
            .comparison = .{ .equals = "dark" },
        },
        .body = &body,
    }};
    const node: Node = .{ .conditional = .{ .branches = &branches } };
    switch (node.conditional.branches[0].condition.comparison) {
        .equals => |v| try std.testing.expectEqualStrings("dark", v),
        else => return error.TestUnexpectedResult,
    }
}

test "loop node with all optional fields" {
    const body = [_]Node{.{ .text = "item" }};
    const node: Node = .{ .loop = .{
        .item_prefix = "post",
        .collection = "pages.posts",
        .alias = "loop",
        .sort_field = "date",
        .order_desc = true,
        .limit = 5,
        .offset = 2,
        .body = &body,
    } };
    try std.testing.expectEqualStrings("post", node.loop.item_prefix);
    try std.testing.expectEqualStrings("pages.posts", node.loop.collection);
    try std.testing.expectEqualStrings("loop", node.loop.alias.?);
    try std.testing.expectEqualStrings("date", node.loop.sort_field.?);
    try std.testing.expect(node.loop.order_desc);
    try std.testing.expectEqual(@as(usize, 5), node.loop.limit.?);
    try std.testing.expectEqual(@as(usize, 2), node.loop.offset.?);
}

test "loop node with defaults" {
    const body = [_]Node{.{ .text = "item" }};
    const node: Node = .{ .loop = .{
        .item_prefix = "item",
        .collection = "items",
        .body = &body,
    } };
    try std.testing.expectEqual(@as(?[]const u8, null), node.loop.alias);
    try std.testing.expectEqual(@as(?[]const u8, null), node.loop.sort_field);
    try std.testing.expect(!node.loop.order_desc);
    try std.testing.expectEqual(@as(?usize, null), node.loop.limit);
    try std.testing.expectEqual(@as(?usize, null), node.loop.offset);
}

test "bound_tag with mixed segments" {
    const segments = [_]Segment{
        .{ .literal = "<a " },
        .{ .binding = .{ .html_attr = "href", .ref_name = "url", .is_var = true } },
        .{ .literal = ">" },
    };
    const node: Node = .{ .bound_tag = .{ .segments = &segments } };
    try std.testing.expectEqual(@as(usize, 3), node.bound_tag.segments.len);
    try std.testing.expectEqualStrings("<a ", node.bound_tag.segments[0].literal);
    try std.testing.expectEqualStrings("href", node.bound_tag.segments[1].binding.html_attr);
    try std.testing.expect(node.bound_tag.segments[1].binding.is_var);
}

test "union matching covers all variants" {
    const nodes = [_]Node{
        .{ .text = "t" },
        .{ .variable = .{ .name = "v" } },
        .{ .raw_variable = .{ .name = "r" } },
        .{ .let_binding = .{ .name = "l", .body = &.{} } },
        .comment,
        .{ .attr_output = .{ .name = "a" } },
        .{ .slot = .{ .name = "s" } },
        .{ .include = .{ .template = "i" } },
        .{ .extend = .{ .template = "e" } },
        .{ .conditional = .{ .branches = &.{} } },
        .{ .loop = .{ .item_prefix = "x", .collection = "xs", .body = &.{} } },
        .{ .bound_tag = .{ .segments = &.{} } },
    };
    for (nodes) |node| {
        switch (node) {
            .text, .variable, .raw_variable, .let_binding, .comment, .attr_output, .slot, .include, .extend, .conditional, .loop, .bound_tag => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 12), nodes.len);
}
