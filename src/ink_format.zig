/// ink.json wire-format key constants shared by serializer.zig (writer) and
/// json_loader.zig (reader).  A format change updates this file only.

// ── Top-level keys ────────────────────────────────────────────────────────────

pub const key_ink_version = "inkVersion";
pub const key_root = "root";
pub const key_list_defs = "listDefs";

// ── Container metadata keys (trailing element of a container array) ───────────

pub const key_meta_name = "#n";
pub const key_meta_flags = "#f";

// ── Object type keys (first key of a single-key or multi-key JSON object) ────

pub const key_divert = "->";
pub const key_tunnel_divert = "->t->";
pub const key_function_call_0 = "f()";     // function call with 0 args
pub const key_function_call_prefix = "f("; // prefix for f(N) keys (N > 0)
pub const key_external_call = "x()";
pub const key_choice_point = "*";
pub const key_var_assign = "VAR=";
pub const key_temp_assign = "temp=";
pub const key_var_ref = "VAR?";
pub const key_read_count = "CNT?";
pub const key_divert_target_val = "^->";
pub const key_var_pointer = "^var";
pub const key_list = "list";
pub const key_inline_tag = "#";             // inkVersion 20 inline tag object

// ── Modifier keys (secondary keys within an object) ──────────────────────────

pub const key_conditional = "c";
pub const key_is_variable = "var";
pub const key_reassign = "re";
pub const key_external_args = "exArgs";
pub const key_choice_flags = "flg";
pub const key_var_pointer_ctx = "ci";

// ── List keys ────────────────────────────────────────────────────────────────

pub const key_list_origins = "origins";

// ── String encoding ───────────────────────────────────────────────────────────

/// Prefix on JSON string values that contain story text (as opposed to commands).
pub const text_prefix = "^";
pub const text_prefix_char: u8 = '^';
