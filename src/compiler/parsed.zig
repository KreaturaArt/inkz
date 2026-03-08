/// Compiler AST — the tree produced by parsing .ink source files.
/// These types are used only during compilation; the runtime uses the
/// flat DOP AST (Story.containers[]) after JSON loading.
const std = @import("std");

// ── Top-level story ───────────────────────────────────────────────────────────

pub const Story = struct {
    list_defs: []ListDef,
    global_decls: []VarDecl,
    constants: []Constant,
    external_fns: []ExternalFn,
    includes: [][]const u8,
    knots: []Knot,
    root_content: []FlowItem,
};

// ── Knots / stitches ──────────────────────────────────────────────────────────

pub const Knot = struct {
    name: []const u8,
    params: []Param,
    is_function: bool,
    stitches: []Stitch,
    /// Used only when is_function=false and stitches is empty.
    content: []FlowItem,
};

pub const Stitch = struct {
    name: []const u8,
    content: []FlowItem,
};

// ── Flow items ────────────────────────────────────────────────────────────────

pub const FlowItem = union(enum) {
    text: TextLine,
    choice: Choice,
    gather: Gather,
    divert: Divert,
    logic: LogicLine,
    conditional: Conditional,
    sequence: Sequence,
    thread_start: []const u8, // knot name after <-
    tag: []const u8,
};

pub const TextLine = struct {
    elements: []InlineElement,
};

pub const InlineElement = union(enum) {
    text: []const u8,
    glue, // <>
    divert: Divert,
    inline_expr: *Expression,
    sequence: Sequence,
    tag: []const u8,
};

// ── Choices & gathers ─────────────────────────────────────────────────────────

pub const Choice = struct {
    nesting: u8, // number of leading * or + chars
    is_sticky: bool,
    condition: ?*Expression,
    /// Content shown in the choice list AND when the choice is followed.
    start_content: []InlineElement,
    /// Content shown only in the choice list, not after selection.
    choice_only_content: []InlineElement,
    /// Content shown only after the choice is selected.
    following_content: []InlineElement,
    label: ?[]const u8,
    inner_content: []FlowItem,
};

pub const Gather = struct {
    nesting: u8,
    label: ?[]const u8,
};

// ── Diverts ───────────────────────────────────────────────────────────────────

pub const Divert = struct {
    target: []const u8,
    is_tunnel: bool,
    is_thread: bool,
    args: []*Expression,
};

// ── Logic lines ───────────────────────────────────────────────────────────────

pub const LogicLine = union(enum) {
    var_decl: VarDecl,
    temp_decl: TempDecl,
    assignment: Assignment,
    return_stmt: ?*Expression, // null = bare `~ return`
    include: []const u8,
};

pub const VarDecl = struct {
    name: []const u8,
    initial: *Expression,
};

pub const TempDecl = struct {
    name: []const u8,
    initial: *Expression,
};

pub const Assignment = struct {
    name: []const u8,
    value: *Expression,
    is_temp: bool,
};

// ── Conditionals ──────────────────────────────────────────────────────────────

pub const Conditional = struct {
    branches: []Branch,
};

pub const Branch = struct {
    condition: ?*Expression, // null = else branch
    content: []FlowItem,
};

// ── Sequences / alternatives ──────────────────────────────────────────────────

pub const Sequence = struct {
    kind: SequenceKind,
    branches: [][]FlowItem,
};

pub const SequenceKind = enum {
    stopping, // default
    cycle, // &
    once_only, // !
    shuffle, // ~
};

// ── Expressions ───────────────────────────────────────────────────────────────

pub const Expression = union(enum) {
    int_lit: i64,
    float_lit: f64,
    bool_lit: bool,
    string_lit: []const u8,
    var_ref: []const u8,
    read_count: []const u8, // {-> knot} visit count
    divert_target: []const u8, // ^-> path
    var_pointer: struct { name: []const u8, context_idx: i32 }, // ref params
    binary: struct { op: BinaryOp, lhs: *Expression, rhs: *Expression },
    unary: struct { op: UnaryOp, operand: *Expression },
    call: struct { name: []const u8, args: []*Expression },
    list_lit: InkListLiteral,
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    gt,
    lt,
    ge,
    le,
    and_,
    or_,
};

pub const UnaryOp = enum {
    negate,
    not,
};

// ── Declarations ──────────────────────────────────────────────────────────────

pub const Param = struct {
    name: []const u8,
    is_ref: bool,
    is_divert: bool,
};

pub const Constant = struct {
    name: []const u8,
    value: *Expression,
};

pub const ListDef = struct {
    name: []const u8,
    items: []ListItem,
};

pub const ListItem = struct {
    name: []const u8,
    value: ?i32, // null = auto-assigned
};

pub const ExternalFn = struct {
    name: []const u8,
    param_count: u32,
};

pub const InkListLiteral = struct {
    /// Each entry is "origin.item" or just "item" (resolved at codegen time).
    items: [][]const u8,
};

// ── Smoke test ────────────────────────────────────────────────────────────────

test "parsed types compile" {
    // Just verifying all types can be referenced without errors.
    _ = Story;
    _ = Knot;
    _ = Stitch;
    _ = FlowItem;
    _ = TextLine;
    _ = InlineElement;
    _ = Choice;
    _ = Gather;
    _ = Divert;
    _ = LogicLine;
    _ = VarDecl;
    _ = TempDecl;
    _ = Assignment;
    _ = Conditional;
    _ = Branch;
    _ = Sequence;
    _ = SequenceKind;
    _ = Expression;
    _ = BinaryOp;
    _ = UnaryOp;
    _ = Param;
    _ = Constant;
    _ = ListDef;
    _ = ListItem;
    _ = ExternalFn;
    _ = InkListLiteral;
}
