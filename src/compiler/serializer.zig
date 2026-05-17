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
const Parsed = @import("parsed.zig");

// ── Public entry points ───────────────────────────────────────────────────────

/// Serialize the root CContainer to a complete ink.json string.
/// The returned slice is allocated with `alloc` (caller owns it).
pub fn serialize(alloc: std.mem.Allocator, root: *const CContainer) ![]u8 {
    return serializeWithListDefs(alloc, root, &.{});
}

/// Serialize the root CContainer + list defs to a complete ink.json string.
pub fn serializeWithListDefs(alloc: std.mem.Allocator, root: *const CContainer, list_defs: []const Parsed.ListDef) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    var ws: std.json.Stringify = .{ .writer = &aw.writer };

    try ws.beginObject();

    try ws.objectField(fmt.key_ink_version);
    try ws.write(@as(u32, 21));

    try ws.objectField(fmt.key_root);
    try serContainer(&ws, root);

    try ws.objectField(fmt.key_list_defs);
    try ws.beginObject();
    for (list_defs) |ld| {
        try ws.objectField(ld.name);
        try ws.beginObject();
        for (ld.items) |item| {
            // item keys are unqualified ("itemName" not "listName.itemName").
            try ws.objectField(item.name);
            try ws.write(item.value orelse @as(i32, 0));
        }
        try ws.endObject();
    }
    try ws.endObject();

    try ws.endObject();

    return aw.toOwnedSlice();
}

// ── Internal helpers ──────────────────────────────────────────────────────────

fn serContainer(ws: *std.json.Stringify, c: *const CContainer) anyerror!void {
    try ws.beginArray();

    for (c.content) |obj| {
        try serObject(ws, obj);
    }

    // Trailing element: null or metadata object.
    const has_meta = c.own_name != null or c.flags != 0 or c.named_children.len > 0;
    if (!has_meta) {
        try ws.print("null", .{});
    } else {
        try ws.beginObject();
        if (c.own_name) |n| {
            try ws.objectField(fmt.key_meta_name);
            try ws.write(n);
        }
        if (c.flags != 0) {
            try ws.objectField(fmt.key_meta_flags);
            try ws.write(c.flags);
        }
        for (c.named_children) |nc| {
            try ws.objectField(nc.name);
            try serContainer(ws, nc.container);
        }
        try ws.endObject();
    }

    try ws.endArray();
}

