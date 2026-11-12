//! Loads ink's compiled JSON (`.ink.json`, versions 18 to 21) into a `Program` (plan §4.9,
//! P3.1), streaming: no JSON value tree, and an explicit frame stack instead of recursion.
//!
//! A container is a JSON array of content items whose last element is `null` or a dictionary
//! holding its named-only children, its counting flags (`#f`) and its name (`#n`). One
//! content item becomes exactly one instruction. An object item is told apart from that final
//! dictionary by its first key: `#f`, `#n`, or a key whose value is an array (a named child)
//! start the dictionary; every content object starts with a key ink defines.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scanner = std.json.Scanner;
const program_builder = @import("program_builder.zig");
const ProgramBuilder = program_builder.ProgramBuilder;
const Program = @import("program.zig").Program;
const instruction_module = @import("instruction.zig");
const Opcode = instruction_module.Opcode;

pub const ink_version_minimum = 18;
pub const ink_version_maximum = 21;
/// Containers nest this deep at most (knots, stitches, weaves, conditionals, sequences).
pub const depth_max = 512;

pub const Error = error{
    InvalidInkJson,
    UnsupportedInkVersion,
    UnknownContent,
    TooDeep,
    IntegerOutOfRange,
} || program_builder.Error || Scanner.NextError || Scanner.AllocError;

/// Control commands and native functions, by their JSON spelling.
const words = std.StaticStringMap(Opcode).initComptime(.{
    .{ "ev", .eval_start },           .{ "out", .eval_output },
    .{ "/ev", .eval_end },            .{ "du", .duplicate },
    .{ "pop", .pop },                 .{ "~ret", .function_return },
    .{ "->->", .tunnel_return },      .{ "str", .string_start },
    .{ "/str", .string_end },         .{ "nop", .nop },
    .{ "choiceCnt", .choice_count },  .{ "turn", .turns },
    .{ "turns", .turns_since },       .{ "readc", .read_count_of_target },
    .{ "rnd", .random },              .{ "srnd", .seed_random },
    .{ "visit", .visit_index },       .{ "seq", .sequence_shuffle_index },
    .{ "thread", .start_thread },     .{ "done", .done },
    .{ "end", .end },                 .{ "listInt", .list_from_int },
    .{ "range", .list_range },        .{ "lrnd", .list_random },
    .{ "#", .tag_start },             .{ "/#", .tag_end },
    .{ "+", .add },                   .{ "-", .subtract },
    .{ "/", .divide },                .{ "*", .multiply },
    .{ "%", .modulo },                .{ "_", .negate },
    .{ "==", .equal },                .{ ">", .greater },
    .{ "<", .less },                  .{ ">=", .greater_or_equal },
    .{ "<=", .less_or_equal },        .{ "!=", .not_equal },
    .{ "!", .not },                   .{ "&&", .@"and" },
    .{ "||", .@"or" },                .{ "MIN", .min },
    .{ "MAX", .max },                 .{ "POW", .pow },
    .{ "FLOOR", .floor },             .{ "CEILING", .ceiling },
    .{ "INT", .int },                 .{ "FLOAT", .float_cast },
    .{ "?", .has },                   .{ "!?", .hasnt },
    .{ "L^", .intersect },            .{ "LIST_MIN", .list_min },
    .{ "LIST_MAX", .list_max },       .{ "LIST_ALL", .list_all },
    .{ "LIST_COUNT", .list_count },   .{ "LIST_VALUE", .list_value },
    .{ "LIST_INVERT", .list_invert }, .{ "<>", .glue },
    .{ "void", .void },
});

/// Loads `json`. The returned program is owned by the caller (`Program.deinit(gpa)`).
pub fn load(gpa: Allocator, json: []const u8) !Program {
    assert(json.len < std.math.maxInt(u32));
    const text = strip_byte_order_mark(json);
    // The scanner's nesting stack and unescaped strings come from one bounded region.
    const scratch = try gpa.alloc(u8, text.len + 64 * 1024);
    defer gpa.free(scratch);
    var scratch_allocator: std.heap.FixedBufferAllocator = .init(scratch);
    var loader: Loader = .{
        .scanner = .initCompleteInput(scratch_allocator.allocator(), text),
        .scratch = scratch_allocator.allocator(),
        .builder = try ProgramBuilder.init(gpa),
    };
    defer loader.builder.deinit();
    defer loader.scanner.deinit();
    try loader.load_document();
    var program = try loader.builder.finish();
    errdefer program.deinit(gpa);
    assert(program.containers.len > 0);
    return program;
}

