# Running your ink

This guide shows how a Zig program loads and plays an ink story with inkz. Every ```zig
block here is compiled against the library by `zig build doctest` (see `tools/doctest.zig`
for the convention). A block that is not a whole file is a snippet: it is compiled inside a
function that has `gpa: std.mem.Allocator`, `io: std.Io` and `story: *inkz.Story` in scope.

If you used the old runtime, the [migration table](#migrating-from-the-old-api) at the end
lists every renamed call.

## Quick start

1. Add inkz to your package with `zig fetch --save <url of inkz>`, then import its module in
   `build.zig`:

   ```text
   const inkz = b.dependency("inkz", .{ .target = target, .optimize = optimize });
   exe.root_module.addImport("inkz", inkz.module("inkz"));
   ```

2. Compile your story. inkz has no command-line compiler yet; use ink's `inklecate` to write
   a `.ink.json` file, or compile the `.ink` source in your program
   (see [Using the compiler](#using-the-compiler)).

3. Load the story and play it:

```zig
const std = @import("std");
const inkz = @import("inkz");

test "a story compiled from source, played to the end" {
    const gpa = std.testing.allocator;
    var program = try inkz.compiler.compile_source(gpa,
        \\Hello, world!
        \\* Hello back
        \\  Nice to hear from you.
        \\- -> END
        \\
    );
    defer program.deinit(gpa);

    var story: inkz.Story = undefined;
    try story.init(gpa, &program, .{});
    defer story.deinit(gpa);

    try std.testing.expectEqualStrings("Hello, world!\n", (try story.cont()).get());
    try std.testing.expect(!story.can_continue());
    try std.testing.expectEqual(@as(u32, 1), story.current_choices_count());
    try std.testing.expectEqualStrings("Hello back", story.current_choice(0).get().text);

    try story.choose_choice_index(0);
    const rest = try story.continue_maximally_alloc(gpa);
    defer gpa.free(rest);
    try std.testing.expectEqualStrings("Hello back\nNice to hear from you.\n", rest);
    try std.testing.expect(!story.can_continue());
}
```

## Loading a story

There are two ways to make a `Story`:

- `story.init(gpa, &program, options)` runs a `Program` you own. The program is immutable
  and must outlive the story. Several stories, on any threads, can share one program.
- `story.init_from_json(gpa, json, options)` loads ink's compiled JSON (versions 18 to 21)
  into a program that the story owns and frees in `deinit`.

`Story` is initialised in place and must not move afterwards, so declare it `undefined` and
call `init` on it. `deinit(gpa)` frees exactly what `init` allocated.

```zig
const json = try std.Io.Dir.cwd().readFileAlloc(io, "story.ink.json", gpa, .limited(1 << 24));
defer gpa.free(json);

var story: inkz.Story = undefined;
try story.init_from_json(gpa, json, .{ .random_seed = 42 });
defer story.deinit(gpa);
```

You can also embed the JSON with `@embedFile("story.ink.json")`. The story does not keep a
reference to `json` after `init_from_json` returns.

### Loading from a program image

JSON has to be parsed. A program image is the `Program`'s arrays as bytes, so loading one
copies and checks them instead, 6–7× faster than JSON (`docs/program_image.md`). Write the
image once, at build time or the first time a story is loaded, and load it from then on:

```zig
// Once: compile (or ink_json.load) and write the image.
var program = try inkz.compiler.compile_source(gpa, "Hello from an image.\n");
defer program.deinit(gpa);
var image: std.Io.Writer.Allocating = .init(gpa);
defer image.deinit();
try inkz.program_image.write(&program, &image.writer);

