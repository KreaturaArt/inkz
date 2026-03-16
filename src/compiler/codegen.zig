/// Ink compiler codegen — converts a Parsed.Story into a CContainer tree.
///
/// The CContainer tree mirrors the ink.json runtime format but uses string
/// paths throughout (the runtime's json_loader converts them to indices).
/// All allocations come from the caller-supplied allocator (use an arena).
const std = @import("std");
const Parsed = @import("parsed.zig");

// ── Public types ─────────────────────────────────────────────────────────────

pub const CObject = union(enum) {
    text: []const u8, // "^text" in JSON
    newline, // "\n"
    done, // "done"
    end, // "end"
    tunnel_return, // "->->"
    glue, // "<>"
    divert: []const u8, // {"->":"target"}
    tunnel_divert: []const u8, // {"->t->":"target"}
    container: *CContainer, // recursive sub-container
    // Eval-mode objects (used for VAR initializers and expressions)
    eval_start, // "ev"
    eval_end, // "/ev"
    eval_output, // "out"
    pop, // "pop"
    void_, // "void"
    nop, // "nop"
    int: i64, // integer literal
    float: f64, // float literal
    bool_: bool, // boolean literal (true/false)
    string: []const u8, // string literal (not ^-prefixed)
    var_assign: struct { name: []const u8, is_new: bool }, // {"VAR=":"name"} or with "re":true
    var_ref: []const u8, // {"VAR?":"name"}
    temp_assign: struct { name: []const u8, is_new: bool }, // {"temp=":"name"} or with "re":true
};

pub const NamedChild = struct {
    name: []const u8,
    container: *CContainer,
};

pub const CContainer = struct {
    own_name: ?[]const u8 = null,
    flags: u32 = 0,
    content: []CObject = &.{},
    named_children: []NamedChild = &.{},
};

// ── Entry point ───────────────────────────────────────────────────────────────

/// Generate a CContainer tree from a parsed story.
/// Returns the root container (alloc should be an arena).
pub fn generate(alloc: std.mem.Allocator, story: Parsed.Story) !*CContainer {
    var gen = Gen{ .alloc = alloc };
    return gen.generateRoot(story);
}

// ── Codegen implementation ────────────────────────────────────────────────────

