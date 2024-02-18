const Ast = @This();

const std = @import("std");
const Diagnostic = @import("Diagnostic.zig");
const Tokenizer = @import("Tokenizer.zig");

pub const Node = struct {
    tag: Tag,
    loc: Tokenizer.Token.Loc = undefined,

    // 0 = root node (root node has itself as parent)
    parent_id: u32,

    // 0 = not present
    next_id: u32 = 0,
    first_child_id: u32 = 0,
    last_child_id: u32 = 0,

    pub const Tag = enum {
        root,
        braceless_struct,
        struct_or_map,
        @"struct",
        struct_field,
        identifier,
        map,
        map_field,
        array,
        array_comma,
        string,
        number,
        bool,
        null,
        tag,
        _value,
    };

    pub fn addChild(
        self: *Node,
        nodes: *std.ArrayList(Node),
        tag: Node.Tag,
    ) !*Node {
        const self_id = self.getId(nodes);
        const new_child_id: u32 = @intCast(nodes.items.len);
        if (self.last_child_id != 0) {
            const child = &nodes.items[self.last_child_id];
            std.debug.assert(child.next_id == 0);

            child.next_id = new_child_id;
        }
        if (self.first_child_id == 0) {
            std.debug.assert(self.last_child_id == 0);
            self.first_child_id = new_child_id;
        }

        self.last_child_id = new_child_id;
        const child = try nodes.addOne();
        child.* = .{ .tag = tag, .parent_id = self_id };

        return child;
    }

    pub fn parent(self: *Node, nodes: *std.ArrayList(Node)) *Node {
        return &nodes.items[self.parent_id];
    }

    pub fn getId(self: *Node, nodes: *std.ArrayList(Node)) u32 {
        const idx: u32 = @intCast(
            (@intFromPtr(self) - @intFromPtr(nodes.items.ptr)) / @sizeOf(Node),
        );
        std.debug.assert(idx < nodes.items.len);
        return idx;
    }
};

code: [:0]const u8,
nodes: std.ArrayList(Node),
tokenizer: Tokenizer = .{},
diag: ?*Diagnostic,

pub fn deinit(self: Ast) void {
    self.nodes.deinit();
}