// Every run: load the image. It is checked, and the bytes are copied.
var loaded = try inkz.program_image.load(gpa, image.written());
defer loaded.deinit(gpa);
var story: inkz.Story = undefined;
try story.init(gpa, &loaded, .{});
defer story.deinit(gpa);
```

`load` treats the image as untrusted. A wrong, truncated or corrupted image returns a named
error (`error.NotAProgramImage`, `error.InvalidImage`, ...), never a crash. Images carry a
format version. After an inkz update that changes it, `load` returns
`error.UnsupportedFormatVersion`; write the image again from the JSON or the source.

`Story.Options` has these fields:

| Field | Default | Meaning |
|---|---|---|
| `limits` | `.{}` | The size of every buffer (see [Memory and limits](#memory-and-limits)). |
| `random_seed` | `0` | ink's story seed. ink seeds from the clock; inkz is deterministic unless you pass a seed. |
| `allow_external_function_fallbacks` | `false` | ink's `allowExternalFunctionFallbacks`. |
| `events` | `.{}` | ink's host events (see [Host events](#host-events)). |
| `on_error`, `error_context` | `null` | ink's `onError` (see [Errors](#errors)). |

## Playing: lines and choices

The story is played in two repeating stages.

1. **Present content.** While `can_continue()` is true, `cont()` returns the next line,
   as ink's `Continue()` does. A line ends at a newline, but `cont()` looks ahead past it:
   if glue (`<>`) later joins the next text onto this line, the joined text is one line.
   Call `cont()` only while `can_continue()` is true.
2. **Make a choice.** When the story can't continue, show its choices and pass the player's
   pick to `choose_choice_index`. Then go back to step 1. If there are no choices, the story
   has ended.

```zig
var stdout_buffer: [4096]u8 = undefined;
var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
const out = &stdout.interface;

while (true) {
    while (story.can_continue()) {
        const line = try story.cont();
        try out.writeAll(line.get());
    }
    const count = story.current_choices_count();
    if (count == 0) break;
    var position: u32 = 0;
    while (position < count) : (position += 1) {
        const choice = story.current_choice(position).get();
        try out.print("{d}: {s}\n", .{ position + 1, choice.text });
    }
    try out.flush();
    const picked: u32 = 0; // The player's pick, from your input handling.
    try story.choose_choice_index(picked);
}
try out.flush();
```

`continue_maximally(writer)` runs `cont()` until the story can't continue and writes every
line to `writer`; `continue_maximally_alloc(gpa)` returns the text in memory you own. Use
them when you show a whole passage at once. Use `cont()` when you show one line at a time, or
when your UI reacts between lines (tags, variable changes).

`current_text()` returns the text of the last line again.

### Borrowed views

`cont()`, `current_text()`, `current_choice()`, `current_choice_tag()`, `get_variable()`,
`evaluate_function()` and `current_flow_name()` return a `Borrowed(T)`: a view into the
story's own memory, with no allocation. Read it with `.get()`. A view is valid **until the
next mutating call** on the story. The mutating calls are `cont`, `cont_alloc`,
`continue_maximally`, `choose_choice_index`, `choose_path_string`, `set_variable`,
`evaluate_function`, `switch_flow`, `switch_to_default_flow`, `remove_flow`, `load_json`,
`reset_state` and `reset_errors`.

In builds with runtime safety (Debug, ReleaseSafe), each view remembers the story's
generation, and `.get()` asserts that no mutating call happened since. Copy what you need
to keep:

```zig
const first = try story.cont();
const kept = try gpa.dupe(u8, first.get()); // Still valid after the next cont().
defer gpa.free(kept);
```

`cont_alloc(gpa)` does the same in one call.

## Tags

Tags are reported to a *sink*: a pointer to any value with a method
`pub fn tag(self, text: []const u8) !void`. The tag text is valid only during the call.

```zig
const Tags = struct {
    count: u32 = 0,

    pub fn tag(tags: *@This(), text: []const u8) !void {
        std.debug.print("tag: {s}\n", .{text});
        tags.count += 1;
    }
};

var tags: Tags = .{};
_ = try story.cont();
try story.current_tags(&tags); // The tags of the line cont() returned.
try story.global_tags(&tags); // The tags at the top of the main ink file.
try story.tags_for_content_at_path("Munich", &tags); // The tags at the top of a knot.
```

Where tags come from in ink:

```ink
# author: Joseph Humfrey
# title: My Wonderful Ink Story

Passepartout: Really, Monsieur. # surly # really_monsieur.ogg

=== Munich ===
# location: Germany
First line of content in the knot.

