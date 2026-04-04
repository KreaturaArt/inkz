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
    // Conditional objects
    cond_divert: []const u8, // {"->":"path","c":true} — conditional branch jump
    dup, // "du"  — duplicate top of stack (used in switch comparisons)
    // Choice objects
    choice_point: struct { path: []const u8, flags: u32 }, // {"*":"path","flg":N}
    divert_target_val: []const u8, // {"^->":"path"}  push divert target as value
    divert_via_var: []const u8, // {"->":"name","var":true}  follow a var's stored path
    // Read-count and function-call objects
    read_count: []const u8, // {"CNT?":"path"}  visit count of a knot/stitch
    function_call: struct { name: []const u8, arg_count: u32 }, // {"f()":"name"} or {"f(N)":"name"}
    external_call: struct { name: []const u8, arg_count: u32 }, // {"x()":"name","exArgs":N}
    func_return, // "~ret"
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
    /// Names of declared knots/stitches (and function knots).  In a condition
    /// expression, a bare name that matches a knot becomes {"CNT?":"name"}
    /// (visit-count check) rather than {"VAR?":"name"} (variable lookup).
    knot_names: std.StringHashMapUnmanaged(void) = .{},
    /// Names of declared global VARs.  A divert to a var name becomes divert_via_var.
    var_names: std.StringHashMapUnmanaged(void) = .{},
    /// Names of divert-target params in the current function.  Same treatment as var_names.
    divert_param_names: std.StringHashMapUnmanaged(void) = .{},
    /// Choice labels → absolute path to the c-N container for read-count references.
    choice_labels: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Gather labels → absolute path to the gather section container.
    gather_label_paths: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Names of EXTERNAL function declarations — calls to these use external_call.
    external_fn_names: std.StringHashMapUnmanaged(u32) = .{}, // name → param_count

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
        // Populate knot_names so expressions can emit CNT? for knot references.
        for (story.knots) |knot| {
            try self.knot_names.put(self.alloc, knot.name, {});
            for (knot.stitches) |stitch| {
                try self.knot_names.put(self.alloc, stitch.name, {});
            }
        }
        // Populate var_names so diverts to variable names become divert_via_var.
        for (story.global_decls) |decl| {
            try self.var_names.put(self.alloc, decl.name, {});
        }
        // Populate external_fn_names so calls to external functions use external_call.
        for (story.external_fns) |ef| {
            try self.external_fn_names.put(self.alloc, ef.name, ef.param_count);
        }

        // 1. Root content sub-container (position 0 inside root).
        const root_content_sub = try self.newContainer(null);

        if (itemsHaveChoices(story.root_content)) {
            // Weave mode: root_content_sub is the weave holder.
            try self.genWeave(story.root_content, root_content_sub, "0", true, 1, null);
        } else {
            var root_flow = std.ArrayList(CObject).empty;
            for (story.root_content) |item| {
                try self.genFlowItem(&root_flow, item, "0");
            }
            // Always append the g-0 implicit-done named container.
            const g0 = try self.newContainer("g-0");
            g0.content = try self.alloc.dupe(CObject, &.{.done});
            try root_flow.append(self.alloc, .{ .container = g0 });
            root_content_sub.content = try root_flow.toOwnedSlice(self.alloc);
        }

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
        if (knot.stitches.len > 0) {
            // Knot with stitches — no weave support for stitches yet.
            var items = std.ArrayList(CObject).empty;
            // Emit param bindings at function start (reverse order).
            if (knot.is_function and knot.params.len > 0) {
                var i = knot.params.len;
                while (i > 0) {
                    i -= 1;
                    const p = knot.params[i];
                    try items.append(self.alloc, .{ .temp_assign = .{ .name = p.name, .is_new = true } });
                }
            }
            for (knot.content) |item| {
                try self.genFlowItem(&items, item, knot.name);
            }
            var stitch_named = std.ArrayList(NamedChild).empty;
            for (knot.stitches) |stitch| {
                const stitch_path = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ knot.name, stitch.name });
                const sc = try self.genKnotContent(stitch.content, stitch_path, &.{}, false);
                try stitch_named.append(self.alloc, .{ .name = stitch.name, .container = sc });
            }
            const kc = try self.newContainer(null);
            kc.content = try items.toOwnedSlice(self.alloc);
            kc.named_children = try stitch_named.toOwnedSlice(self.alloc);
            return kc;
        }

        // Track divert-target params for the duration of genKnotContent.
        self.divert_param_names.clearRetainingCapacity();
        for (knot.params) |p| {
            if (p.is_divert) {
                try self.divert_param_names.put(self.alloc, p.name, {});
            }
        }
        defer self.divert_param_names.clearRetainingCapacity();
        return self.genKnotContent(knot.content, knot.name, knot.params, knot.is_function);
    }

    /// Generate a knot or stitch body.  If the content has choices we wrap it
    /// in an inner_wrapper container at index 0 (producing the `knot.0` weave
    /// holder pattern Inklecate uses).
    fn genKnotContent(self: *Gen, content: []const Parsed.FlowItem, knot_name: []const u8, params: []const Parsed.Param, is_function: bool) !*CContainer {
        if (itemsHaveChoices(content)) {
            // Create inner_wrapper: the weave holder lives at knot.0.
            const inner_wrapper = try self.newContainer(null);
            const holder_abs = try std.fmt.allocPrint(self.alloc, "{s}.0", .{knot_name});
            try self.genWeave(content, inner_wrapper, holder_abs, false, 1, null);

            // The knot container wraps inner_wrapper as its sole content item.
            const kc = try self.newContainer(null);
            kc.content = try self.alloc.dupe(CObject, &.{.{ .container = inner_wrapper }});
            return kc;
        }

        // No choices: emit items directly.
        var items = std.ArrayList(CObject).empty;
        // Emit param bindings at function start (reverse order, last param first).
        if (is_function and params.len > 0) {
            var i = params.len;
            while (i > 0) {
                i -= 1;
                const p = params[i];
                try items.append(self.alloc, .{ .temp_assign = .{ .name = p.name, .is_new = true } });
            }
        }
        for (content) |item| {
            try self.genFlowItem(&items, item, knot_name);
        }
        const kc = try self.newContainer(null);
        kc.content = try items.toOwnedSlice(self.alloc);
        return kc;
    }

    fn genFlowItem(self: *Gen, out: *std.ArrayList(CObject), item: Parsed.FlowItem, parent_path: []const u8) error{OutOfMemory}!void {
        switch (item) {
            .text => |tl| {
                for (tl.elements) |elem| {
                    try self.genInlineElement(out, elem);
                }
                try out.append(self.alloc, .newline);
            },
            .divert => |d| try self.genDivert(out, d),
            .tag => |tag_text| {
                try out.append(self.alloc, .{ .string = "#" });
                try out.append(self.alloc, .{ .text = tag_text });
                try out.append(self.alloc, .{ .string = "/#" });
            },
            .logic => |ll| try self.genLogicLine(out, ll),
            .conditional => |c| try self.genConditional(out, c, parent_path),
            // Choices and gathers are handled by genWeave; they should not
            // appear here in isolation, but if they do we silently skip them.
            .choice => {},
            .gather => {},
            .sequence => |seq| try self.genSequence(out, seq),
            .thread_start => {}, // TASK-84
        }
    }

    fn genDivert(self: *Gen, out: *std.ArrayList(CObject), d: Parsed.Divert) !void {
        if (std.mem.eql(u8, d.target, "END")) {
            try out.append(self.alloc, .end);
        } else if (std.mem.eql(u8, d.target, "DONE")) {
            try out.append(self.alloc, .done);
        } else if (std.mem.eql(u8, d.target, "->->")) {
            // Tunnel/function return: push void then return.
            try out.append(self.alloc, .eval_start);
            try out.append(self.alloc, .void_);
            try out.append(self.alloc, .eval_end);
            try out.append(self.alloc, .tunnel_return);
        } else {
            // Emit args if any (for parameterized knot calls).
            if (d.args.len > 0) {
                try out.append(self.alloc, .eval_start);
                for (d.args) |arg| {
                    try self.genExpr(out, arg.*);
                }
                try out.append(self.alloc, .eval_end);
            }
            // Check gather_label_paths first so labeled gathers resolve to abs paths.
            if (self.gather_label_paths.get(d.target)) |abs_path| {
                try out.append(self.alloc, .{ .divert = abs_path });
            } else if (d.is_tunnel) {
                if (self.var_names.contains(d.target) or self.divert_param_names.contains(d.target)) {
                    try out.append(self.alloc, .{ .divert_via_var = d.target }); // TODO: tunnel+var
                } else {
                    try out.append(self.alloc, .{ .tunnel_divert = d.target });
                }
                // Tunnel-onwards: after the tunnel call, also return from here.
                if (d.is_tunnel_onwards) {
                    try out.append(self.alloc, .eval_start);
                    try out.append(self.alloc, .void_);
                    try out.append(self.alloc, .eval_end);
                    try out.append(self.alloc, .tunnel_return);
                }
            } else if (self.var_names.contains(d.target) or self.divert_param_names.contains(d.target)) {
                // Divert to a variable containing a divert target.
                try out.append(self.alloc, .{ .divert_via_var = d.target });
            } else {
                try out.append(self.alloc, .{ .divert = d.target });
            }
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
            .expr_stmt => |expr| {
                // Standalone expression statement — evaluate and pop return value.
                try out.append(self.alloc, .eval_start);
                try self.genExpr(out, expr.*);
                try out.append(self.alloc, .pop);
                try out.append(self.alloc, .eval_end);
            },
            .return_stmt => |expr_opt| {
                try out.append(self.alloc, .eval_start);
                if (expr_opt) |expr| {
                    try self.genExpr(out, expr.*);
                } else {
                    try out.append(self.alloc, .void_);
                }
                try out.append(self.alloc, .eval_end);
                try out.append(self.alloc, .func_return);
            },
            .var_decl => {}, // handled via global_decls
            .include => {}, // TASK-84
        }
    }

    fn genInlineElement(self: *Gen, out: *std.ArrayList(CObject), elem: Parsed.InlineElement) error{OutOfMemory}!void {
        switch (elem) {
            .text => |t| {
                // Trim only leading whitespace; trailing spaces before {expr}
                // are prose and must be preserved.
                var start: usize = 0;
                while (start < t.len and (t[start] == ' ' or t[start] == '\t')) start += 1;
                var remaining = t[start..];
                // Split on <> glue markers.
                while (remaining.len > 0) {
                    if (std.mem.indexOf(u8, remaining, "<>")) |idx| {
                        if (idx > 0) try out.append(self.alloc, .{ .text = remaining[0..idx] });
                        try out.append(self.alloc, .glue);
                        remaining = remaining[idx + 2 ..];
                    } else {
                        if (remaining.len > 0) try out.append(self.alloc, .{ .text = remaining });
                        break;
                    }
                }
            },
            .glue => try out.append(self.alloc, .glue),
            .divert => |d| try self.genDivert(out, d),
            .inline_expr => |expr| {
                try out.append(self.alloc, .eval_start);
                try self.genExpr(out, expr.*);
                try out.append(self.alloc, .eval_output);
                try out.append(self.alloc, .eval_end);
            },
            .sequence => |seq| try self.genSequence(out, seq),
            .tag => |tag_text| {
                try out.append(self.alloc, .{ .string = "#" });
                try out.append(self.alloc, .{ .text = tag_text });
                try out.append(self.alloc, .{ .string = "/#" });
            },
        }
    }

    // ── Sequence (alternative) codegen ───────────────────────────────────────

    /// Generate a sequence (alternative) as a dispatch container + branch containers.
    /// Pattern: ev, visit, CLAMP, OP, /ev, (ev, du, i, ==, /ev, {->si,c})*N, nop
    ///          named children s0..s(total-1): each = [pop, ...content..., {->.^.^.N}]
    fn genSequence(self: *Gen, out: *std.ArrayList(CObject), seq: Parsed.Sequence) error{OutOfMemory}!void {
        const n_source = seq.branches.len;
        const total: usize = switch (seq.kind) {
            .once_only => n_source + 1, // extra empty branch
            else => n_source,
        };
        if (total == 0) return; // degenerate — no branches

        // Index of `nop` inside dispatch content: 5 items preamble + 6 items per branch
        const nop_index: usize = 5 + 6 * total;
        // End divert path from inside branch si (named child of dispatch):
        //   .^ → si → dispatch, .^ → dispatch (parent of si), .N → dispatch[N] = nop
        const end_path = try std.fmt.allocPrint(self.alloc, ".^.^.{}", .{nop_index});

        // Create dispatch container (visits counted for sequence index computation)
        const dispatch = try self.newContainer(null);
        dispatch.flags = 5; // VISITS_SHOULD_BE_COUNTED | TURN_INDEX_SHOULD_BE_COUNTED

        var dc = std.ArrayList(CObject).empty;
        // Preamble: ev, visit, CLAMP_or_COUNT, OP, /ev
        try dc.append(self.alloc, .eval_start);
        try dc.append(self.alloc, .{ .string = "visit" });
        switch (seq.kind) {
            .stopping => {
                try dc.append(self.alloc, .{ .int = @intCast(total - 1) });
                try dc.append(self.alloc, .{ .string = "MIN" });
            },
            .cycle => {
                try dc.append(self.alloc, .{ .int = @intCast(total) });
                try dc.append(self.alloc, .{ .string = "%" });
            },
            .once_only => {
                // Clamp to n_source (the extra empty branch is at index n_source)
                try dc.append(self.alloc, .{ .int = @intCast(n_source) });
                try dc.append(self.alloc, .{ .string = "MIN" });
            },
            .shuffle => {
                try dc.append(self.alloc, .{ .int = @intCast(total) });
                try dc.append(self.alloc, .{ .string = "seq" });
            },
        }
        try dc.append(self.alloc, .eval_end);

        // Branch dispatch: for each i, ev, du, i, ==, /ev, {->".^.si",c:true}
        for (0..total) |i| {
            const si_name = try std.fmt.allocPrint(self.alloc, "s{}", .{i});
            const si_path = try std.fmt.allocPrint(self.alloc, ".^.{s}", .{si_name});
            try dc.append(self.alloc, .eval_start);
            try dc.append(self.alloc, .dup);
            try dc.append(self.alloc, .{ .int = @intCast(i) });
            try dc.append(self.alloc, .{ .string = "==" });
            try dc.append(self.alloc, .eval_end);
            try dc.append(self.alloc, .{ .cond_divert = si_path });
        }

        // nop at index nop_index
        try dc.append(self.alloc, .nop);

        dispatch.content = try dc.toOwnedSlice(self.alloc);

        // Create branch containers si as named children of dispatch
        var named = std.ArrayList(NamedChild).empty;
        for (0..total) |i| {
            const si = try self.newContainer(null);
            var bc = std.ArrayList(CObject).empty;
            try bc.append(self.alloc, .pop);

            if (i < n_source) {
                if (!seq.is_inline) {
                    // Block form: leading newline + full flow items (each adds trailing \n)
                    try bc.append(self.alloc, .newline);
                    for (seq.branches[i]) |item| {
                        try self.genFlowItem(&bc, item, "");
                    }
                } else {
                    // Inline form: emit inline elements without surrounding newlines
                    for (seq.branches[i]) |item| {
                        switch (item) {
                            .text => |tl| for (tl.elements) |elem| try self.genInlineElement(&bc, elem),
                            else => try self.genFlowItem(&bc, item, ""),
                        }
                    }
                }
            }
            // (else: empty branch for once_only — just pop + end_divert)

            // End divert back to nop in dispatch
            try bc.append(self.alloc, .{ .divert = end_path });

            si.content = try bc.toOwnedSlice(self.alloc);
            const si_name = try std.fmt.allocPrint(self.alloc, "s{}", .{i});
            try named.append(self.alloc, .{ .name = si_name, .container = si });
        }
        dispatch.named_children = try named.toOwnedSlice(self.alloc);

        try out.append(self.alloc, .{ .container = dispatch });
    }

    // ── Weave codegen (choices & gathers) ────────────────────────────────────

    /// Process a flat list of FlowItems that contains at least one .choice or
    /// .gather, building the weave_holder container in-place.
    ///
    /// `holder_abs_path`: absolute path to `holder` from the JSON root.
    /// `is_root`:  true = pre-gather choices use absolute gather paths.
    /// `min_nesting`: the nesting level to treat as "level 1" (1 for root weave,
    ///   ch.nesting+1 when called recursively for a choice's inner_content).
    /// `outer_gather_path`: where to divert when the last gather section ends;
    ///   null at the top level (story just terminates naturally).
    fn genWeave(
        self: *Gen,
        items: []const Parsed.FlowItem,
        holder: *CContainer,
        holder_abs_path: []const u8,
        is_root: bool,
        min_nesting: u8,
        outer_gather_path: ?[]const u8,
    ) error{OutOfMemory}!void {
        // ── Phase 1: pre-scan gather names at min_nesting level ──────────────
        var gather_names = std.ArrayList([]const u8).empty;
        defer gather_names.deinit(self.alloc);
        {
            var gi: u32 = 0;
            for (items) |item| {
                switch (item) {
                    .gather => |g| if (g.nesting == min_nesting) {
                        const gname = g.label orelse
                            try std.fmt.allocPrint(self.alloc, "g-{}", .{gi});
                        try gather_names.append(self.alloc, gname);
                        gi += 1;
                    },
                    else => {},
                }
            }
        }
        // Register gather_label_paths for named gathers.
        {
            var gi: usize = 0;
            for (items) |item| {
                switch (item) {
                    .gather => |g| if (g.nesting == min_nesting) {
                        if (g.label) |lbl| {
                            const abs_path = try std.fmt.allocPrint(
                                self.alloc, "{s}.{s}", .{ holder_abs_path, lbl });
                            try self.gather_label_paths.put(self.alloc, lbl, abs_path);
                        }
                        gi += 1;
                    },
                    else => {},
                }
            }
        }

        // Determine whether the first min_nesting gather is the very first item.
        const has_initial_gather: bool = blk: {
            for (items) |item| {
                switch (item) {
                    .gather => |g| break :blk g.nesting == min_nesting,
                    else => break :blk false,
                }
            }
            break :blk false;
        };

        // ── Phase 2: state-machine pass over items ────────────────────────────
        //
        // States:
        //   pre_gather   – before any min_nesting gather; content goes into main_content.
        //   in_initial   – inside the initial inline gather section (container at pos 0).
        //   in_named     – inside a subsequent named gather section.
        //
        // For the initial section we build section_content/section_named in-place and
        // wrap them into an inline CContainer.  For subsequent named sections we also
        // build content lists and wrap them.

        const State = enum { pre_gather, in_initial, in_named };
        var state: State = .pre_gather;

        var main_content = std.ArrayList(CObject).empty;
        var main_named = std.ArrayList(NamedChild).empty;

        // Working buffers for the current section.
        var cur_content: *std.ArrayList(CObject) = &main_content;
        var cur_holder_abs: []const u8 = holder_abs_path;
        var cur_is_root: bool = is_root;
        var cur_choice_idx: u32 = 0;

        // Inline initial section scratch buffers (used only in .in_initial).
        var init_sec_content = std.ArrayList(CObject).empty;
        var init_sec_named = std.ArrayList(NamedChild).empty;
        var init_sec_container: ?*CContainer = null;

        // Named section scratch buffers (reused for each .in_named section).
        var named_sec_content = std.ArrayList(CObject).empty;
        var named_sec_named = std.ArrayList(NamedChild).empty;
        var named_sec_name: []const u8 = "";

        var gather_processed: u32 = 0; // how many min_nesting gathers we've seen

        for (items) |item| {
            switch (item) {
                // ── Gather at min_nesting level ───────────────────────────────
                .gather => |g| {
                    if (g.nesting != min_nesting) continue;

                    const gname = gather_names.items[gather_processed];

                    switch (state) {
                        .pre_gather => {
                            if (has_initial_gather and gather_processed == 0) {
                                // Transition to initial inline section.
                                state = .in_initial;
                                const sec = try self.newContainer(gname);
                                init_sec_container = sec;
                                cur_holder_abs = try std.fmt.allocPrint(
                                    self.alloc, "{s}.{s}", .{ holder_abs_path, gname });
                                cur_is_root = false;
                                cur_content = &init_sec_content;
                                cur_choice_idx = 0;
                            } else {
                                // First gather but not initial → start named section.
                                state = .in_named;
                                named_sec_name = gname;
                                cur_holder_abs = try std.fmt.allocPrint(
                                    self.alloc, "{s}.{s}", .{ holder_abs_path, gname });
                                cur_is_root = false;
                                cur_content = &named_sec_content;
                                cur_choice_idx = 0;
                            }
                        },
                        .in_initial => {
                            // Close the initial section → push it into main_content.
                            init_sec_container.?.content =
                                try init_sec_content.toOwnedSlice(self.alloc);
                            init_sec_container.?.named_children =
                                try init_sec_named.toOwnedSlice(self.alloc);
                            try main_content.append(
                                self.alloc, .{ .container = init_sec_container.? });
                            init_sec_container = null;
                            // Start the next named section.
                            state = .in_named;
                            named_sec_name = gname;
                            cur_holder_abs = try std.fmt.allocPrint(
                                self.alloc, "{s}.{s}", .{ holder_abs_path, gname });
                            cur_is_root = false;
                            cur_content = &named_sec_content;
                            cur_choice_idx = 0;
                        },
                        .in_named => {
                            // Close the current named section → push as named_child.
                            const gc = try self.newContainer(null);
                            gc.content = try named_sec_content.toOwnedSlice(self.alloc);
                            gc.named_children =
                                try named_sec_named.toOwnedSlice(self.alloc);
                            try main_named.append(
                                self.alloc, .{ .name = named_sec_name, .container = gc });
                            // Start fresh named section.
                            named_sec_name = gname;
                            cur_holder_abs = try std.fmt.allocPrint(
                                self.alloc, "{s}.{s}", .{ holder_abs_path, gname });
                            cur_choice_idx = 0;
                        },
                    }
                    gather_processed += 1;
                },

                // ── Choice at min_nesting level ───────────────────────────────
                .choice => |ch| {
                    if (ch.nesting != min_nesting) continue;

                    // Compute gather_path: where should c-N divert after selection?
                    // (Only needed when inner_content has no nested weave of its own.)
                    const next_gi = gather_processed; // index of next gather after this choice
                    const gather_path: []const u8 = gp: {
                        if (next_gi < gather_names.items.len) {
                            const next_gname = gather_names.items[next_gi];
                            // If we're in a section (not directly in holder), the next
                            // gather is a named_child of the OUTER holder → absolute.
                            // If we're directly in the holder, use is_root to decide.
                            if (state == .pre_gather) {
                                if (cur_is_root) {
                                    break :gp try std.fmt.allocPrint(
                                        self.alloc, "{s}.{s}", .{ holder_abs_path, next_gname });
                                } else {
                                    break :gp try std.fmt.allocPrint(
                                        self.alloc, ".^.^.{s}", .{next_gname});
                                }
                            } else {
                                // Inside a section: the next gather is in the outer holder.
                                break :gp try std.fmt.allocPrint(
                                    self.alloc, "{s}.{s}", .{ holder_abs_path, next_gname });
                            }
                        } else if (outer_gather_path) |ogp| {
                            break :gp ogp;
                        } else {
                            // No gathers at all and no outer path: implicit g-0.
                            break :gp if (cur_is_root)
                                try std.fmt.allocPrint(
                                    self.alloc, "{s}.g-0", .{holder_abs_path})
                            else
                                ".^.^.g-0";
                        }
                    };

                    // For choices inside a section, the cur_named must point to the
                    // section's named list, not main_named.
                    const cur_named_ptr = switch (state) {
                        .pre_gather => &main_named,
                        .in_initial => &init_sec_named,
                        .in_named => &named_sec_named,
                    };

                    try self.genChoiceInWeave(
                        cur_content,
                        cur_named_ptr,
                        ch,
                        cur_choice_idx,
                        cur_holder_abs,
                        cur_is_root,
                        gather_path,
                        min_nesting,
                    );
                    cur_choice_idx += 1;
                },

                // ── Other items ───────────────────────────────────────────────
                else => try self.genFlowItem(cur_content, item, cur_holder_abs),
            }
        }

        // ── Finalize any open section ─────────────────────────────────────────
        switch (state) {
            .pre_gather => {
                // No gathers encountered.  If we had choices, add implicit g-0 done.
                if (cur_choice_idx > 0 and gather_names.items.len == 0) {
                    const g0 = try self.newContainer(null);
                    g0.content = try self.alloc.dupe(CObject, &.{.done});
                    try main_named.append(self.alloc, .{ .name = "g-0", .container = g0 });
                }
            },
            .in_initial => {
                // Only initial section (no subsequent gathers).
                // Append outer_gather_path divert if provided.
                if (outer_gather_path) |ogp| {
                    try init_sec_content.append(self.alloc, .{ .divert = ogp });
                }
                init_sec_container.?.content =
                    try init_sec_content.toOwnedSlice(self.alloc);
                init_sec_container.?.named_children =
                    try init_sec_named.toOwnedSlice(self.alloc);
                try main_content.append(self.alloc, .{ .container = init_sec_container.? });
            },
            .in_named => {
                // Append outer_gather_path divert to last named section if provided.
                if (outer_gather_path) |ogp| {
                    try named_sec_content.append(self.alloc, .{ .divert = ogp });
                }
                const gc = try self.newContainer(null);
                gc.content = try named_sec_content.toOwnedSlice(self.alloc);
                gc.named_children = try named_sec_named.toOwnedSlice(self.alloc);
                try main_named.append(self.alloc, .{ .name = named_sec_name, .container = gc });
            },
        }

        holder.content = try main_content.toOwnedSlice(self.alloc);
        holder.named_children = try main_named.toOwnedSlice(self.alloc);
    }

    /// Emit one choice into the weave holder's main_content and named lists.
    ///
    /// `gather_path`: where c-N should divert after the choice is taken (the
    ///   next gather container).  Computed by the caller (genWeave).
    /// `min_nesting`: the nesting level of the current weave; nested choices
    ///   at nesting > min_nesting in inner_content trigger a recursive call.
    fn genChoiceInWeave(
        self: *Gen,
        main_content: *std.ArrayList(CObject),
        named: *std.ArrayList(NamedChild),
        ch: Parsed.Choice,
        choice_idx: u32,
        holder_abs_path: []const u8,
        is_root: bool,
        gather_path: []const u8,
        min_nesting: u8,
    ) error{OutOfMemory}!void {
        const c_name = try std.fmt.allocPrint(self.alloc, "c-{}", .{choice_idx});
        // Absolute path to c-N for divert target values.
        const c_abs = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ holder_abs_path, c_name });

        // Register choice label if present.
        if (ch.label) |lbl| {
            try self.choice_labels.put(self.alloc, lbl, c_abs);
        }

        // Compute flags.
        const is_fallback = isFallbackChoice(ch);
        const has_start = ch.start_content.len > 0;
        const has_choice_only = ch.choice_only_content.len > 0;
        var flg: u32 = 0;
        if (ch.condition != null) flg |= 0x01;
        if (has_start) flg |= 0x02;
        if (has_choice_only) flg |= 0x04;
        if (is_fallback) flg |= 0x08;
        if (!ch.is_sticky) flg |= 0x10;

        // c-N container flags: 5 for once-only, 0 for sticky.
        const c_flags: u32 = if (!ch.is_sticky) 5 else 0;

        // Detect whether inner_content has a nested weave (choices/gathers at
        // nesting > min_nesting).
        const has_nested_weave = itemsHaveChoicesAtNesting(ch.inner_content, min_nesting + 1);

        if (is_fallback) {
            // ── Fallback choice: just a choice_point in main_content ──────────
            const cp_path = if (is_root)
                try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ holder_abs_path, c_name })
            else
                try std.fmt.allocPrint(self.alloc, ".^.{s}", .{c_name});
            try main_content.append(self.alloc, .{ .choice_point = .{ .path = cp_path, .flags = flg } });

            var c_body = std.ArrayList(CObject).empty;
            try c_body.append(self.alloc, .newline);
            try c_body.append(self.alloc, .{ .divert = gather_path });
            const cc = try self.newContainer(null);
            cc.flags = c_flags;
            cc.content = try c_body.toOwnedSlice(self.alloc);
            try named.append(self.alloc, .{ .name = c_name, .container = cc });
        } else if (!has_start) {
            // ── Brackets-only (or condition-only): eval block in main_content ──
            try main_content.append(self.alloc, .eval_start);
            try main_content.append(self.alloc, .{ .string = "str" });
            for (ch.choice_only_content) |elem| {
                try self.genInlineElement(main_content, elem);
            }
            try main_content.append(self.alloc, .{ .string = "/str" });
            // Condition expressions go between /str and /ev.
            if (ch.condition) |cond| try self.genExpr(main_content, cond.*);
            try main_content.append(self.alloc, .eval_end);

            const cp_path = if (is_root)
                try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ holder_abs_path, c_name })
            else
                try std.fmt.allocPrint(self.alloc, ".^.{s}", .{c_name});
            try main_content.append(self.alloc, .{ .choice_point = .{ .path = cp_path, .flags = flg } });

            // c-N body: following_content (if any) then "\n" then inner.
            var c_body = std.ArrayList(CObject).empty;
            for (ch.following_content) |elem| {
                try self.genInlineElement(&c_body, elem);
            }
            try c_body.append(self.alloc, .newline);
            if (has_nested_weave) {
                try self.genNestedWeave(&c_body, ch.inner_content, c_abs, min_nesting + 1, gather_path);
            } else {
                for (ch.inner_content) |inner| {
                    try self.genFlowItem(&c_body, inner, c_abs);
                }
                try c_body.append(self.alloc, .{ .divert = gather_path });
            }
            const cc = try self.newContainer(null);
            cc.flags = c_flags;
            cc.content = try c_body.toOwnedSlice(self.alloc);
            try named.append(self.alloc, .{ .name = c_name, .container = cc });
        } else {
            // ── Start-text choice: sub-inner container ────────────────────────
            const sub_inner_pos = main_content.items.len;
            const sub_inner_abs = try std.fmt.allocPrint(self.alloc, "{s}.{}", .{ holder_abs_path, sub_inner_pos });
            const r1_path = try std.fmt.allocPrint(self.alloc, "{s}.$r1", .{sub_inner_abs});
            const r2_path = try std.fmt.allocPrint(self.alloc, "{s}.$r2", .{c_abs});

            // choice_point path: relative from sub_inner (two ^s) or absolute.
            const cp_path = if (is_root)
                try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ holder_abs_path, c_name })
            else
                try std.fmt.allocPrint(self.alloc, ".^.^.{s}", .{c_name});

            // Path from c-N to sub_inner.s.
            const s_path = if (is_root)
                try std.fmt.allocPrint(self.alloc, "{s}.{}.s", .{ holder_abs_path, sub_inner_pos })
            else
                try std.fmt.allocPrint(self.alloc, ".^.^.{}.s", .{sub_inner_pos});

            // Build sub-inner container.
            var si_body = std.ArrayList(CObject).empty;
            try si_body.append(self.alloc, .eval_start);
            try si_body.append(self.alloc, .{ .divert_target_val = r1_path });
            try si_body.append(self.alloc, .{ .temp_assign = .{ .name = "$r", .is_new = true } });
            try si_body.append(self.alloc, .{ .string = "str" });
            try si_body.append(self.alloc, .{ .divert = ".^.s" });
            // $r1 label: empty named container inline.
            const r1_label = try self.newContainer("$r1");
            r1_label.content = &.{};
            try si_body.append(self.alloc, .{ .container = r1_label });
            try si_body.append(self.alloc, .{ .string = "/str" });
            // Optional choice-only block.
            if (has_choice_only) {
                try si_body.append(self.alloc, .{ .string = "str" });
                for (ch.choice_only_content) |elem| {
                    try self.genInlineElement(&si_body, elem);
                }
                try si_body.append(self.alloc, .{ .string = "/str" });
            }
            // Condition expressions go between /str (or choice-only /str) and /ev.
            if (ch.condition) |cond| try self.genExpr(&si_body, cond.*);
            try si_body.append(self.alloc, .eval_end);
            try si_body.append(self.alloc, .{ .choice_point = .{ .path = cp_path, .flags = flg } });

            // "s" named child: start_content + divert_via_var "$r".
            var s_body = std.ArrayList(CObject).empty;
            for (ch.start_content) |elem| {
                try self.genInlineElement(&s_body, elem);
            }
            try s_body.append(self.alloc, .{ .divert_via_var = "$r" });
            const s_c = try self.newContainer(null);
            s_c.content = try s_body.toOwnedSlice(self.alloc);

            const sub_inner = try self.newContainer(null);
            sub_inner.content = try si_body.toOwnedSlice(self.alloc);
            sub_inner.named_children = try self.alloc.dupe(NamedChild, &.{
                .{ .name = "s", .container = s_c },
            });
            try main_content.append(self.alloc, .{ .container = sub_inner });

            // Build c-N body.
            var c_body = std.ArrayList(CObject).empty;
            try c_body.append(self.alloc, .eval_start);
            try c_body.append(self.alloc, .{ .divert_target_val = r2_path });
            try c_body.append(self.alloc, .eval_end);
            try c_body.append(self.alloc, .{ .temp_assign = .{ .name = "$r", .is_new = true } });
            try c_body.append(self.alloc, .{ .divert = s_path });
            // $r2 label.
            const r2_label = try self.newContainer("$r2");
            r2_label.content = &.{};
            try c_body.append(self.alloc, .{ .container = r2_label });
            // Following content (inline elements on the choice line after brackets).
            for (ch.following_content) |elem| {
                try self.genInlineElement(&c_body, elem);
            }
            try c_body.append(self.alloc, .newline);
            // Inner content (body lines after the choice line).
            if (has_nested_weave) {
                try self.genNestedWeave(&c_body, ch.inner_content, c_abs, min_nesting + 1, gather_path);
            } else {
                for (ch.inner_content) |inner| {
                    try self.genFlowItem(&c_body, inner, c_abs);
                }
                try c_body.append(self.alloc, .{ .divert = gather_path });
            }
            const cc = try self.newContainer(null);
            cc.flags = c_flags;
            cc.content = try c_body.toOwnedSlice(self.alloc);
            try named.append(self.alloc, .{ .name = c_name, .container = cc });
        }
    }

    /// Generate a nested weave (inner_content of a choice that has deeper
    /// choices/gathers) into `out` as an inline wrapper container.
    ///
    /// The wrapper is placed at the current end of `out`.  `outer_gather_path`
    /// is what the innermost choices/gathers should divert to when done.
    fn genNestedWeave(
        self: *Gen,
        out: *std.ArrayList(CObject),
        items: []const Parsed.FlowItem,
        parent_abs: []const u8,
        new_min_nesting: u8,
        outer_gather_path: []const u8,
    ) error{OutOfMemory}!void {
        const wrapper_pos = out.items.len;
        const wrapper_abs = try std.fmt.allocPrint(self.alloc, "{s}.{}", .{ parent_abs, wrapper_pos });

        const wrapper = try self.newContainer(null);
        try self.genWeave(items, wrapper, wrapper_abs, false, new_min_nesting, outer_gather_path);

        try out.append(self.alloc, .{ .container = wrapper });
    }

    // ── Conditional codegen ──────────────────────────────────────────────────

    fn genConditional(self: *Gen, out: *std.ArrayList(CObject), cond: Parsed.Conditional, parent_path: []const u8) error{OutOfMemory}!void {
        const initial_len = out.items.len;

        // --- 1. Compute outer eval items (if any) ---
        // For outer_condition forms (is_inline or block with outer cond),
        // the eval goes directly into the parent container.
        var eval_count: usize = 0;
        if (cond.outer_condition) |oc| {
            const start = out.items.len;
            try out.append(self.alloc, .eval_start);
            try self.genExpr(out, oc.*);
            try out.append(self.alloc, .eval_end);
            eval_count = out.items.len - start;
        }

        // --- 2. Compute nop index ---
        const pop_count: usize = if (cond.is_switch) 1 else 0;
        const nop_idx = initial_len + eval_count + cond.branches.len + pop_count;
        const nop_path = try std.fmt.allocPrint(self.alloc, "{s}.{}", .{ parent_path, nop_idx });

        // --- 3. Emit branch wrappers ---
        for (cond.branches, 0..) |branch, i| {
            const wrapper_idx = initial_len + eval_count + i;
            const body_path = try std.fmt.allocPrint(self.alloc, "{s}.{}.b", .{ parent_path, wrapper_idx });

            // Build the body container content.
            var body = std.ArrayList(CObject).empty;

            if (cond.is_switch) {
                // Switch body starts with "pop" (consume the duplicated value).
                try body.append(self.alloc, .pop);
            }
            if (!cond.is_inline) {
                // Block form: leading newline before content.
                try body.append(self.alloc, .newline);
            }
            if (cond.is_inline) {
                for (branch.inline_elems) |elem| {
                    try self.genInlineElement(&body, elem);
                }
            } else {
                for (branch.content) |item| {
                    try self.genFlowItem(&body, item, body_path);
                }
            }
            // Convergence divert — jumps to the nop.
            try body.append(self.alloc, .{ .divert = nop_path });

            const body_c = try self.newContainer(null);
            body_c.content = try body.toOwnedSlice(self.alloc);

            // Build the branch wrapper container content.
            var wrapper_content = std.ArrayList(CObject).empty;

            if (cond.is_switch) {
                // Switch: dup, ev, case_expr, "==", /ev, branch_divert_true
                try wrapper_content.append(self.alloc, .dup);
                try wrapper_content.append(self.alloc, .eval_start);
                if (branch.condition) |case_expr| {
                    try self.genExpr(&wrapper_content, case_expr.*);
                }
                try wrapper_content.append(self.alloc, .{ .string = "==" });
                try wrapper_content.append(self.alloc, .eval_end);
                try wrapper_content.append(self.alloc, .{ .cond_divert = ".^.b" });
            } else if (cond.outer_condition != null) {
                // Outer-condition (boolean or inline): first branch → conditional jump,
                // subsequent branches → unconditional jump.
                if (i == 0) {
                    try wrapper_content.append(self.alloc, .{ .cond_divert = ".^.b" });
                } else {
                    try wrapper_content.append(self.alloc, .{ .divert = ".^.b" });
                }
            } else {
                // Multi-branch: each branch has its own eval + conditional jump,
                // except the else branch (no condition) which is unconditional.
                if (branch.condition) |cond_expr| {
                    try wrapper_content.append(self.alloc, .eval_start);
                    try self.genExpr(&wrapper_content, cond_expr.*);
                    try wrapper_content.append(self.alloc, .eval_end);
                    try wrapper_content.append(self.alloc, .{ .cond_divert = ".^.b" });
                } else {
                    try wrapper_content.append(self.alloc, .{ .divert = ".^.b" });
                }
            }

            const wrapper = try self.newContainer(null);
            wrapper.content = try wrapper_content.toOwnedSlice(self.alloc);
            wrapper.named_children = try self.alloc.dupe(NamedChild, &.{
                .{ .name = "b", .container = body_c },
            });

            try out.append(self.alloc, .{ .container = wrapper });
        }

        // --- 4. Switch pop ---
        if (cond.is_switch) {
            try out.append(self.alloc, .pop);
        }

        // --- 5. Nop + trailing newline ---
        try out.append(self.alloc, .nop);
        try out.append(self.alloc, .newline);
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
                } else if (self.choice_labels.get(name)) |c_path| {
                    // Choice label in an expression → read-count of that choice.
                    try out.append(self.alloc, .{ .read_count = c_path });
                } else if (self.knot_names.contains(name)) {
                    // Bare knot/stitch name in an expression → visit-count check.
                    try out.append(self.alloc, .{ .read_count = name });
                } else {
                    try out.append(self.alloc, .{ .var_ref = name });
                }
            },
            .read_count => |path| try out.append(self.alloc, .{ .read_count = path }),
            .divert_target => |path| try out.append(self.alloc, .{ .divert_target_val = path }),
            .call => |c| {
                // Push arguments left-to-right, then emit the call.
                for (c.args) |arg| try self.genExpr(out, arg.*);
                if (self.external_fn_names.contains(c.name)) {
                    try out.append(self.alloc, .{ .external_call = .{
                        .name = c.name,
                        .arg_count = @intCast(c.args.len),
                    } });
                } else {
                    try out.append(self.alloc, .{ .function_call = .{
                        .name = c.name,
                        .arg_count = @intCast(c.args.len),
                    } });
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

/// True when any item in `items` is a choice or gather.
fn itemsHaveChoices(items: []const Parsed.FlowItem) bool {
    for (items) |item| {
        if (item == .choice or item == .gather) return true;
    }
    return false;
}

/// True when any item has .choice or .gather at exactly `nesting`.
fn itemsHaveChoicesAtNesting(items: []const Parsed.FlowItem, nesting: u8) bool {
    for (items) |item| {
        switch (item) {
            .choice => |ch| if (ch.nesting == nesting) return true,
            .gather => |g| if (g.nesting == nesting) return true,
            else => {},
        }
    }
    return false;
}

/// True when `ch` is a fallback (invisible-default) choice:
/// no start content, no choice-only content, no condition,
/// and the following content is empty or a bare `->` with no target.
fn isFallbackChoice(ch: Parsed.Choice) bool {
    if (ch.start_content.len > 0) return false;
    if (ch.choice_only_content.len > 0) return false;
    if (ch.condition != null) return false;
    if (ch.following_content.len == 0) return true;
    if (ch.following_content.len == 1) {
        const fc = ch.following_content[0];
        if (fc == .divert and fc.divert.target.len == 0) return true;
    }
    return false;
}

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
        .has => "?",
        .hasnt => "!?",
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
