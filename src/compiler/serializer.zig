/// Ink compiler serializer — converts a CContainer tree to a JSON string.
///
/// Output format matches the ink.json runtime format consumed by json_loader.zig:
///   {"inkVersion":21,"root":[...],"listDefs":{}}
///
/// Container arrays end with:
///   - `null`  when the container has no name, no flags, no meta-named children
///   - `{...}` with "#n", "#f", and/or named-child entries otherwise
const std = @import("std");
const cg = @import("codegen.zig");
const CContainer = cg.CContainer;
const CObject = cg.CObject;
const fmt = @import("../ink_format.zig");

// ── Public entry point ────────────────────────────────────────────────────────

const Parsed = @import("parsed.zig");

/// Serialize the root CContainer to a complete ink.json string.
/// The returned slice is allocated with `alloc` (caller owns it).
pub fn serialize(alloc: std.mem.Allocator, root: *const CContainer) ![]u8 {
    return serializeWithListDefs(alloc, root, &.{});
}

/// Serialize the root CContainer + list defs to a complete ink.json string.
pub fn serializeWithListDefs(alloc: std.mem.Allocator, root: *const CContainer, list_defs: []const Parsed.ListDef) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);

    try buf.appendSlice(alloc, "{\"" ++ fmt.key_ink_version ++ "\":21,\"" ++ fmt.key_root ++ "\":");
    try serContainer(alloc, &buf, root);
    try buf.appendSlice(alloc, ",\"" ++ fmt.key_list_defs ++ "\":{");
    for (list_defs, 0..) |ld, li| {
        if (li > 0) try buf.append(alloc, ',');
        try buf.append(alloc, '"');
        try writeJsonStr(alloc, &buf, ld.name);
        try buf.appendSlice(alloc, "\":{");
        for (ld.items, 0..) |item, ii| {
            if (ii > 0) try buf.append(alloc, ',');
            try buf.append(alloc, '"');
            // listDefs item keys are unqualified (just "itemName", not "listName.itemName").
            try writeJsonStr(alloc, &buf, item.name);
            try buf.appendSlice(alloc, "\":");
            var tmp: [32]u8 = undefined;
            const val = item.value orelse 0;
            const s = std.fmt.bufPrint(&tmp, "{}", .{val}) catch unreachable;
            try buf.appendSlice(alloc, s);
        }
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "}}");

    return buf.toOwnedSlice(alloc);
}

// ── Internal helpers ──────────────────────────────────────────────────────────

const SerError = std.mem.Allocator.Error;

fn serContainer(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), c: *const CContainer) SerError!void {
    try buf.append(alloc, '[');

    var first = true;
    for (c.content) |obj| {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try serObject(alloc, buf, obj);
    }

    // Trailing element: null or metadata object.
    const has_meta = c.own_name != null or c.flags != 0 or c.named_children.len > 0;
    if (!first) try buf.append(alloc, ',');
    if (!has_meta) {
        try buf.appendSlice(alloc, "null");
    } else {
        try buf.append(alloc, '{');
        var mfirst = true;
        if (c.own_name) |n| {
            try buf.appendSlice(alloc, "\"" ++ fmt.key_meta_name ++ "\":\"");
            try writeJsonStr(alloc, buf, n);
            try buf.append(alloc, '"');
            mfirst = false;
        }
        if (c.flags != 0) {
            if (!mfirst) try buf.append(alloc, ',');
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "\"" ++ fmt.key_meta_flags ++ "\":{}", .{c.flags}) catch unreachable;
            try buf.appendSlice(alloc, s);
            mfirst = false;
        }
        for (c.named_children) |nc| {
            if (!mfirst) try buf.append(alloc, ',');
            try buf.append(alloc, '"');
            try writeJsonStr(alloc, buf, nc.name);
            try buf.appendSlice(alloc, "\":");
            try serContainer(alloc, buf, nc.container);
            mfirst = false;
        }
        try buf.append(alloc, '}');
    }

    try buf.append(alloc, ']');
}