pub fn parse(
    gpa: std.mem.Allocator,
    code: [:0]const u8,
    path: ?[]const u8,
    diag: ?*Diagnostic,
) !Ast {
    var ast: Ast = .{
        .code = code,
        .diag = diag,
        .nodes = std.ArrayList(Node).init(gpa),
    };
    errdefer ast.nodes.clearAndFree();

    if (ast.diag) |d| {
        d.code = code;
        d.path = path;
    }

    const root_node = try ast.nodes.addOne();
    root_node.* = .{ .tag = .root, .parent_id = 0 };

    var node = root_node;
    var token = try ast.next();
    while (true) {
        switch (node.tag) {
            .root => switch (token.tag) {
                .dot => {
                    node = try node.addChild(&ast.nodes, .braceless_struct);
                    node.loc.start = token.loc.start;
                },
                .eof => return ast,
                else => {
                    node = try node.addChild(&ast.nodes, ._value);
                },
            },
            .braceless_struct => switch (token.tag) {
                .eof => return ast,
                .dot => {
                    node = try node.addChild(&ast.nodes, .struct_field);
                    node.loc.start = token.loc.start;
                    token = try ast.next();
                },
                else => {
                    if (ast.diag) |d| {
                        d.tok = token;
                        d.err = .{
                            .unexpected_token = .{
                                .expected = &.{ .eof, .dot },
                            },
                        };
                    }
                    return error.Syntax;
                },
            },

            .struct_or_map => switch (token.tag) {
                .rb => {
                    node.loc.end = token.loc.end;
                    node = node.parent(&ast.nodes);
                    token = try ast.next();
                },
                .dot => {
                    node.tag = .@"struct";
                    node.loc.start = token.loc.start;
                },
                .string => {
                    node.tag = .map;
                    node.loc.start = token.loc.start;
                },
                else => {
                    if (ast.diag) |d| {
                        d.tok = token;
                        d.err = .{
                            .unexpected_token = .{
                                .expected = &.{ .dot, .string, .rb },
                            },
                        };
                    }
                    return error.Syntax;
                },
            },

            .@"struct" => switch (token.tag) {
                .dot => {
                    node = try node.addChild(&ast.nodes, .struct_field);
                    node.loc.start = token.loc.start;
                    token = try ast.next();
                },
                .rb => {
                    node.loc.end = token.loc.end;
                    node = node.parent(&ast.nodes);
                    token = try ast.next();
                },
                else => {
                    if (ast.diag) |d| {
                        d.tok = token;
                        d.err = .{
                            .unexpected_token = .{
                                .expected = &.{ .dot, .rb },
                            },
                        };
                    }
                    return error.Syntax;
                },
            },

            .struct_field => {
                if (node.first_child_id == 0) {
                    if (token.tag == .identifier) {
                        node = try node.addChild(&ast.nodes, .identifier);
                        node.loc = token.loc;
                        node = node.parent(&ast.nodes);
                    } else {
                        if (ast.diag) |d| {
                            d.tok = token;
                            d.err = .{
                                .unexpected_token = .{
                                    .expected = &.{.identifier},
                                },
                            };
                        }
                        return error.Syntax;
                    }

                    const t = try ast.next();
                    if (t.tag != .eql) {
                        if (ast.diag) |d| {
                            d.tok = t;
                            d.err = .{
                                .unexpected_token = .{
                                    .expected = &.{.eql},
                                },
                            };
                        }
                        return error.Syntax;
                    }

                    node = try node.addChild(&ast.nodes, ._value);
                    token = try ast.next();
                } else {
                    node.loc.end = token.loc.end;

                    if (token.tag == .comma) {
                        token = try ast.next();
                    } else {
                        if (token.tag != .rb and token.tag != .eof) {
                            if (ast.diag) |d| {
                                d.tok = token;
                                d.err = .{
                                    .unexpected_token = .{
                                        .expected = &.{.comma},
                                    },
                                };
                            }
                            return error.Syntax;
                        }
                    }

                    node = node.parent(&ast.nodes);
                }
            },

            .map => switch (token.tag) {
                .string => {
                    node = try node.addChild(&ast.nodes, .map_field);
                    node.loc.start = token.loc.start;
                },
                .rb => {
                    node.loc.end = token.loc.end;
                    node = node.parent(&ast.nodes);
                    token = try ast.next();
                },
                else => {
                    if (ast.diag) |d| {
                        d.tok = token;
                        d.err = .{
                            .unexpected_token = .{
                                .expected = &.{ .string, .rb },
                            },
                        };
                    }
                    return error.Syntax;
                },
            },

            .map_field => {
                if (node.first_child_id == 0) {
                    if (token.tag == .string) {
                        node = try node.addChild(&ast.nodes, .string);
                        node.loc = token.loc;
                        node = node.parent(&ast.nodes);
                    } else {
                        if (ast.diag) |d| {
                            d.tok = token;
                            d.err = .{
                                .unexpected_token = .{
                                    .expected = &.{.string},
                                },
                            };
                        }
                        return error.Syntax;
                    }

                    const t = try ast.next();
                    if (t.tag != .colon) {
                        if (ast.diag) |d| {
                            d.tok = token;
                            d.err = .{
                                .unexpected_token = .{
                                    .expected = &.{.colon},
                                },
                            };
                        }
                        return error.Syntax;
                    }

                    node = try node.addChild(&ast.nodes, ._value);
                    token = try ast.next();
                } else {
                    node.loc.end = token.loc.end;
                    if (token.tag == .comma) {
                        token = try ast.next();
                    } else {
                        if (token.tag != .rb) {
                            if (ast.diag) |d| {
                                d.tok = token;
                                d.err = .{
                                    .unexpected_token = .{
                                        .expected = &.{.comma},
                                    },
                                };
                            }
                            return error.Syntax;
                        }
                    }

                    node = node.parent(&ast.nodes);
                }
            },
            .array => {
                if (node.last_child_id != 0) {
                    if (token.tag == .comma) {
                        token = try ast.next();
                        if (token.tag == .rsb) {
                            node.tag = .array_comma;
                        }
                    } else {
                        if (token.tag != .rsb) {
                            if (ast.diag) |d| {
                                d.tok = token;
                                d.err = .{
                                    .unexpected_token = .{
                                        .expected = &.{.comma},
                                    },
                                };
                            }
                            return error.Syntax;
                        }
                    }
                }

                if (token.tag == .rsb) {
                    node.loc.end = token.loc.end;
                    node = node.parent(&ast.nodes);
                    token = try ast.next();
                } else {
                    node = try node.addChild(&ast.nodes, ._value);
                }
            },

            .tag => {
                node = node.parent(&ast.nodes);
            },

            ._value => switch (token.tag) {
                .lb => {
                    node.tag = .struct_or_map;
                    node.loc.start = token.loc.start;
                    token = try ast.next();
                },
                .lsb => {
                    node.tag = .array;
                    node.loc.start = token.loc.start;
                    token = try ast.next();
                },
                .at => {
                    node.tag = .tag;
                    const t = try ast.next();
                    if (t.tag != .identifier) {
                        if (ast.diag) |d| {
                            d.tok = t;
                            d.err = .{
                                .unexpected_token = .{
                                    .expected = &.{.identifier},
                                },
                            };
                        }
                        return error.Syntax;
                    }

                    node.loc = t.loc;
                    node = try node.addChild(&ast.nodes, ._value);
                    token = try ast.next();
                },
                .string => {
                    node.tag = .string;
                    node.loc = token.loc;
                    node = node.parent(&ast.nodes);
                    token = try ast.next();
                },
                .number => {
                    node.tag = .number;
                    node.loc = token.loc;
                    node = node.parent(&ast.nodes);
                    token = try ast.next();
                },
                .true, .false => {
                    node.tag = .bool;
                    node.loc = token.loc;
                    node = node.parent(&ast.nodes);
                    token = try ast.next();
                },
                .null => {
                    node.tag = .null;
                    node.loc = token.loc;
                    node = node.parent(&ast.nodes);
                    token = try ast.next();
                },
                else => {
                    if (ast.diag) |d| {
                        d.tok = token;
                        d.err = .{
                            .unexpected_token = .{
                                .expected = &.{.value},
                            },
                        };
                    }
                    return error.Syntax;
                },
            },

            // only set at .rsb
            .array_comma,

            .identifier,
            .string,
            .number,
            .bool,
            .null,
            => unreachable,
        }
    }
}