const Gen = struct {
    alloc: std.mem.Allocator,
    /// Compile-time constant values, keyed by name.  Used to substitute CONST
    /// references at codegen time so no {"VAR?":"name"} appears for constants.
    const_map: std.StringHashMapUnmanaged(*const Parsed.Expression) = .{},

    fn newContainer(self: *Gen, name: ?[]const u8) !*CContainer {
        const c = try self.alloc.create(CContainer);
        c.* = .{ .own_name = name };
        return c;
    }

    fn generateRoot(self: *Gen, story: Parsed.Story) !*CContainer {
        // Populate CONST map so value substitution works during genExpr.
        for (story.constants) |c| {
            try self.const_map.put(self.alloc, c.name, c.value);
        }
        // 1. Root content sub-container (position 0 inside root).
        var root_flow = std.ArrayList(CObject).empty;
        for (story.root_content) |item| {
            try self.genFlowItem(&root_flow, item);
        }
        // Always append the g-0 implicit-done named container.
        const g0 = try self.newContainer("g-0");
        g0.content = try self.alloc.dupe(CObject, &.{.done});
        try root_flow.append(self.alloc, .{ .container = g0 });

        const root_content_sub = try self.newContainer(null);
        root_content_sub.content = try root_flow.toOwnedSlice(self.alloc);

        // 2. Global-decl container (VAR initializers), if any.
        //    Format: ["ev", 0, {VAR=:"name"}, ... , "/ev", "end", null]
        var global_decl_items = std.ArrayList(CObject).empty;
        if (story.global_decls.len > 0) {
            try global_decl_items.append(self.alloc, .eval_start);
            for (story.global_decls) |decl| {
                try self.genExpr(&global_decl_items, decl.initial.*);
                try global_decl_items.append(self.alloc, .{ .var_assign = .{
                    .name = decl.name,
                    .is_new = true,
                } });
            }
            try global_decl_items.append(self.alloc, .eval_end);
            try global_decl_items.append(self.alloc, .end);
        }

        // 3. Named children: knots + optional global-decl.
        var named = std.ArrayList(NamedChild).empty;
        for (story.knots) |knot| {
            const kc = try self.genKnot(knot);
            try named.append(self.alloc, .{ .name = knot.name, .container = kc });
        }
        if (global_decl_items.items.len > 0) {
            const gd = try self.newContainer(null);
            gd.content = try global_decl_items.toOwnedSlice(self.alloc);
            try named.append(self.alloc, .{ .name = "global decl", .container = gd });
        }

        // 4. Root container: [root_content_sub, "done", {knots...}]
        const root = try self.newContainer(null);
        root.content = try self.alloc.dupe(CObject, &.{
            .{ .container = root_content_sub },
            .done,
        });
        root.named_children = try named.toOwnedSlice(self.alloc);
        return root;
    }

    fn genKnot(self: *Gen, knot: Parsed.Knot) !*CContainer {
        var items = std.ArrayList(CObject).empty;
        for (knot.content) |item| {
            try self.genFlowItem(&items, item);
        }

        if (knot.stitches.len > 0) {
            var stitch_named = std.ArrayList(NamedChild).empty;
            for (knot.stitches) |stitch| {
                var stitch_items = std.ArrayList(CObject).empty;
                for (stitch.content) |item| {
                    try self.genFlowItem(&stitch_items, item);
                }
                const sc = try self.newContainer(null);
                sc.content = try stitch_items.toOwnedSlice(self.alloc);
                try stitch_named.append(self.alloc, .{ .name = stitch.name, .container = sc });
            }
            const kc = try self.newContainer(null);
            kc.content = try items.toOwnedSlice(self.alloc);
            kc.named_children = try stitch_named.toOwnedSlice(self.alloc);
            return kc;
        } else {
            const kc = try self.newContainer(null);
            kc.content = try items.toOwnedSlice(self.alloc);
            return kc;
        }
    }

    fn genFlowItem(self: *Gen, out: *std.ArrayList(CObject), item: Parsed.FlowItem) !void {
        switch (item) {
            .text => |tl| {
                for (tl.elements) |elem| {
                    try self.genInlineElement(out, elem);
                }
                try out.append(self.alloc, .newline);
            },
            .divert => |d| try self.genDivert(out, d),
            .tag => {}, // TASK-82
            .logic => |ll| try self.genLogicLine(out, ll),
            .conditional => {}, // TASK-78
            .choice => {}, // TASK-79
            .gather => {}, // TASK-79
            .sequence => {}, // TASK-81
            .thread_start => {}, // TASK-84
        }
    }

    fn genDivert(self: *Gen, out: *std.ArrayList(CObject), d: Parsed.Divert) !void {
        if (std.mem.eql(u8, d.target, "END")) {
            try out.append(self.alloc, .end);
        } else if (std.mem.eql(u8, d.target, "DONE")) {
            try out.append(self.alloc, .done);
        } else if (std.mem.eql(u8, d.target, "->->")) {
            try out.append(self.alloc, .tunnel_return);
        } else if (d.is_tunnel) {
            try out.append(self.alloc, .{ .tunnel_divert = d.target });
        } else {
            try out.append(self.alloc, .{ .divert = d.target });
        }
    }

    fn genLogicLine(self: *Gen, out: *std.ArrayList(CObject), ll: Parsed.LogicLine) !void {
        switch (ll) {
            .temp_decl => |td| {
                try out.append(self.alloc, .eval_start);
                try self.genExpr(out, td.initial.*);
                try out.append(self.alloc, .eval_end);
                try out.append(self.alloc, .{ .temp_assign = .{ .name = td.name, .is_new = true } });
            },
            .assignment => |a| {
                try out.append(self.alloc, .eval_start);
                try self.genExpr(out, a.value.*);
                try out.append(self.alloc, .eval_end);
                if (a.is_temp) {
                    try out.append(self.alloc, .{ .temp_assign = .{ .name = a.name, .is_new = false } });
                } else {
                    try out.append(self.alloc, .{ .var_assign = .{ .name = a.name, .is_new = false } });
                }
            },
            .return_stmt => {}, // TASK-80
            .var_decl => {}, // handled via global_decls
            .include => {}, // TASK-84
        }
    }

    fn genInlineElement(self: *Gen, out: *std.ArrayList(CObject), elem: Parsed.InlineElement) !void {
        switch (elem) {
            .text => |t| {
                const trimmed = std.mem.trim(u8, t, " \t");
                if (trimmed.len > 0) try out.append(self.alloc, .{ .text = trimmed });
            },
            .glue => try out.append(self.alloc, .glue),
            .divert => |d| try self.genDivert(out, d),
            .inline_expr => |expr| {
                try out.append(self.alloc, .eval_start);
                try self.genExpr(out, expr.*);
                try out.append(self.alloc, .eval_output);
                try out.append(self.alloc, .eval_end);
            },
            .sequence => {}, // TASK-81
            .tag => {}, // TASK-82
        }
    }

    fn genExpr(self: *Gen, out: *std.ArrayList(CObject), expr: Parsed.Expression) !void {
        switch (expr) {
            .int_lit => |v| try out.append(self.alloc, .{ .int = v }),
            .float_lit => |v| try out.append(self.alloc, .{ .float = v }),
            .bool_lit => |v| try out.append(self.alloc, .{ .bool_ = v }),
            .string_lit => |v| {
                try out.append(self.alloc, .{ .string = "str" });
                try out.append(self.alloc, .{ .text = v });
                try out.append(self.alloc, .{ .string = "/str" });
            },
            .var_ref => |name| {
                // Substitute CONST values at codegen time.
                if (self.const_map.get(name)) |const_expr| {
                    try self.genExpr(out, const_expr.*);
                } else {
                    try out.append(self.alloc, .{ .var_ref = name });
                }
            },
            .binary => |b| {
                try self.genExpr(out, b.lhs.*);
                try self.genExpr(out, b.rhs.*);
                try out.append(self.alloc, .{ .string = opStr(b.op) });
            },
            .unary => |u| {
                try self.genExpr(out, u.operand.*);
                const s: []const u8 = if (u.op == .not) "!" else "_";
                try out.append(self.alloc, .{ .string = s });
            },
            else => {}, // remaining expression types in later tasks
        }
    }
};