fn strip_byte_order_mark(json: []const u8) []const u8 {
    assert(json.len < std.math.maxInt(u32));
    const mark = "\xEF\xBB\xBF";
    const result = if (std.mem.startsWith(u8, json, mark)) json[mark.len..] else json;
    assert(result.len <= json.len);
    return result;
}

const FrameKind = enum { content, metadata };

const Loader = struct {
    scanner: Scanner,
    scratch: Allocator,
    builder: ProgramBuilder,
    frames: [depth_max]FrameKind = undefined,
    frames_count: u32 = 0,

    fn load_document(loader: *Loader) Error!void {
        assert(loader.builder.containers.len == 0);
        try loader.expect(.object_begin);
        var saw_root = false;
        while (true) {
            const key = switch (try loader.next_token()) {
                .object_end => break,
                .string, .allocated_string => |name| name,
                else => return error.InvalidInkJson,
            };
            if (std.mem.eql(u8, key, "inkVersion")) {
                const version = try loader.integer();
                if (version < ink_version_minimum or version > ink_version_maximum) {
                    return error.UnsupportedInkVersion;
                }
                loader.builder.ink_version = @intCast(version);
            } else if (std.mem.eql(u8, key, "root")) {
                try loader.load_containers();
                saw_root = true;
            } else if (std.mem.eql(u8, key, "listDefs")) {
                try loader.load_list_definitions();
            } else {
                try loader.scanner.skipValue();
            }
        }
        if (!saw_root) return error.InvalidInkJson;
        assert(loader.frames_count == 0);
    }

    /// The next token, with strings and numbers complete (unescaped into scratch if needed).
    fn next_token(loader: *Loader) Error!std.json.Token {
        assert(loader.frames_count <= depth_max);
        const result = try loader.scanner.nextAlloc(loader.scratch, .alloc_if_needed);
        assert(result != .partial_string and result != .partial_number);
        return result;
    }

    fn expect(loader: *Loader, comptime tag: std.meta.Tag(std.json.Token)) Error!void {
        assert(loader.frames_count <= depth_max);
        const token = try loader.scanner.next();
        if (std.meta.activeTag(token) != tag) return error.InvalidInkJson;
        assert(tag != .end_of_document or loader.frames_count == 0);
    }

    fn integer(loader: *Loader) Error!i64 {
        assert(loader.frames_count <= depth_max);
        const token = try loader.next_token();
        const text = switch (token) {
            .number, .allocated_number => |digits| digits,
            else => return error.InvalidInkJson,
        };
        assert(text.len > 0);
        return std.fmt.parseInt(i64, text, 10) catch error.InvalidInkJson;
    }

    fn string(loader: *Loader) Error![]const u8 {
        assert(loader.frames_count <= depth_max);
        const token = try loader.next_token();
        const text = switch (token) {
            .string, .allocated_string => |value| value,
            else => return error.InvalidInkJson,
        };
        assert(text.len < std.math.maxInt(u32));
        return text;
    }

    /// A string that names something (a variable, a path, a list): never empty.
    fn nonempty_string(loader: *Loader) Error![]const u8 {
        assert(loader.frames_count <= depth_max);
        const text = try loader.string();
        if (text.len == 0) return error.InvalidInkJson;
        assert(text.len > 0);
        return text;
    }

    /// An integer field that must fit `T`.
    fn integer_as(loader: *Loader, comptime T: type) Error!T {
        comptime assert(@bitSizeOf(T) <= 32);
        const value = try loader.integer();
        const result = std.math.cast(T, value) orelse return error.InvalidInkJson;
        assert(@as(i64, result) == value);
        return result;
    }

    fn push(loader: *Loader, kind: FrameKind) Error!void {
        assert(loader.frames_count <= depth_max);
        if (loader.frames_count == depth_max) return error.TooDeep;
        loader.frames[loader.frames_count] = kind;
        loader.frames_count += 1;
        assert(loader.frames_count <= depth_max);
    }

    /// The root container and everything in it, one token at a time.
    fn load_containers(loader: *Loader) Error!void {
        try loader.expect(.array_begin);
        _ = try loader.builder.begin_container(.{});
        try loader.push(.content);
        var steps: u64 = 0;
        while (loader.frames_count > 0) : (steps += 1) {
            // Every step consumes at least one token.
            assert(steps <= loader.scanner.input.len);
            switch (loader.frames[loader.frames_count - 1]) {
                .content => try loader.content_step(),
                .metadata => try loader.metadata_step(),
            }
        }
        assert(loader.builder.frames.items.len == 0);
    }

    /// One content item, or the container's terminator.
    fn content_step(loader: *Loader) Error!void {
        assert(loader.frames[loader.frames_count - 1] == .content);
        assert(loader.frames_count > 0);
        switch (try loader.scanner.peekNextTokenType()) {
            .array_begin => {
                _ = try loader.scanner.next();
                _ = try loader.builder.begin_container(.{});
                try loader.push(.content);
            },
            .null => {
                _ = try loader.scanner.next();
                try loader.end_container();
            },
            .array_end => return error.InvalidInkJson,
            .object_begin => {
                _ = try loader.scanner.next();
                try loader.object_item();
            },
            .string => try loader.add_word(try loader.string()),
            .number => try loader.add_number(),
            .true, .false => try loader.builder.add(.bool, (try loader.scanner.next()) == .true),
            else => return error.InvalidInkJson,
        }
    }

    /// Closes the current container after its terminator: expects the array's end.
    fn end_container(loader: *Loader) Error!void {
        assert(loader.builder.frames.items.len > 0);
        try loader.expect(.array_end);
        try loader.builder.end_container();
        assert(loader.frames_count > 0);
        loader.frames_count -= 1;
    }

    /// An object in a container's content: a content item, or the final dictionary.
    fn object_item(loader: *Loader) Error!void {
        assert(loader.frames_count > 0);
        assert(loader.frames[loader.frames_count - 1] == .content);
        const first = switch (try loader.next_token()) {
            .object_end => return loader.end_container(),
            .string, .allocated_string => |key| key,
            else => return error.InvalidInkJson,
        };
        const is_metadata = std.mem.eql(u8, first, "#f") or std.mem.eql(u8, first, "#n") or
            try loader.scanner.peekNextTokenType() == .array_begin;
        if (!is_metadata) return loader.content_object(first);
        // The dictionary is open; its first key still needs handling.
        try loader.push(.metadata);
        try loader.metadata_key(first);
    }

    /// One key of a container's final dictionary, or its end.
    fn metadata_step(loader: *Loader) Error!void {
        assert(loader.frames_count > 0);
        assert(loader.frames[loader.frames_count - 1] == .metadata);
        switch (try loader.next_token()) {
            .object_end => {
                loader.frames_count -= 1;
                try loader.end_container();
            },
            .string, .allocated_string => |key| try loader.metadata_key(key),
            else => return error.InvalidInkJson,
        }
    }

    fn metadata_key(loader: *Loader, key: []const u8) Error!void {
        assert(loader.frames[loader.frames_count - 1] == .metadata);
        assert(loader.builder.frames.items.len > 0);
        if (key.len == 0) return error.InvalidInkJson;
        if (std.mem.eql(u8, key, "#f")) {
            const bits = try loader.integer();
            if (bits < 0 or bits > 7) return error.InvalidInkJson;
            loader.builder.set_flags(@bitCast(@as(u8, @intCast(bits))));
        } else if (std.mem.eql(u8, key, "#n")) {
            try loader.builder.set_name(try loader.nonempty_string());
        } else {
            try loader.expect(.array_begin);
            _ = try loader.builder.begin_container(.{ .name = key, .named_only = true });
            try loader.push(.content);
        }
    }

    fn add_number(loader: *Loader) Error!void {
        assert(loader.builder.frames.items.len > 0);
        assert(loader.frames[loader.frames_count - 1] == .content);
        const token = try loader.next_token();
        const text = switch (token) {
            .number, .allocated_number => |digits| digits,
            else => unreachable,
        };
        if (std.mem.indexOfAny(u8, text, ".eE") != null) {
            const value = std.fmt.parseFloat(f32, text) catch return error.InvalidInkJson;
            return loader.builder.add(.float, value);
        }
        const value = std.fmt.parseInt(i32, text, 10) catch return error.IntegerOutOfRange;
        try loader.builder.add(.integer, value);
    }

    /// A string content item: text, a newline, or a command or function word.
    fn add_word(loader: *Loader, word: []const u8) Error!void {
        assert(loader.builder.frames.items.len > 0);
        if (word.len == 0) return error.UnknownContent;
        if (word[0] == '^') return loader.builder.add(.text, try loader.builder.intern(word[1..]));
        if (std.mem.eql(u8, word, "\n")) return loader.builder.add(.newline, {});
        const opcode = words.get(word) orelse {
            std.log.debug("unknown content word: {s}", .{word});
            return error.UnknownContent;
        };
        assert(instruction_module.operand_kind(opcode) == .none);
        try loader.add_bare(opcode);
    }

    fn add_bare(loader: *Loader, opcode: Opcode) Error!void {
        assert(instruction_module.operand_kind(opcode) == .none);
        const count_before = loader.builder.scratch.len;
        try loader.builder.scratch.append(loader.builder.gpa, .{ .opcode = opcode, .operand = 0 });
        assert(loader.builder.scratch.len == count_before + 1);
    }

    /// The fields of a content object; ink defines which keys appear together.
    const Fields = struct {
        divert_key: ?[]const u8 = null,
        target: ?[]const u8 = null,
        variable: bool = false,
        conditional: bool = false,
        external_arguments: u32 = 0,
        choice_flags: u32 = 0,
        reassignment: bool = false,
        context: i32 = -1,
        value: ?[]const u8 = null,
        key: []const u8 = "",
        list_items: std.ArrayList([]const u8) = .empty,
        list_origins: std.ArrayList([]const u8) = .empty,
    };

    /// Reads the rest of a content object whose first key is `first`, then adds it.
    fn content_object(loader: *Loader, first: []const u8) Error!void {
        assert(first.len > 0);
        var fields: Fields = .{};
        var key = first;
        while (true) {
            try loader.content_field(&fields, key);
            key = switch (try loader.next_token()) {
                .object_end => break,
                .string, .allocated_string => |next| next,
                else => return error.InvalidInkJson,
            };
        }
        try loader.add_object(&fields);
        assert(fields.key.len > 0);
    }

    fn content_field(loader: *Loader, fields: *Fields, key: []const u8) Error!void {
        assert(loader.builder.frames.items.len > 0);
        assert(key.len > 0);
        const divert_keys = [_][]const u8{ "->", "f()", "->t->", "x()" };
        for (divert_keys) |divert_key| {
            if (std.mem.eql(u8, key, divert_key)) {
                fields.divert_key = divert_key;
                fields.target = try loader.nonempty_string();
                fields.key = divert_key;
                return;
            }
        }
        if (std.mem.eql(u8, key, "var")) return loader.flag(&fields.variable);
        if (std.mem.eql(u8, key, "c")) return loader.flag(&fields.conditional);
        if (std.mem.eql(u8, key, "re")) return loader.flag(&fields.reassignment);
        if (std.mem.eql(u8, key, "exArgs")) {
            fields.external_arguments = try loader.integer_as(u16);
            return;
        }
        if (std.mem.eql(u8, key, "flg")) {
            // Five flag bits; anything above them is not ink's.
            fields.choice_flags = try loader.integer_as(u5);
            return;
        }
        if (std.mem.eql(u8, key, "ci")) {
            fields.context = try loader.integer_as(i32);
            return;
        }
        if (std.mem.eql(u8, key, "list")) return loader.list_items(fields);
        if (std.mem.eql(u8, key, "origins")) return loader.list_origins(fields);
        // A key whose value is a string: "*", "^->", "^var", "VAR?", "CNT?", "VAR=", ...
        fields.key = key;
        fields.value = try loader.nonempty_string();
    }

    fn flag(loader: *Loader, field: *bool) Error!void {
        assert(loader.frames_count > 0);
        const token = try loader.scanner.next();
        field.* = switch (token) {
            .true => true,
            .false => false,
            else => return error.InvalidInkJson,
        };
        assert(token == .true or token == .false);
    }

    /// `"list": {"origin.item": value, ...}`
    fn list_items(loader: *Loader, fields: *Fields) Error!void {
        assert(fields.list_items.items.len == 0);
        try loader.expect(.object_begin);
        fields.key = "list";
        while (true) {
            const name = switch (try loader.next_token()) {
                .object_end => return,
                .string, .allocated_string => |item| item,
                else => return error.InvalidInkJson,
            };
            if (name.len == 0) return error.InvalidInkJson;
            _ = try loader.integer_as(i32);
            try fields.list_items.append(loader.scratch, name);
            assert(fields.list_items.items.len > 0);
        }
    }

    /// `"origins": ["origin", ...]`
    fn list_origins(loader: *Loader, fields: *Fields) Error!void {
        assert(fields.list_origins.items.len == 0);
        try loader.expect(.array_begin);
        while (true) {
            const name = switch (try loader.next_token()) {
                .array_end => return,
                .string, .allocated_string => |origin| origin,
                else => return error.InvalidInkJson,
            };
            if (name.len == 0) return error.InvalidInkJson;
            try fields.list_origins.append(loader.scratch, name);
            assert(fields.list_origins.items.len > 0);
        }
    }

    fn add_object(loader: *Loader, fields: *Fields) Error!void {
        assert(loader.builder.frames.items.len > 0);
        const builder = &loader.builder;
        if (fields.divert_key != null) return loader.add_divert_object(fields);
        const key = fields.key;
        if (std.mem.eql(u8, key, "list")) {
            return builder.add_list_literal(fields.list_items.items, fields.list_origins.items);
        }
        const value = fields.value orelse {
            std.log.debug("content object without a value: {s}", .{fields.key});
            return error.UnknownContent;
        };
        if (std.mem.eql(u8, key, "*")) {
            return builder.add_choice_point(value, @bitCast(fields.choice_flags));
        }
        if (std.mem.eql(u8, key, "^->")) return builder.add_container_operand(
            .divert_target,
            value,
        );
        if (std.mem.eql(u8, key, "CNT?")) return builder.add_container_operand(.read_count, value);
        if (std.mem.eql(u8, key, "VAR?")) return builder.add_variable_get(value);
        if (std.mem.eql(u8, key, "#")) return builder.add(.tag, try builder.intern(value));
        if (std.mem.eql(u8, key, "VAR=")) {
            const slot = try builder.global(value);
            if (fields.reassignment) return builder.add(.global_assign, slot);
            return builder.add(.global_declare, slot);
        }
        if (std.mem.eql(u8, key, "temp=")) {
            const name = try builder.intern(value);
            if (fields.reassignment) return builder.add(.temp_assign, name);
            return builder.add(.temp_declare, name);
        }
        if (std.mem.eql(u8, key, "^var")) return loader.add_variable_pointer(value, fields.context);
        assert(key.len > 0);
        std.log.debug("unknown content object key: {s}", .{key});
        return error.UnknownContent;
    }

    fn add_variable_pointer(loader: *Loader, name: []const u8, context: i32) Error!void {
        const builder = &loader.builder;
        assert(name.len > 0);
        const at = try builder.extra.add(builder.gpa, instruction_module.VariablePointer{
            .name = try builder.intern(name),
            .context = context,
        });
        try builder.add(.variable_pointer, @fromBackingInt(@intCast(at)));
        assert(at < builder.extra.count());
    }

    fn add_divert_object(loader: *Loader, fields: *const Fields) Error!void {
        assert(fields.target != null);
        const builder = &loader.builder;
        const key = fields.divert_key.?;
        const target = fields.target.?;
        if (std.mem.eql(u8, key, "x()")) {
            const at = try builder.extra.add(builder.gpa, instruction_module.ExternalCall{
                .external = try builder.external(target),
                .arguments_count = fields.external_arguments,
                .conditional = fields.conditional,
            });
            return builder.add(.call_external, @fromBackingInt(@intCast(at)));
        }
        const kind: instruction_module.DivertKind = if (std.mem.eql(u8, key, "f()"))
            .function
        else if (std.mem.eql(u8, key, "->t->"))
            .tunnel
        else
            .plain;
        const flags: instruction_module.DivertFlags = .{
            .kind = kind,
            .conditional = fields.conditional,
            .variable = fields.variable,
        };
        if (fields.variable) return builder.add_divert_variable(target, flags);
        try builder.add_divert(target, flags);
        assert(!flags.variable);
    }

    /// `"listDefs": {"origin": {"item": value, ...}, ...}`
    fn load_list_definitions(loader: *Loader) Error!void {
        assert(loader.builder.list_origins.items.len == 0);
        try loader.expect(.object_begin);
        var items: std.ArrayList(ProgramBuilder.ListItemDeclaration) = .empty;
        while (true) {
            const origin = switch (try loader.next_token()) {
                .object_end => break,
                .string, .allocated_string => |text| text,
                else => return error.InvalidInkJson,
            };
            if (origin.len == 0) return error.InvalidInkJson;
            try loader.expect(.object_begin);
            items.clearRetainingCapacity();
            while (true) {
                const item = switch (try loader.next_token()) {
                    .object_end => break,
                    .string, .allocated_string => |text| text,
                    else => return error.InvalidInkJson,
                };
                if (item.len == 0) return error.InvalidInkJson;
                const value = try loader.integer_as(i32);
                try items.append(loader.scratch, .{ .name = item, .value = value });
            }
            _ = try loader.builder.list_origin(origin, items.items);
        }
        assert(items.items.len < std.math.maxInt(u32));
    }
};