fn serObject(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), obj: CObject) SerError!void {
    switch (obj) {
        .text => |t| {
            try buf.appendSlice(alloc, "\"" ++ fmt.text_prefix);
            try writeJsonStr(alloc, buf, t);
            try buf.append(alloc, '"');
        },
        .newline => try buf.appendSlice(alloc, "\"\\n\""),
        .done => try buf.appendSlice(alloc, "\"done\""),
        .end => try buf.appendSlice(alloc, "\"end\""),
        .tunnel_return => try buf.appendSlice(alloc, "\"->->\""),
        .glue => try buf.appendSlice(alloc, "\"<>\""),
        .divert => |t| {
            try buf.appendSlice(alloc, "{\"" ++ fmt.key_divert ++ "\":\"");
            try writeJsonStr(alloc, buf, t);
            try buf.appendSlice(alloc, "\"}");
        },
        .tunnel_divert => |t| {
            try buf.appendSlice(alloc, "{\"" ++ fmt.key_tunnel_divert ++ "\":\"");
            try writeJsonStr(alloc, buf, t);
            try buf.appendSlice(alloc, "\"}");
        },
        .tunnel_divert_via_var => |name| {
            try buf.appendSlice(alloc, "{\"" ++ fmt.key_tunnel_divert ++ "\":\"");
            try writeJsonStr(alloc, buf, name);
            try buf.appendSlice(alloc, "\",\"" ++ fmt.key_is_variable ++ "\":true}");
        },
        .container => |c| try serContainer(alloc, buf, c),
        .eval_start => try buf.appendSlice(alloc, "\"ev\""),
        .eval_end => try buf.appendSlice(alloc, "\"/ev\""),
        .eval_output => try buf.appendSlice(alloc, "\"out\""),
        .pop => try buf.appendSlice(alloc, "\"pop\""),
        .void_ => try buf.appendSlice(alloc, "\"void\""),
        .nop => try buf.appendSlice(alloc, "\"nop\""),
        .int => |n| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{}", .{n}) catch unreachable;
            try buf.appendSlice(alloc, s);
        },
        .float => |f| {
            var tmp: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
            try buf.appendSlice(alloc, s);
            // Ensure a decimal point so the runtime parses this as a float.
            if (std.mem.indexOfScalar(u8, s, '.') == null and
                std.mem.indexOfScalar(u8, s, 'e') == null)
            {
                try buf.appendSlice(alloc, ".0");
            }
        },
        .bool_ => |b| {
            if (b) try buf.appendSlice(alloc, "true") else try buf.appendSlice(alloc, "false");
        },
        .string => |s| {
            try buf.append(alloc, '"');
            try writeJsonStr(alloc, buf, s);
            try buf.append(alloc, '"');
        },
        .var_assign => |va| {
            try buf.appendSlice(alloc, "{\"" ++ fmt.key_var_assign ++ "\":\"");
            try writeJsonStr(alloc, buf, va.name);
            if (va.is_new) {
                try buf.appendSlice(alloc, "\"}");
            } else {
                try buf.appendSlice(alloc, "\",\"" ++ fmt.key_reassign ++ "\":true}");
            }
        },
        .var_ref => |name| {
            try buf.appendSlice(alloc, "{\"" ++ fmt.key_var_ref ++ "\":\"");
            try writeJsonStr(alloc, buf, name);
            try buf.appendSlice(alloc, "\"}");
        },
        .var_pointer => |vp| {
            try buf.appendSlice(alloc, "{\"" ++ fmt.key_var_pointer ++ "\":\"");
            try writeJsonStr(alloc, buf, vp.name);
            try buf.appendSlice(alloc, "\",\"" ++ fmt.key_var_pointer_ctx ++ "\":");
            var tmp: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{}", .{vp.context_idx}) catch unreachable;
            try buf.appendSlice(alloc, s);
            try buf.append(alloc, '}');
        },
        .temp_assign => |ta| {
            try buf.appendSlice(alloc, "{\"" ++ fmt.key_temp_assign ++ "\":\"");
            try writeJsonStr(alloc, buf, ta.name);
            if (ta.is_new) {
                try buf.appendSlice(alloc, "\"}");
            } else {
                try buf.appendSlice(alloc, "\",\"" ++ fmt.key_reassign ++ "\":true}");
            }
        },
        .cond_divert => |path| {
            try buf.appendSlice(alloc, "{\"" ++ fmt.key_divert ++ "\":\"");
            try writeJsonStr(alloc, buf, path);
            try buf.appendSlice(alloc, "\",\"" ++ fmt.key_conditional ++ "\":true}");
        },
        .dup => try buf.appendSlice(alloc, "\"du\""),
        .choice_point => |cp| {
            try buf.appendSlice(alloc, "{\"" ++ fmt.key_choice_point ++ "\":\"");
            try writeJsonStr(alloc, buf, cp.path);
            try buf.appendSlice(alloc, "\",\"" ++ fmt.key_choice_flags ++ "\":");
            var tmp: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{}", .{cp.flags}) catch unreachable;
            try buf.appendSlice(alloc, s);
            try buf.append(alloc, '}');
        },
        .divert_target_val => |path| {
            try buf.appendSlice(alloc, "{\"" ++ fmt.key_divert_target_val ++ "\":\"");
            try writeJsonStr(alloc, buf, path);
            try buf.appendSlice(alloc, "\"}");
        },
        .divert_via_var => |name| {
            try buf.appendSlice(alloc, "{\"" ++ fmt.key_divert ++ "\":\"");
            try writeJsonStr(alloc, buf, name);
            try buf.appendSlice(alloc, "\",\"" ++ fmt.key_is_variable ++ "\":true}");
        },
        .read_count => |path| {
            try buf.appendSlice(alloc, "{\"" ++ fmt.key_read_count ++ "\":\"");
            try writeJsonStr(alloc, buf, path);
            try buf.appendSlice(alloc, "\"}");
        },
        .func_return => try buf.appendSlice(alloc, "\"~ret\""),
        .function_call => |fc| {
            // {"f()":"name"} for 0 args, {"f(N)":"name"} for N args.
            var tmp: [32]u8 = undefined;
            const key = if (fc.arg_count == 0)
                "\"" ++ fmt.key_function_call_0 ++ "\":"
            else blk: {
                const s = std.fmt.bufPrint(&tmp, "\"f({})\":", .{fc.arg_count}) catch unreachable;
                break :blk s;
            };
            try buf.append(alloc, '{');
            try buf.appendSlice(alloc, key);
            try buf.append(alloc, '"');
            try writeJsonStr(alloc, buf, fc.name);
            try buf.append(alloc, '"');
            if (fc.is_var) try buf.appendSlice(alloc, ",\"" ++ fmt.key_is_variable ++ "\":true");
            try buf.append(alloc, '}');
        },
        .external_call => |ec| {
            // {"x()":"name","exArgs":N}
            try buf.append(alloc, '{');
            try buf.appendSlice(alloc, "\"" ++ fmt.key_external_call ++ "\":");
            try buf.append(alloc, '"');
            try writeJsonStr(alloc, buf, ec.name);
            var tmp2: [32]u8 = undefined;
            const args_s = std.fmt.bufPrint(&tmp2, "\",\"" ++ fmt.key_external_args ++ "\":{}}}", .{ec.arg_count}) catch unreachable;
            try buf.appendSlice(alloc, args_s);
        },
        .list_val => |lv| {
            // Non-empty: {"list":{"origin.item":value,...}}
            // Empty with origin: {"list":{},"origins":["origin",...]}
            try buf.appendSlice(alloc, "{\"" ++ fmt.key_list ++ "\":{");
            for (lv.entries, 0..) |e, i| {
                if (i > 0) try buf.append(alloc, ',');
                try buf.append(alloc, '"');
                try writeJsonStr(alloc, buf, e.key);
                var tmp: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "\":{}", .{e.value}) catch unreachable;
                try buf.appendSlice(alloc, s);
            }
            try buf.append(alloc, '}');
            if (lv.entries.len == 0 and lv.origins.len > 0) {
                try buf.appendSlice(alloc, ",\"" ++ fmt.key_list_origins ++ "\":[");
                for (lv.origins, 0..) |o, i| {
                    if (i > 0) try buf.append(alloc, ',');
                    try buf.append(alloc, '"');
                    try writeJsonStr(alloc, buf, o);
                    try buf.append(alloc, '"');
                }
                try buf.append(alloc, ']');
            }
            try buf.append(alloc, '}');
        },
    }
}

