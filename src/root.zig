//! inkz: an ink runtime and compiler. The runtime's API is at the top level (plan §4.7);
//! `compiler` compiles ink source to a Program, `core` holds the shared program image.

const api = @import("runtime/api.zig");

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

pub const runtime = @import("runtime/root.zig");
pub const compiler = @import("compiler/compile.zig");
pub const core = @import("core/root.zig");
pub const ink_json = @import("core/ink_json.zig");
pub const program_image = @import("core/program_image.zig");
pub const Program = @import("core/program.zig").Program;