fn load_file(gpa: Allocator, path: []const u8) !Program {
    assert(std.mem.endsWith(u8, path, ".json"));
    assert(path.len > 0);
    const io = std.testing.io;
    const json = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(json);
    return load(gpa, json);
}

test "hello world loads into the expected instructions" {
    // Goal: the basic mapping of content items to instructions. Method: load a tiny story and
    // dump it.
    const gpa = std.testing.allocator;
    const json =
        \\{"inkVersion":21,"root":[["^Hello",{"->":".^.^.knot"},["done",{"#f":5,"#n":"g-0"}],null],
        \\"done",{"knot":["^K","\n","end",null]}],"listDefs":{}}
    ;
    var program = try load(gpa, json);
    defer program.deinit(gpa);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try @import("program_dump.zig").dump(&program, &output.writer);
    try std.testing.expectEqualStrings(
        \\container 0 "" depth 0
        \\  0 enter_container 1
        \\  1 done
        \\container 1 "0" parent 0 depth 1
        \\  0 text "Hello"
        \\  1 divert plain -> 3:0
        \\  2 enter_container 2
        \\container 2 "0.g-0" parent 1 depth 2 visits start_only
        \\  0 done
        \\container 3 "knot" parent 0 depth 1 named
        \\  0 text "K"
        \\  1 newline
        \\  2 end
        \\
    , output.written());
}