/// Write `s` into `buf` with JSON string escaping (no surrounding quotes).
/// Reserves worst-case capacity up front so the inner loop never allocates.
fn writeJsonStr(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    // Every byte may expand to at most 2 bytes (e.g. '\n' → "\\n").
    try buf.ensureUnusedCapacity(alloc, s.len * 2);
    for (s) |ch| {
        switch (ch) {
            '"' => buf.appendSliceAssumeCapacity("\\\""),
            '\\' => buf.appendSliceAssumeCapacity("\\\\"),
            '\n' => buf.appendSliceAssumeCapacity("\\n"),
            '\r' => buf.appendSliceAssumeCapacity("\\r"),
            '\t' => buf.appendSliceAssumeCapacity("\\t"),
            else => buf.appendAssumeCapacity(ch),
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Compiler serializer: empty story" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const codegen = @import("codegen.zig");

    const story = Parsed.Story{
        .list_defs = &.{},
        .global_decls = &.{},
        .constants = &.{},
        .external_fns = &.{},
        .includes = &.{},
        .knots = &.{},
        .root_content = &.{},
    };
    const root = try codegen.generate(aa, story);
    const json = try serialize(alloc, root);
    defer alloc.free(json);

    // Expected: {"inkVersion":21,"root":[[["done",{"#n":"g-0"}],null],"done",null],"listDefs":{}}
    try std.testing.expectEqualStrings(
        "{\"inkVersion\":21,\"root\":[[[\"done\",{\"#n\":\"g-0\"}],null],\"done\",null],\"listDefs\":{}}",
        json,
    );
}

test "Compiler serializer: hello world" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const parser = @import("parser.zig");
    const codegen = @import("codegen.zig");

    const src = "Hello world\n";
    const story = try parser.parse(aa, src);
    const root = try codegen.generate(aa, story);
    const json = try serialize(alloc, root);
    defer alloc.free(json);

    try std.testing.expectEqualStrings(
        "{\"inkVersion\":21,\"root\":[[\"^Hello world\",\"\\n\",[\"done\",{\"#n\":\"g-0\"}],null],\"done\",null],\"listDefs\":{}}",
        json,
    );
}