fn opStr(op: Parsed.BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .eq => "==",
        .ne => "!=",
        .gt => ">",
        .lt => "<",
        .ge => ">=",
        .le => "<=",
        .and_ => "&&",
        .or_ => "||",
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Compiler codegen: empty story produces g-0 root" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const story = Parsed.Story{
        .list_defs = &.{},
        .global_decls = &.{},
        .constants = &.{},
        .external_fns = &.{},
        .includes = &.{},
        .knots = &.{},
        .root_content = &.{},
    };
    const root = try generate(aa, story);
    // Root container has 2 content items: sub-container + done
    try std.testing.expectEqual(@as(usize, 2), root.content.len);
    try std.testing.expectEqual(CObject.done, root.content[1]);
    // Sub-container has 1 item: g-0 container
    const sub = root.content[0].container;
    try std.testing.expectEqual(@as(usize, 1), sub.content.len);
    const g0 = sub.content[0].container;
    try std.testing.expectEqualStrings("g-0", g0.own_name.?);
    try std.testing.expectEqual(CObject.done, g0.content[0]);
}

test "Compiler codegen: hello world" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const parser = @import("parser.zig");
    const src = "Hello world\n";
    const story = try parser.parse(aa, src);
    const root = try generate(aa, story);

    // root.content[0] is the root flow sub-container
    const sub = root.content[0].container;
    // sub.content: text("Hello world"), newline, g0
    try std.testing.expectEqual(@as(usize, 3), sub.content.len);
    try std.testing.expectEqualStrings("Hello world", sub.content[0].text);
    try std.testing.expectEqual(CObject.newline, sub.content[1]);
    const g0 = sub.content[2].container;
    try std.testing.expectEqualStrings("g-0", g0.own_name.?);
}