fn next(self: *Ast) error{Syntax}!Tokenizer.Token {
    const token = self.tokenizer.next(self.code);
    if (token.tag == .invalid) {
        if (self.diag) |d| {
            d.tok = token;
            d.err = .invalid_token;
        }
        return error.Syntax;
    }
    return token;
}

pub fn format(
    self: Ast,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    out_stream: anytype,
) !void {
    _ = fmt;
    _ = options;

    try render(self.nodes.items, self.code, out_stream);
}

const RenderMode = enum { horizontal, vertical };
pub fn render(nodes: []const Node, code: [:0]const u8, w: anytype) anyerror!void {
    try renderValue(0, nodes[1], nodes, code, true, w);
}

fn renderValue(
    indent: usize,
    node: Node,
    nodes: []const Node,
    code: [:0]const u8,
    is_top_value: bool,
    w: anytype,
) anyerror!void {
    switch (node.tag) {
        .root => return,
        .braceless_struct => {
            std.debug.assert(node.first_child_id != 0);
            try renderFields(indent, .vertical, ".", " =", node.first_child_id, nodes, code, w);
        },

        .@"struct" => {
            // empty struct literals are .struct_or_map nodes
            std.debug.assert(node.first_child_id != 0);
            const mode: RenderMode = blk: {
                if (is_top_value) break :blk .vertical;

                std.debug.assert(node.last_child_id != 0);
                const char = nodes[node.last_child_id].loc.end - 1;
                if (code[char] == ',') break :blk .vertical;
                break :blk .horizontal;
            };
            switch (mode) {
                .vertical => try w.writeAll("{\n"),
                .horizontal => try w.writeAll("{ "),
            }
            try renderFields(indent + 1, mode, ".", " =", node.first_child_id, nodes, code, w);
            switch (mode) {
                .vertical => {
                    try printIndent(indent, w);
                },
                .horizontal => try w.writeAll(" "),
            }
            try w.writeAll("}");
        },

        .map => {
            // empty map literals are .struct_or_map nodes
            std.debug.assert(node.first_child_id != 0);
            const mode: RenderMode = blk: {
                std.debug.assert(node.last_child_id != 0);
                const char = nodes[node.last_child_id].loc.end - 1;
                if (code[char] == ',') break :blk .vertical;
                break :blk .horizontal;
            };

            switch (mode) {
                .vertical => try w.writeAll("{\n"),
                .horizontal => try w.writeAll("{ "),
            }

            try renderFields(indent + 1, mode, "", ":", node.first_child_id, nodes, code, w);

            switch (mode) {
                .vertical => {
                    try printIndent(indent, w);
                },
                .horizontal => try w.writeAll(" "),
            }
            try w.writeAll("}");
        },

        .array => {
            if (node.first_child_id == 0) {
                try w.writeAll("[]");
                return;
            }

            try w.writeAll("[");
            try renderArray(indent + 1, .horizontal, node.first_child_id, nodes, code, w);
            try w.writeAll("]");
        },
        .array_comma => {
            std.debug.assert(node.first_child_id != 0);

            try w.writeAll("[\n");
            try renderArray(indent + 1, .vertical, node.first_child_id, nodes, code, w);
            try printIndent(indent, w);
            try w.writeAll("]");
        },

        else => {
            try w.print("{s}", .{node.loc.src(code)});
        },
    }
}