fn serObject(ws: *std.json.Stringify, obj: CObject) anyerror!void {
    switch (obj) {
        .text => |t| {
            // Prefix with ^ then write as a JSON string.
            // Use beginWriteRaw + encodeJsonStringChars to avoid a heap allocation.
            try ws.beginWriteRaw();
            try ws.writer.writeByte('"');
            try ws.writer.writeByte(fmt.text_prefix_char);
            try std.json.Stringify.encodeJsonStringChars(t, .{}, ws.writer);
            try ws.writer.writeByte('"');
            ws.endWriteRaw();
        },
        .newline => try ws.write("\n"),
        .done => try ws.write("done"),
        .end => try ws.write("end"),
        .tunnel_return => try ws.write("->->"),
        .glue => try ws.write("<>"),
        .divert => |t| {
            try ws.beginObject();
            try ws.objectField(fmt.key_divert);
            try ws.write(t);
            try ws.endObject();
        },
        .tunnel_divert => |t| {
            try ws.beginObject();
            try ws.objectField(fmt.key_tunnel_divert);
            try ws.write(t);
            try ws.endObject();
        },
        .tunnel_divert_via_var => |name| {
            try ws.beginObject();
            try ws.objectField(fmt.key_tunnel_divert);
            try ws.write(name);
            try ws.objectField(fmt.key_is_variable);
            try ws.write(true);
            try ws.endObject();
        },
        .container => |c| try serContainer(ws, c),
        .eval_start => try ws.write("ev"),
        .eval_end => try ws.write("/ev"),
        .eval_output => try ws.write("out"),
        .pop => try ws.write("pop"),
        .void_ => try ws.write("void"),
        .nop => try ws.write("nop"),
        .int => |n| try ws.write(n),
        .float => |f| {
            // Ink floats need a decimal point even for whole numbers.
            var tmp: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
            if (std.mem.indexOfScalar(u8, s, '.') == null and
                std.mem.indexOfScalar(u8, s, 'e') == null)
            {
                try ws.print("{d}.0", .{f});
            } else {
                try ws.print("{d}", .{f});
            }
        },
        .bool_ => |b| try ws.write(b),
        .string => |s| try ws.write(s),
        .var_assign => |va| {
            try ws.beginObject();
            try ws.objectField(fmt.key_var_assign);
            try ws.write(va.name);
            if (!va.is_new) {
                try ws.objectField(fmt.key_reassign);
                try ws.write(true);
            }
            try ws.endObject();
        },
        .var_ref => |name| {
            try ws.beginObject();
            try ws.objectField(fmt.key_var_ref);
            try ws.write(name);
            try ws.endObject();
        },
        .var_pointer => |vp| {
            try ws.beginObject();
            try ws.objectField(fmt.key_var_pointer);
            try ws.write(vp.name);
            try ws.objectField(fmt.key_var_pointer_ctx);
            try ws.write(vp.context_idx);
            try ws.endObject();
        },
        .temp_assign => |ta| {
            try ws.beginObject();
            try ws.objectField(fmt.key_temp_assign);
            try ws.write(ta.name);
            if (!ta.is_new) {
                try ws.objectField(fmt.key_reassign);
                try ws.write(true);
            }
            try ws.endObject();
        },
        .cond_divert => |path| {
            try ws.beginObject();
            try ws.objectField(fmt.key_divert);
            try ws.write(path);
            try ws.objectField(fmt.key_conditional);
            try ws.write(true);
            try ws.endObject();
        },
        .dup => try ws.write("du"),
        .choice_point => |cp| {
            try ws.beginObject();
            try ws.objectField(fmt.key_choice_point);
            try ws.write(cp.path);
            try ws.objectField(fmt.key_choice_flags);
            try ws.write(cp.flags);
            try ws.endObject();
        },
        .divert_target_val => |path| {
            try ws.beginObject();
            try ws.objectField(fmt.key_divert_target_val);
            try ws.write(path);
            try ws.endObject();
        },
        .divert_via_var => |name| {
            try ws.beginObject();
            try ws.objectField(fmt.key_divert);
            try ws.write(name);
            try ws.objectField(fmt.key_is_variable);
            try ws.write(true);
            try ws.endObject();
        },
        .read_count => |path| {
            try ws.beginObject();
            try ws.objectField(fmt.key_read_count);
            try ws.write(path);
            try ws.endObject();
        },
        .func_return => try ws.write("~ret"),
        .function_call => |fc| {
            // {"f()":"name"} for 0 args, {"f(N)":"name"} for N args.
            try ws.beginObject();
            if (fc.arg_count == 0) {
                try ws.objectField(fmt.key_function_call_0);
            } else {
                var key_buf: [32]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "f({d})", .{fc.arg_count}) catch unreachable;
                try ws.objectField(key);
            }
            try ws.write(fc.name);
            if (fc.is_var) {
                try ws.objectField(fmt.key_is_variable);
                try ws.write(true);
            }
            try ws.endObject();
        },
        .external_call => |ec| {
            // {"x()":"name","exArgs":N}
            try ws.beginObject();
            try ws.objectField(fmt.key_external_call);
            try ws.write(ec.name);
            try ws.objectField(fmt.key_external_args);
            try ws.write(ec.arg_count);
            try ws.endObject();
        },
        .list_val => |lv| {
            // Non-empty: {"list":{"origin.item":value,...}}
            // Empty with origins: {"list":{},"origins":["origin",...]}
            try ws.beginObject();
            try ws.objectField(fmt.key_list);
            try ws.beginObject();
            for (lv.entries) |e| {
                try ws.objectField(e.key);
                try ws.write(e.value);
            }
            try ws.endObject();
            if (lv.entries.len == 0 and lv.origins.len > 0) {
                try ws.objectField(fmt.key_list_origins);
                try ws.beginArray();
                for (lv.origins) |o| {
                    try ws.write(o);
                }
                try ws.endArray();
            }
            try ws.endObject();
        },
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
