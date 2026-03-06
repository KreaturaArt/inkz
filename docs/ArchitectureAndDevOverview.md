# Architecture and Development

## Overview

The ink pipeline broadly consists of 3 stages:

* The ink parser - interprets the ink text files to a hierarchy of objects
* The runtime code generation
* The runtime engine itself

The following is a fairly brief tour of these 3 stages, hopefully enough to give you a foundation for exploring the codebase yourself.

## Ink parser

The parser takes a root ink file (which may reference other ink files), and constructs a hierarchy of `Parsed.Object` values that closely resemble the structure within the original ink files, as closely as possible to how it was written.

The parser is a hand-written recursive descent parser built on top of `StringParser`, which allows a hierarchy of parse rules to be composed using Zig function pointers. At the top level, `ink_parser.zig` contains a function called `parse()`, which returns a `Parsed.Story` value.

Within `parse()`, rules are evaluated, each of which may contain more rules. Rules are simply functions that return the result of parsing or `null` if parsing failed (though there are exceptions to this).

Crucially however, parse rules are wrapped in either `parseObject(rule)` or `parse(T, rule)`. These functions know how to rewind the state of the parser when a rule fails. This is important, since the rule may get part way through before it realises that it's not parsing what it wanted. By way of illustration, here's the start of the parse rule for a stitch:

```zig
fn stitchDefinition(p: *Parser) ?*Parsed.Stitch {
    // Wrap the 'stitchDeclaration' rule in a parse(...) call,
    // so that it will return to the correct point in the ink
    // file if parsing fails.
    const saved = p.save();
    const decl = p.parse(stitchDeclaration) orelse {
        p.restore(saved);
        return null;
    };

    // ... (continue parsing the StitchDefinition)
```

If a rule isn't wrapped in a `parse` function, then it's an indication that rewinding definitely isn't strictly necessary within the scope, for example if a sub-rule is both optional and atomic. Or, when success and failure of the rule is handled manually.

## StringParser structuring

The base type `StringParser` contains a number of helper functions to help with parsing.

Functions like `parseString`, `parseSingleCharacter`, `parseInt`, etc can be used to read text and values at the lowest level.

Higher level structuring functions can be used to compose rules together. For example:

```zig
pub fn oneOrMore(p: *Parser, comptime T: type, rule: *const fn(*Parser) ?T) ![]T
```

...acts a bit like the `+` operator in regular expressions. So for example, in multiline conditionals, we have:

```zig
const multiple_conditions = try p.oneOrMore(Condition, singleMultilineCondition);
```

Similarly, but even more powerfully, the `interleave` function matches patterns of the form ABABA etc. Frequently, this is used to interleave some core content with whitespace. Here's an example that parses the arguments to a flow (e.g. knot, stitch or function), that is a series of identifiers separated by commas:

```zig
const flow_arguments = try p.interleave(
    Argument,
    p.spaced(flowDeclArgument),
    p.exclude(p.string(",")),
);
```

The above example also demonstrates another concept: rule transformers and builders. In the above example, `spaced` takes a rule, and produces a new rule that also allows for optional whitespace on either side of the content that is parsed.

The `exclude` transformer takes a rule, and if it succeeds, prevents its result from being included in the `interleave`'s returned slice (to remove the commas from the parsed results).

The `string` rule is like `parseString` except that it **constructs rules** rather than parsing immediately, which is useful for conveniently constructing declarative expressions like the one above.

Other transformers and structuring concepts exist, but hopefully this should give you enough of a taste to get started.

## DOP AST construction (compiler code generation)

The parsed hierarchy closely resembles the ink as it was originally written. The compiler's job is to convert it into the **Data Oriented Programming (DOP) AST** — a flat, container-based representation that is shared by both the compiler and the runtime.

The DOP AST is built out of smaller, more fundamental units (sort of like byte code, though not that low level). This AST is serialized to a JSON-based format (`.ink.json`) by the compiler, and deserialized back into the **same DOP AST structure** by the runtime at startup. For more information on the JSON format, [see the documentation](ink_JSON_runtime_format.md).

> **Key architectural constraint**: the runtime has **no dynamic memory allocation** during story execution. All DOP AST nodes are allocated once during `Story.initFromJson()` and remain immutable for the lifetime of the story.

In the DOP AST, there's no concept of Knots, Stitches, Weave, or other high level ink structures. Instead, the AST consists mainly of general purpose `Container` objects and content, represented as `RuntimeObject` tagged unions.

These DOP AST nodes are built from the `Parsed.Object` hierarchy, however not immediately. The `init` functions of `Parsed.Object` types are kept as lightweight as possible, since the rewinding of the parser when rules fail can potentially cause them to be built and destroyed multiple times before a final successful hierarchy is produced.

Instead, the hard work of converting the parsed hierarchy into the DOP AST is saved for two steps done later:

* Main DOP AST construction
* Resolving of references

In most cases, a single `Parsed.Object` is converted to one or more `RuntimeObject` nodes, through the following function:

```zig
pub fn generateRuntimeObject(self: *Parsed.Object, allocator: Allocator) !*RuntimeObject { ... }
```

At the top level, this construction process is kicked off by the `Parsed.Story` in:

```zig
pub fn exportRuntime(self: *Parsed.Story, allocator: Allocator) !*Story
```

Once the full DOP AST has been constructed, references are resolved. This has to be done in a separate pass, since the target of references (such as divert targets — knot names etc) may not exist until the full AST exists.

Each `Parsed.Object` can implement:

```zig
pub fn resolveReferences(self: *Parsed.Object, context: *Story) void
```

...in order to participate in this process. For example in `divert.zig`, the function contains this (as well as other things):

```zig
if (self.target_content) |target| {
    self.runtime_divert.target_path = target.runtimePath();
}
```

After reference resolution, the fully linked DOP AST is serialized to `.ink.json`. The runtime then deserializes this JSON back into the same DOP AST structure via `Story.initFromJson()`, with all allocation happening at that point.

## Runtime ink engine

The runtime operates directly on the **DOP AST** deserialized from `.ink.json` at startup. Because the compiler and runtime share the same AST structure, there is no translation step at runtime — `Story.initFromJson()` allocates all nodes once, and `step()` traverses them with zero further allocation.

All the higher level structures, including the story itself, any knots and stitches, and even choices, are built out of containers. Within the containers, content is iterated through sequentially, and appended to the output.

This structure is loaded by the ink engine from a [JSON based format](ink_JSON_runtime_format.md).

### Containers

The `Runtime.Container` is general purpose, and can work as either an array or a dictionary, or both. Therefore, it can have ordered (indexed content) that's designed to be iterated through sequentially, and can also have named content, that's designed to be accessed by a string key.

For example, a `Parsed.Choice` compiles down to a `Runtime.Container` that contains, amongst other things, the initial sequential content that forms the text of the choice, the minimal `Runtime.ChoicePoint` itself, as well as a named sub-container that contains the content that is run when the choice is picked by the player.

### Content

As with ink itself, the runtime engine's fundamental unit is content, rather than code. As such, a simple "Hello world" ink file would be compiled down to a single `Runtime.Container` with a single `Runtime.StringValue` in it (as well as a terminator).

Each piece of content that is encountered is appended to the `output_stream` within the `Runtime.Story`.

### Control commands

Alongside the content that's designed to be seen by the player, additional commands are used to control the flow and evaluation of the content. Some examples, all of which are in the enum `Runtime.ControlCommand.CommandType`:

* `eval_start` and `eval_end`: the content objects between are appended to the `evaluation_stack` rather than the `output_stream`. As functions and operators are encountered, they pop values off the stack, process them, and push a value back on the stack. Meanwhile, `eval_output` pops a value off the evaluation stack, and pushes it onto the output stream.
* `choice_count`: how many choices have been produced in the current turn? Push the value to the output stream (or evaluation stack if in evaluation mode).
* `done`: Indicates that the current flow is safe to end.

### Story

Some important and useful features of the main runtime engine in `story.zig`:

* `cont()` is the top level point where iteration of the content happens, and has this rough structure internally:

```zig
while (try self.step() or self.tryFollowDefaultInvisibleChoice()) {}
```

* `step()` iterates through a single element of content, and returns `false` if it runs out of content.
* `performLogicAndFlowControl(content_object)` is called from `step`, and handles the majority of the non-content objects such as Diverts, Control Commands, etc.

## Compiler development and debugging tips

While testing modifications to the compiler, it's useful to run the **ink_testbed** executable. Inside `ink_testbed.zig` there is a suite of useful tools.

The main entry point is `run()`. By default it simply calls `play()`, which will load up a pre-existing `test.ink` (that you can put your test ink in). `play()` has a basic choice loop that also serves as a good introduction to some of the built-in convenience functions.

However if you want to automate the testing of a particular flow, you could write something like:

```zig
pub fn run(tb: *TestBed) !void {
    try tb.compileFile();

    try tb.continueMaximally();
    try tb.choose(0);

    try tb.continueMaximally();
    try tb.choose(1);

    try tb.continueMaximally();
}
```

`buildStringOfHierarchy()` is a method in `Runtime.Story` that's useful when debugging. Call it while debugging to see a representation of the runtime hierarchy, as well as an arrow that points at where execution currently is in the hierarchy. For example, the following ink:

    This is a test.
    * [A choice]
    - The end -> DONE

...is at the time of writing represented, somewhat verbosely, as:

    [
        [
            This is a test.
    ,
            [
                eval_start,  <---
                begin_string,
                A choice,
                end_string,
                eval_end,
                Choice: ->  line 2
                -- named: --
                [ (c)
                    Divert (line 3)
                ]
            ]
            -- named: --
            [ (g-0)
                The end
    ,
                done
            ]
        ],
        End
    ]

The `<---` is the pointer to the current object being evaluated.

In this representation, containers are represented as:

    [
        ...content...
        -- named: --
        ...named content...
    ]