fn printIndent(indent: usize, w: anytype) !void {
    for (0..indent) |_| try w.writeAll("    ");
}

fn renderArray(
    indent: usize,
    mode: RenderMode,
    idx: u32,
    nodes: []const Node,
    code: [:0]const u8,
    w: anytype,
) !void {
    var maybe_value: ?Node = nodes[idx];
    while (maybe_value) |value| {
        if (mode == .vertical) {
            try printIndent(indent, w);
        }
        try renderValue(indent, value, nodes, code, false, w);

        if (value.next_id != 0) {
            maybe_value = nodes[value.next_id];
        } else {
            maybe_value = null;
        }

        switch (mode) {
            .vertical => try w.writeAll(",\n"),
            .horizontal => {
                if (maybe_value != null) {
                    try w.writeAll(", ");
                }
            },
        }
    }
}

fn renderFields(
    indent: usize,
    mode: RenderMode,
    dot: []const u8,
    sep: []const u8,
    idx: u32,
    nodes: []const Node,
    code: [:0]const u8,
    w: anytype,
) !void {
    var maybe_field: ?Node = nodes[idx];
    while (maybe_field) |field| {
        const field_name = nodes[field.first_child_id].loc.src(code);
        if (mode == .vertical) {
            try printIndent(indent, w);
        }
        try w.print("{s}{s}{s} ", .{ dot, field_name, sep });
        try renderValue(indent, nodes[field.last_child_id], nodes, code, false, w);

        if (field.next_id != 0) {
            maybe_field = nodes[field.next_id];
        } else {
            maybe_field = null;
        }

        switch (mode) {
            .vertical => try w.writeAll(",\n"),
            .horizontal => {
                if (maybe_field != null) {
                    try w.writeAll(", ");
                }
            },
        }
    }
}

test "basics" {
    const case =
        \\.foo = "bar",
        \\.bar = [1, 2, 3],
        \\
    ;

    var diag: Diagnostic = .{};
    errdefer std.debug.print("diag: {}", .{diag});
    const ast = try parse(std.testing.allocator, case, null, &diag);
    defer ast.deinit();
    try std.testing.expectFmt(case, "{}", .{ast});
}

test "vertical" {
    const case =
        \\.foo = "bar",
        \\.bar = [
        \\    1,
        \\    2,
        \\    3,
        \\],
        \\
    ;

    var diag: Diagnostic = .{};
    errdefer std.debug.print("diag: {}", .{diag});
    const ast = try parse(std.testing.allocator, case, null, &diag);
    defer ast.deinit();
    try std.testing.expectFmt(case, "{}", .{ast});
}

test "complex" {
    const case =
        \\.foo = "bar",
        \\.bar = [
        \\    1,
        \\    2,
        \\    {
        \\        "abc": "foo",
        \\        "baz": ["foo", "bar"],
        \\    },
        \\],
        \\
    ;

    var diag: Diagnostic = .{};
    errdefer std.debug.print("diag: {}", .{diag});
    const ast = try parse(std.testing.allocator, case, null, &diag);
    defer ast.deinit();
    try std.testing.expectFmt(case, "{}", .{ast});
}
