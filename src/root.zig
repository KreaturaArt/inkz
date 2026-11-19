//! inkz: an ink runtime and compiler. The runtime's API is at the top level;
//! `compiler` compiles ink source to a Program, `core` holds the shared program image.
//!
//! Stability. The stable host API (docs/RunningYourInk.md) is:
//! - the top-level declarations re-exported from `runtime/api.zig`: `Story`, `Value`,
//!   `Choice`, `ChooseOptions`, `BindOptions`, `Limits`, `Usage`, `fitted_limits`, `Events`,
//!   `ErrorHandler`, `Observer`, `ExternalFunction`, `Severity`, `Error`, `SetError`,
//!   `Borrowed`;
//! - `Program`, the immutable image a story runs;
//! - `compiler`'s entry points: `compile_source`, `compile_file`, `compile_file_with`
//!   (with `Options`), `compile_to_json` and `Error`;
//! - `ink_json.load` and `program_image.load` / `program_image.write`;
//! - from `runtime`, only `runtime.story.Story` (the story an external function receives) and
//!   `runtime.evaluate.evaluate_function` (for calling ink from inside one).
//!
//! Everything else reachable from here is internal and may change without notice: the other
//! declarations of `runtime` (VM, heap, state, flows, lookahead, save/load internals) and of
//! `compiler`, and all of `core` (instructions, containers, builder, string pool, profile
//! zones). They are exported for the tests, the benchmarks and the tools in this repository.

const api = @import("runtime/api.zig");

// Stable host API.
pub const Story = api.Story;
pub const Value = api.Value;
pub const Choice = api.Choice;
pub const ChooseOptions = api.ChooseOptions;
pub const BindOptions = api.BindOptions;
pub const Limits = api.Limits;
pub const Usage = api.Usage;
pub const fitted_limits = api.fitted_limits;
pub const Events = api.Events;
pub const ErrorHandler = api.ErrorHandler;
pub const Observer = api.Observer;
pub const ExternalFunction = api.ExternalFunction;
pub const Severity = api.Severity;
pub const Error = api.Error;
pub const SetError = api.SetError;
pub const Borrowed = api.Borrowed;

/// Unstable internals, except `runtime.story.Story` and `runtime.evaluate.evaluate_function`
/// (see the file comment).
pub const runtime = @import("runtime/root.zig");
/// Stable: `compile_source`, `compile_file`, `compile_file_with`, `Options`,
/// `compile_to_json`, `Error`. The rest is internal.
pub const compiler = @import("compiler/compile.zig");
/// Unstable internals (the program image's building blocks), for tests and tools.
pub const core = @import("core/root.zig");
/// Stable: `load` (ink's JSON to a `Program`). The rest is internal.
pub const ink_json = @import("core/ink_json.zig");
/// Stable: `load` and `write` (the binary program image). The rest is internal.
pub const program_image = @import("core/program_image.zig");
/// Stable: the immutable program a `Story` runs.
pub const Program = @import("core/program.zig").Program;