* A choice! # a tag on both choice and content
* [A choice # a choice tag not on the content]
```

The first line of the story carries the global tags too, and the first line of a knot
carries the knot's tags, as in ink. Tags are dynamic: they may contain inline ink, such as
`#{character}_greeting.jpg`.

A choice's tags are read by position:

```zig
const choice = story.current_choice(0).get();
var tag: u32 = 0;
while (tag < choice.tags_count) : (tag += 1) {
    std.debug.print("choice tag: {s}\n", .{story.current_choice_tag(0, tag).get()});
}
```

## Jumping to a knot or stitch

```zig
try story.choose_path_string("Munich", .{});
try story.choose_path_string("Munich.station", .{});
```

`ChooseOptions` has `reset_callstack` (default `true`, as in ink: the current flow's call
stack is ended and its choices are cleared) and `arguments`, for a knot with parameters:

```zig
try story.choose_path_string("greet", .{ .arguments = &.{.{ .string = "Ada" }} });
```

The path is a runtime path: `knot` or `knot.stitch`. Gather and choice labels can't be
reached this way. An unknown path returns `error.PathNotFound`. Without
`reset_callstack`, calling it from inside an ink function is an error, as in ink.

## Variables

```zig
try story.set_variable("player_health", .{ .integer = 100 });
try story.set_variable("player_name", .{ .string = "Ada" }); // Copied into the story.

if (story.get_variable("player_health")) |health| {
    std.debug.print("health: {d}\n", .{health.get().integer});
}
```

`inkz.Value` is a tagged union: `.null`, `.integer` (`i32`), `.float` (`f32`), `.bool`,
`.string` (a borrowed slice), `.list` (an opaque reference into the story's list storage)
and `.divert_target`. Integers wrap and floats are 32-bit, as in C# ink.

`set_variable` works only on declared globals (`error.VariableNotDeclared` otherwise), and
type-checks as ink does. It notifies observers at once, since it happens outside `cont()`.
`get_variable` returns `null` for an unknown name. To list the globals:

```zig
var position: u32 = 0;
while (position < story.global_variable_count()) : (position += 1) {
    std.debug.print("{s}\n", .{story.global_variable_name(position)});
}
```

## Visit counts

```zig
const visits = story.visit_count_at_path_string("Munich.station");
std.debug.print("visited {d} times\n", .{visits});
```

## Variable observers

An observer is called with the global's name and its new value. Observers of changes made
during `cont()` are called once per variable, at the end of that `cont()` call, with the
value then (as ink's batched observation does). Every callback takes the `context` pointer
it was registered with.

```zig
const Hud = struct {
    health: i32 = 0,

    fn on_change(context: ?*anyopaque, name: []const u8, value: inkz.Value) void {
        const hud: *@This() = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, name, "health")) hud.health = value.integer;
    }
};

var hud: Hud = .{};
try story.observe_variable("health", &hud, Hud.on_change);
try story.observe_variable("stamina", &hud, Hud.on_change);
```

A string value passed to an observer is valid only during the call.

## Running ink functions

`evaluate_function(name, arguments, text_writer)` runs an ink function to its end, as
ink's `EvaluateFunction` does. Text the function prints goes to `text_writer`, line by line.
Its return value comes back as a borrowed `Value` (`.null` if it returns nothing). Other side
effects (globals, visit counts, the random state) persist.

```zig
var text: std.Io.Writer.Allocating = .init(gpa);
defer text.deinit();
const result = try story.evaluate_function("multiply", &.{ .{ .integer = 6 }, .{ .integer = 7 } }, &text.writer);
std.debug.print("{d}, printed: {s}\n", .{ result.get().integer, text.written() });
```

An unknown function returns `error.FunctionNotFound`.

## External functions

Declare the function in ink:

```ink
EXTERNAL play_sound(name)
~ play_sound("whack")
```

and bind a Zig function to it before the first `cont()`. An external function receives its
`context`, the runtime's story and the arguments, and returns a `Value` (`.null` for none).

```zig
const Audio = struct {
    played: u32 = 0,

    fn play_sound(
        context: ?*anyopaque,
        runtime_story: *inkz.runtime.story.Story,
        arguments: []const inkz.Value,
    ) anyerror!inkz.Value {
        _ = runtime_story;
        const audio: *@This() = @ptrCast(@alignCast(context.?));
        std.debug.print("play {s}\n", .{arguments[0].string});
        audio.played += 1;
        return .null;
    }
};

var audio: Audio = .{};
try story.bind_external_function("play_sound", .{ .lookahead_safe = false }, &audio, Audio.play_sound);
```

- Argument strings are valid only during the call. A returned string is copied into the
  story before it continues.
- Calling a mutating story method from inside a callback returns `error.Reentrant`. The one
  exception is `inkz.runtime.evaluate.evaluate_function(runtime_story, ...)`, which may nest
  up to `Limits.evaluate_depth_max` deep, as in ink.
- If any external function the story declares has no binding (and no usable fallback), the
  first `cont()` returns `error.MissingExternalBinding`, as ink's binding validation does.
  Binding a name the story doesn't declare does nothing.
- `unbind_external_function(name)` removes a binding. Binding a name twice returns
  `error.AlreadyBound`.

### Actions and pure functions: `lookahead_safe`

To find where a line ends, `cont()` runs past each newline to see whether glue joins the
next text on. Functions called during that lookahead run before the line they belong to is
shown.

- An **action** (plays a sound, changes game state) should not run early. Bind it with
  `.lookahead_safe = false`: when the lookahead reaches it, the line ends there, and the
  function runs during the next `cont()`.
- A **pure function** (a calculation, harmless to call more than once) can be bound with
  `.lookahead_safe = true`, the default, so it doesn't break glue:

```ink
The square root of 9
~ temp x = sqrt(9)
<> is {x}.
```

### Fallbacks

With `Options.allow_external_function_fallbacks`, an unbound external function runs the ink
function of the same name, if the story has one:

```ink
EXTERNAL multiply(x, y)
=== function multiply(x, y) ===
~ return x * y
```

## Saving and loading

`to_json(writer)` streams the state as ink's save format (version 10), with no allocation.
`load_json(json)` loads a save written by inkz or by C# ink (versions 8 to 10). A save that
doesn't load leaves the story unchanged.

```zig
var saved: std.Io.Writer.Allocating = .init(gpa);
defer saved.deinit();
try story.to_json(&saved.writer);

try story.load_json(saved.written());
```

`load_json` returns `error.InvalidSave`, `error.SaveVersionTooOld`,
`error.SaveDoesNotMatchStory` (the story changed since the save) or `error.SaveTooLarge`
(the save doesn't fit the story's limits). `reset_state()` starts the story over, as ink's
`ResetState` does.

## Errors

ink records runtime errors and warnings (for example "ran out of content"). With an error
handler, `cont()` passes each message to it and carries on:

```zig
const Log = struct {
    fn on_error(context: ?*anyopaque, message: []const u8, severity: inkz.Severity) void {
        _ = context;
        switch (severity) {
            .warning => std.log.warn("{s}", .{message}),
            .@"error" => std.log.err("{s}", .{message}),
        }
    }
};

var story: inkz.Story = undefined;
try story.init_from_json(gpa, "{\"inkVersion\":21,\"root\":[\"done\",null],\"listDefs\":{}}", .{
    .on_error = Log.on_error,
});
defer story.deinit(gpa);
```

Without a handler, `cont()` returns `error.StoryError` and keeps the diagnostics, so you can
read and clear them:

```zig
if (story.cont()) |line| {
    std.debug.print("{s}", .{line.get()});
} else |err| switch (err) {
    error.StoryError => {
        var message: std.Io.Writer.Allocating = .init(gpa);
        defer message.deinit();
        var position: u32 = 0;
        while (position < story.error_count()) : (position += 1) {
            try story.write_error(position, &message.writer);
        }
        std.debug.print("{s}\n", .{message.written()});
        story.reset_errors();
    },
    else => return err,
}
```

`has_error()`, `has_warning()`, `warning_count()` and `write_warning()` complete the set.
Running out of a limit returns its own error, such as `error.FrameLimit`, `error.HeapLimit`
or `error.StepLimit`; see `inkz.Error`. ink throws in these cases. Here, when it happens in
the lookahead past a line's newline, the story goes back to the end of that line: it saves,
and the next `cont` tries the same steps again. Anywhere else the step is half done and the
story fails closed: `can_continue()` is false, there are no choices, and `cont`,
`choose_choice_index`, `choose_path_string`, `evaluate_function` and `to_json` return
`error.StoryFailed` until `reset_state()` or a successful `load_json`.

## Host events

`Options.events` holds ink's host events, each optional and each called with
`events.context`: `on_did_continue` (after each `cont`), `on_make_choice` (before a choice is
taken), `on_evaluate_function` and `on_complete_evaluate_function` (around
`evaluate_function`) and `on_choose_path_string`.

```zig
const Counter = struct {
    lines: u32 = 0,

    fn on_did_continue(context: ?*anyopaque) void {
        const counter: *@This() = @ptrCast(@alignCast(context.?));
        counter.lines += 1;
    }
};

var counter: Counter = .{};
const options: inkz.Story.Options = .{
    .events = .{ .context = &counter, .on_did_continue = Counter.on_did_continue },
};
_ = options; // Pass to story.init or story.init_from_json.
```

## Parallel flows

A flow has its own call stack, output and choices; globals, visit counts and the random
state are shared, as in ink.

```zig
try story.switch_flow("background"); // Creates the flow, starting at the root.
try story.choose_path_string("gossip", .{});
const line = try story.cont();
std.debug.print("{s}", .{line.get()});
try story.switch_to_default_flow();
try story.remove_flow("background");
std.debug.print("now in {s}\n", .{story.current_flow_name().get()});
```

The default flow is named `DEFAULT_FLOW`. `alive_flow_names(sink)` calls
`sink.name(text)` for every flow except the default one. The number of flows and the room
to park inactive ones are limits (`flows_max`, `flow_parking_bytes_max`).

## Lists

List values come back from `get_variable` as `.list`, an opaque reference that can be
stored back with `set_variable` while the story runs. The host API has no calls yet to build
a list or read its items; use ink functions through `evaluate_function` (for example one
that returns `LIST_COUNT(list)` or tests `list ? item`).

## Memory and limits

Each story makes exactly one allocation, in `init`, of `Limits.bytes_total()` bytes, and
none after that: `cont`, choosing, saving, loading and the rest run in that memory. Running
out of a buffer returns a named error such as `error.OutputLimit`, never undefined
behaviour. The defaults take about 2.2 MB per story and suit most stories. Play speed doesn't
depend on the limits, so a smaller budget costs nothing but headroom. A small side story can
use less:

```zig
var limits: inkz.Limits = .{};
limits.flows_max = 2;
limits.heap_bytes_max = 64 * 1024;
const options: inkz.Story.Options = .{ .limits = limits };
_ = options;
```

### Fitting limits to a story

Every buffer records its peak. Play the story as widely as you can with the default limits,
including every path, saves and loads. Then read `usage()` and fit the limits with a margin:

```zig
// After a thorough play of `story` with the default limits:
const limits = inkz.fitted_limits(story.usage(), 2);
var fitted: inkz.Story = undefined;
try fitted.init(gpa, story.get_program(), .{ .limits = limits });
defer fitted.deinit(gpa);
```

`zig build simulate -- --json story.ink.json --seeds 10000 --fit on` does this over 10,000
seeded random playthroughs, with saves, loads and flow switches along the way. It prints the
fitted limits as Zig source with their byte budget, then replays the same seeds within them.
crime_scene fits in 47 KB instead of 2.2 MB. A fitted budget is only as good as the play that
measured it: a story that later needs more gets a named limit error, so keep the margin.

`docs/benchmarks.md` has a worked sizing example and the measurements.

## Using the compiler

`inkz.compiler` compiles ink source to a `Program`, as inklecate does:

- `compile_source(gpa, source)` compiles one file's text (no `INCLUDE`).
- `compile_file(gpa, io, directory, path)` compiles `path` in `directory` and the files it
  includes; `compile_file_with(gpa, io, directory, path, .{ .count_all_visits = true })`
  sets ink's `countAllVisits`.
- `compile_to_json(gpa, source)` returns the story as inklecate's `.ink.json`.

A story with errors returns `error.CompileFailed`. The compiler doesn't report its
diagnostics through this API yet.

```zig
var directory = try std.Io.Dir.cwd().openDir(io, "stories", .{});
defer directory.close(io);
var program = try inkz.compiler.compile_file(gpa, io, directory, "main.ink");
defer program.deinit(gpa);

var story: inkz.Story = undefined;
try story.init(gpa, &program, .{});
defer story.deinit(gpa);
```

Precompiled JSON loads faster than source compiles, so ship `.ink.json` and compile source
during development.

## Migrating from the old API

The runtime was rewritten (plan `docs/DODMigrationPlan.md`). Three decisions change the API:

- **D5:** `cont()` returns a borrowed view, valid until the next mutating call, instead of
  allocated text. `cont_alloc(gpa)` returns a copy you own.
- **D8:** every public name is snake_case.
- **D12:** `cont()` returns one line, with ink's newline lookahead, as ink's `Continue()`
  does. The old `cont()` returned a whole turn; that is now `continue_maximally`.

| Old API | New API |
|---|---|
| `ink.Story.initFromJson(allocator, json)` | `var story: inkz.Story = undefined; try story.init_from_json(gpa, json, .{})` |
| `compiler.compile()` returning a story | `inkz.compiler.compile_source(gpa, source)` returns a `Program`; then `story.init(gpa, &program, .{})` |
| `ink.Compiler.init(allocator, source, .{ .file_handler = ... })` | `inkz.compiler.compile_file(gpa, io, directory, path)` |
| `story.deinit()` | `story.deinit(gpa)` |
| `story.cont() ![]const u8` (a turn, allocated) | `story.cont()` returns `Borrowed([]const u8)` (one line); `.get()` reads it |
| `story.continueMaximally()` | `story.continue_maximally(writer)` or `story.continue_maximally_alloc(gpa)` |
| `story.canContinue()` | `story.can_continue()` |
| `story.currentChoices()` | `story.current_choices_count()` and `story.current_choice(position).get()` |
| `choice.tags` | `choice.tags_count` and `story.current_choice_tag(position, tag)` |
| `story.chooseChoiceIndex(i)` | `story.choose_choice_index(i)` |
| `story.choosePathString(path)` | `story.choose_path_string(path, .{})` |
| `story.currentTags()` | `story.current_tags(&sink)` |
| `story.globalTags()` | `story.global_tags(&sink)` |
| `story.tagsForContentAtPath(path)` | `story.tags_for_content_at_path(path, &sink)` |
| `story.variables_state.get(name)` | `story.get_variable(name)` returns `?Borrowed(Value)` |
| `story.variables_state.set(name, value)` | `story.set_variable(name, value)` |
| `story.state.visitCountAtPathString(path)` | `story.visit_count_at_path_string(path)` |
| `story.state.toJson(allocator)` | `story.to_json(writer)` |
| `story.state.loadJson(json)` | `story.load_json(json)` |
| `story.observeVariable(name, callback)` | `story.observe_variable(name, context, observer)` |
| `story.bindExternalFunction(name, fn, options)` | `story.bind_external_function(name, options, context, function)` |
| `fn([]const ink.Value) ?ink.Value` | `fn(?*anyopaque, *inkz.runtime.story.Story, []const inkz.Value) anyerror!inkz.Value` |
| `BindOptions.lookahead_safe = false` by default | `BindOptions.lookahead_safe = true` by default, as in ink |
| `story.evaluateFunction(name, text_out, params)` | `story.evaluate_function(name, arguments, text_writer)` |
| `story.on_error = fn([]const u8, ink.ErrorType) void` | `Options.on_error = fn(?*anyopaque, []const u8, inkz.Severity) void` |
| `story.switchFlow(name)`, `switchToDefaultFlow()`, `removeFlow(name)` | `switch_flow(name)`, `switch_to_default_flow()`, `remove_flow(name)` |
| `story.currentFlowName()`, `aliveFlowNames()` | `current_flow_name()`, `alive_flow_names(&sink)` |
| `story.currentFlowIsDefaultFlow()` | compare `current_flow_name().get()` with `"DEFAULT_FLOW"` |
| `ink.Value` with `.int` | `inkz.Value` with `.integer` (`i32`) and `.float` (`f32`) |
| `ink.InkList` and its methods | none yet; lists are opaque `.list` references (see [Lists](#lists)) |