/// Every `.ink.json` below `directory`, sorted.
fn collect_json(arena: Allocator, directory: []const u8) ![]const []const u8 {
    assert(directory.len > 0);
    const io = std.testing.io;
    var root = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walk(arena);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ink.json")) continue;
        try paths.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{
            directory,
            entry.path,
        }));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            assert(a.len > 0);
            assert(b.len > 0);
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    assert(paths.items.len > 0);
    return paths.items;
}

test "every compiled fixture and ground-truth story loads" {
    // Goal: P3.1. Method: load every .ink.json from inklecate (test/fixture/compiled) and from
    // the pinned ink compiler (test/ground_truth), and count the v20 ones.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = std.testing.allocator;
    var loaded: u32 = 0;
    var version_20: u32 = 0;
    var failures: u32 = 0;
    for ([_][]const u8{ "test/fixture/compiled", "test/ground_truth" }) |directory| {
        for (try collect_json(arena, directory)) |path| {
            var program = load_file(gpa, path) catch |err| {
                std.debug.print("failed to load {s}: {t}\n", .{ path, err });
                failures += 1;
                continue;
            };
            defer program.deinit(gpa);
            loaded += 1;
            if (program.ink_version == 20) version_20 += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 0), failures);
    try std.testing.expect(loaded > 300);
    try std.testing.expectEqual(@as(u32, 5), version_20);
}

test "malformed input returns an error instead of crashing" {
    // Goal: untrusted JSON can't reach an assertion. Method: inputs the fuzzer and review
    // found: an empty named-child key, an empty name, out-of-range integer fields.
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        \\{"ion":21,"root":[["^Hello","\n",["done",{"":[["^Hello",":"g-0"}],null],"done",null],
        ,
        \\{"inkVersion":21,"root":[["done",{"#n":""}],null]}
        ,
        \\{"inkVersion":21,"root":[{"*":".^","flg":99},"done",null]}
        ,
        \\{"inkVersion":21,"root":[{"x()":"f","exArgs":-1},"done",null]}
        ,
        \\{"inkVersion":21,"root":["done",null],"listDefs":{"l":{"a":99999999999}}}
        ,
    };
    for (cases) |json| {
        if (load(gpa, json)) |program| {
            var loaded = program;
            loaded.deinit(gpa);
            return error.TestUnexpectedSuccess;
        } else |_| {}
    }
}
