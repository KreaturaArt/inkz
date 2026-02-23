# Running your ink

## Quick Start

* Compile your `.ink` source file to JSON using the `inkz` compiler:
  ```sh
  inkz compile story.ink -o story.ink.json
  ```
* Add `inkz` as a dependency in your `build.zig.zon` and import the `ink` module in your `build.zig`.
* Load the compiled JSON and run the story (see **Getting started with the runtime API**, below).

## Further information

Ink uses an intermediate `.json` format, which is compiled from the original `.ink` files. You can compile them on the command line using the `inkz` compiler. See **Using inkz on the command line** in the [README](http://www.github.com/inkle/ink) for more information.

We recommend that you create a wrapper struct for the `ink.Story`. Here, we'll call the struct `Script` — in the "film script" sense, rather than the "code module" sense:

```zig
const ink = @import("ink");

pub const Script = struct {
    story: ink.Story,

    pub fn init(allocator: Allocator, json_asset: []const u8) !Script {
        return .{ .story = try ink.Story.initFromJson(allocator, json_asset) };
    }

    pub fn deinit(self: *Script) void {
        self.story.deinit();
    }
};
```

## Getting started with the runtime API

As mentioned above, your `.ink` file(s) are compiled to a single `.json` file. You can embed this directly in your binary at compile time or load it from disk at runtime.

The API for loading and running your story is very straightforward. Construct a new `Story` by passing in the JSON string. For example:

```zig
var script = try Script.init(allocator, @embedFile("story.ink.json"));
defer script.deinit();
```

From there, you make calls to the story in a loop. There are two repeating stages:

 1. **Present content:** You repeatedly call `cont()` on it, which returns individual lines of string content, until `canContinue()` returns false. For example:

```zig
while (script.story.canContinue()) {
    const line = try script.story.cont();
    std.debug.print("{s}", .{line});
}
```

    A simpler way to achieve the above is through one call to `script.story.continueMaximally()`. However, in many stories it's useful to pause the story at each line, for example when stepping through dialogue. Also, in such games, there may be state changes that should be reflected in the UI, such as resource counters.

 2. **Make choice:** When there isn't any more content, you should check to see whether there any choices to present to the player. To do so, use something like:

```zig
if (script.story.currentChoices().len > 0) {
    for (script.story.currentChoices(), 0..) |choice, i| {
        std.debug.print("{d}: {s}\n", .{i + 1, choice.text});
    }
}

// ...and when the player provides input:

try script.story.chooseChoiceIndex(index);

// And now you're ready to return to step 1, and present content again.
```

### Saving and loading

To save the state of your story within your game, call:

```zig
const saved_json = try story.state.toJson(allocator);
defer allocator.free(saved_json);
```

...and then to load it again:

```zig
try story.state.loadJson(saved_json);
```

### Error handling

If you made a mistake in your ink that the compiler can't catch, then the story will return an error. To handle errors gracefully and get structured error output instead, you can assign an error handler when you create your story:

```zig
var story = try ink.Story.initFromJson(allocator, json_asset);

story.on_error = struct {
    fn handler(msg: []const u8, err_type: ink.ErrorType) void {
        switch (err_type) {
            .warning => std.log.warn("{s}", .{msg}),
            .err     => std.log.err("{s}", .{msg}),
        }
    }
}.handler;
```

### Is that it?

That's it! You can achieve a lot with just those simple steps, but for more advanced usage, including deep integration with your game, read on.

## Engine usage and philosophy

We recommend using your own wrapper struct to encapsulate `ink.Story`. The runtime **ink** engine has been designed to be reasonably general purpose and have a simple API. We also recommend wrapping rather than embedding the story directly in domain objects, so that you can expose to your game only the functionality that you need.

Often when designing the flow for your game, the sequence of interactions between the player and the story may not precisely match the way the **ink** is evaluated. For example, with a classic choose-your-own-adventure type story, you may want to show multiple lines (paragraphs) of text and choices all at once. For a visual novel, you may want to display one line per screen.

Additionally, since the **ink** engine outputs lines of plain text, it can be effectively used for your own simple sub-formats. For example, for a dialog based game, you could write:

    *   Lisa: Where did he go?
        Joe:  I think he jumped over the garden fence.
        * *   Lisa: Let's take a look.
        * *   Lisa: So he's gone for good?

As far as the **ink** engine is concerned, the `:` characters are just text. But as the lines of text and choices are produced by the game, you can do some simple text parsing of your own to turn the string `Joe: What's up?` into a game-specific dialog object that references the speaker and the text (or even audio).

This approach can be taken even further to text that flexibly indicates non-content directives. Again, these directives come out of the engine as text, but can be parsed by your game for a specific purpose:

    PROPLIST table, chair, apple, orange

The above approach is used in our current game for the writer to declare the props that they expect to be in the scene. These might be picked up in the game editor in order to automatically fill a scene with placeholder objects, or just to validate that the level designer has populated the scene correctly.

To mark up content more explicitly, you may want to use *tags* or *external functions* - see below. At inkle, we find that we use a mixture, but we actually find the above approach useful for a very large portion of our interaction with the game - it's very flexible.


## Marking up your ink content with tags

Tags can be used to add metadata to your game content that isn't intended to appear to the player. Within ink, add a `#` character followed by any string content you want to pass over to the game. There are three main places where you can add these hash tags:

### Line by line tags

One use case is for a graphic adventure that has different art for characters depending on their facial expression. So, you could do:

    Passepartout: Really, Monsieur. # surly

On the game side, every time you get content with `story.cont()`, you can get a slice of tags with `story.currentTags()`, which will return a `[][]const u8`, in the above case with just one element: `"surly"`.

To add more than one tag, simply delimit them with more `#` characters:

    Passepartout: Really, Monsieur. # surly # really_monsieur.ogg

The above demonstrate another possible use case: providing full voice-over for your game, by marking up your ink with the audio filenames.

Tags for a line can be written above it, or on the end of the line:

    # the first tag
    # the second tag
    This is the line of content. # the third tag

All of the above tags will be included in the `currentTags()` slice.

### Knot tags

Any tags that you include at the very top of a knot:

    === Munich ==
    # location: Germany
    # overview: munich.ogg
    # require: Train ticket
    First line of content in the knot.

...are accessible by calling `story.tagsForContentAtPath("your_knot")`, which is useful for getting metadata from a knot before you actually want the game to go there.

Note that these tags will also appear in the `currentTags()` slice for the first line of content in the knot.

### Global tags

Any tags provided at the very top of the main ink file are accessible via the story's `globalTags()` method, which also returns a `[][]const u8`. Any top level story metadata can be included there.

We suggest the following by convention, if you wish to share your ink stories publicly:

    # author: Joseph Humfrey
    # title: My Wonderful Ink Story

Note that [Inky](https://github.com/inkle/inky) will use the title tag in this format as the `<h1>` tag in a story exported for web.

#### Choice tags

Tags can also be applied to choices. Depending where the tag is placed inside the ink line, the tag will appear on both the choice and the content generated by that choice; on just the choice; or just on the output:

	* A choice! #a tag on both choice and content
	* [A choice #a choice tag not on content ]
	* A choice[!] which continues. #a tag on output content only

You can use all three in the same ink line:

	* A choice #shared_tag [ with detail #choice_tag ] and content # content_tag

The choice tags are stored inside the `tags` slice on the choice object.

#### Advanced: Tags are dynamic

Note that the content of a tag can contain any inline **ink**, such as shuffles, cycles, function calls and variable replacements.

	{character}: Hello there! #{character}_greeting.jpg

	I open the door. #suspense_music{RANDOM(1, 4)}.mp3

## Jumping to a particular "scene"

Top level named sections in **ink** are called knots (see [the writing tutorial](WritingWithInk.md)). You can tell the runtime engine to jump to a particular named knot:

```zig
try story.choosePathString("myKnotName");
```

And then call `cont()` as usual.

To jump directly to a stitch within a knot, use a `.` as a separator:

```zig
try story.choosePathString("myKnotName.theStitchWithin");
```

(Note that this path string is a *runtime* path rather than the path as used within the **ink** format. It's just been designed so that for the basics of knots and stitches, the format works out the same. Unfortunately however, you can't reference gather or choice labels this way.)

## Setting/getting ink variables

The state of the variables in the **ink** engine is, appropriately enough, stored within the `variables_state` field within the `story`. You can both get and set variables directly on this object:

```zig
try story.variables_state.set("player_health", .{ .int = 100 });

const health = story.variables_state.get("player_health").?.int;
```

## Read/Visit counts

To find out the number of times that a knot or stitch has been visited by the ink engine, you can use this API:

```zig
const count = story.state.visitCountAtPathString("...");
```

The path string is in the form `"yourKnot"` for knots, and `"yourKnot.yourStitch"` for stitches.

## Variable observers

You can register a callback function to be called whenever a particular variable changes. This can be useful to reflect the state of certain **ink** variables directly in the UI. For example:

```zig
try story.observeVariable("health", struct {
    fn onChange(_: []const u8, new_value: ink.Value) void {
        setHealthInUi(new_value.int);
    }
}.onChange);
```

The reason that the variable name is passed in is so that you can have a single observer function that observes multiple different variables:

```zig
try story.observeVariable("health", onStatChanged);
try story.observeVariable("stamina", onStatChanged);

fn onStatChanged(var_name: []const u8, new_value: ink.Value) void {
    if (std.mem.eql(u8, var_name, "health"))
        setHealthInUi(new_value.int)
    else if (std.mem.eql(u8, var_name, "stamina"))
        setStaminaInUi(new_value.int);
}
```


## Running functions

You can run ink functions directly using `evaluateFunction`.

You can pass the expected arguments for the ink function, if any.

If the ink function has a return value, it will be returned by `evaluateFunction`.
You do not need to call `cont()` over any text lines that may exist in the function; it runs to the end. Any content is written to `text_output`, with a line break between each line.

```zig
var text_output = std.ArrayList(u8).init(allocator);
defer text_output.deinit();

const return_value = try story.evaluateFunction("myFunctionName", &text_output, params);
```

## External functions

You can define game-side functions in Zig that can be called directly from **ink**. To do so:

1. Declare an external function using something like this at the top of one of your **ink** files, in global scope:

        EXTERNAL playSound(soundName)

2. Bind your Zig function. For example:

```zig
try story.bindExternalFunction("playSound", struct {
    fn call(args: []const ink.Value) ?ink.Value {
        audio_controller.play(args[0].asString());
        return null;
    }
}.call, .{});
```

3. You can then call that function within the **ink**:

        ~ playSound("whack")

The types you can use as parameters and return values are `.int`, `.float`, `.bool` (automatically converted from **ink**'s internal ints) and `.string`.

#### Alternatives to external functions

Remember that in addition to external functions, there are other good ways to communicate between your ink and your game:

* You can set up a variable observer if you just want the game to know when some state has changed. This is perfect for say, changing the score in the UI.

* You can use [tags](RunningYourInk.md#marking-up-your-ink-content-with-tags) to add invisible metadata to a line in ink.

* In inkle's games such as [Heaven's Vault](https://www.inklestudios.com/heavensvault), we use the text itself to write instructions to the game, and then have a game-specific text parser decide what to do with it. This is a very flexible approach, and allows us to have a different style of writing on each project. For example, we use the following syntax to ask the game to set up a particular camera shot:

  `>>> SHOT: view_over_bridge`

#### Actions v.s. Pure functions

**Warning:** The following section is subtly complex! However, don't worry - you can probably ignore it and use default behaviour. If you find a situation where glue isn't working the way you expect and there's an external function in there somewhere, or if you're just plain curious, read on...

There are two kinds of external functions:

* **Actions** - for example, to play sounds, show images, etc. Generally, these may change game state in some way.
* **Pure functions** - those that don't cause side effects. Specifically 1) **it should be harmless to call them more than once**, and 2) **they shouldn't affect game state**. For example, a mathematical calculation, or pure inspection of game state.

By default, external functions are treated as Actions, since we think this is the primary use-case for most people. However, the distinction can be important for subtle reasons to do with the way that glue works.

When the engine looks at content, it may look ahead further than you would expect *just in case* there is glue in future content that would turn two separate lines into one.

However, external functions that are intended to be run as actions, you don't want them to be run prospectively, since the player is likely to notice, so for this kind we cancel any attempt to glue content together. If it was in the middle of prospectively looking ahead and it sees an action, it'll stop before running it.

Conversely, if all you're doing is a mathematical calculation for example, you don't want your glue to break. For example:

```
The square root of 9
~ temp x = sqrt(9)
<> is {x}.
```

You can define how you want your function to behave when you bind it, using the `lookahead_safe` option:

```zig
pub fn bindExternalFunction(
    story: *Story,
    func_name: []const u8,
    func: *const fn([]const ink.Value) ?ink.Value,
    options: BindOptions,
) !void
```

where `BindOptions` is:

```zig
pub const BindOptions = struct {
    lookahead_safe: bool = false,
};
```

* **Actions** should have `lookahead_safe = false` (the default)
* **Pure functions** should have `lookahead_safe = true`

### Fallbacks for external functions

When testing your story in [Inky](/inkle/inky) or the `inkz` player, you don't get an opportunity to bind a game function before running the story. To get around this, you can define a *fallback function* within ink, which is run if the `EXTERNAL` function can't be found. To do so, simply create an ink function with the same name and parameters. For example, for the above `multiply` example, create the ink function:

```
=== function multiply(x,y) ===
// Usually external functions can only return placeholder
// results, otherwise they'd be defined in ink!
~ return 1
```

## Multiple parallel flows (BETA)

It is possible to have multiple parallel "flows" - allowing the following examples:

- A background conversation between two characters while the protagonist talks to someone else. The protagonist could then leave and interject in the background conversation.
- Non-blocking interactions: you could interact with an object with generates a bunch of choices, but "pause" them, and go and interact with something else. The original object's choices won't block you from interacting with something new, and you can resume them later.

The API is relatively simple:

- `story.switchFlow("Your flow name")` - create a new Flow context, or switch to an existing one. The name can be anything you like, though you may choose to use the same name as an entry knot that you would go on to choose with `story.choosePathString("knotName")`.
- `story.switchToDefaultFlow()` - before you start switching Flows there's an implicit default Flow. To return to it, call this method.
- `story.removeFlow("Your flow name")` - destroy a previously created Flow. If the Flow is already active, it returns to the default flow.
- `story.aliveFlowNames()` - the names of currently alive flows. A flow is alive if it's previously been switched to and hasn't been destroyed. Does not include default flow.
- `story.currentFlowIsDefaultFlow()` - true if the default flow is currently active. By definition, will also return true if not using flow functionality.
- `story.currentFlowName()` — a string containing the name of the currently active flow. May contain internal identifier for default flow, so use `currentFlowIsDefaultFlow()` to check first.

## Working with LISTs

Ink lists are a more complex type used in the ink engine, so interacting with them is a bit more involved than with ints, floats and strings.

Lists always need to know the origin of their items. For example, in ink you can do:

    ~ myList = (Orange, House)

...even though `Orange` may have come from a list called `fruit` and `House` may have come from a list called `places`. In ink these *origin* lists are automatically resolved for you when writing. However when working in game code, you have to be more explicit, and tell the engine which origin lists your items belong to.

To create a list with items from a single origin, and assign it to a variable in the game:

```zig
var new_list = try ink.InkList.initFromOrigin(allocator, "fruit", &story);
defer new_list.deinit();
try new_list.addItem("Orange");
try new_list.addItem("Apple");
try story.variables_state.set("myList", .{ .list = new_list });
```

If you're modifying a list, and you know that it has/had elements from a particular origin already:

```zig
var fruit = story.variables_state.get("fruit").?.list;
try fruit.addItem("Apple");
```

Note that single list items in ink, such as:

	VAR lunch = Apple

...are actually just lists with single items in them rather than a different type. So to create them on the game side, just use the techniques above to create a list with just one item.

You can also create lists from items if you explicitly know all the metadata for the items - i.e. the origin name as well as the int value assigned to it. This is useful if you're building a list out of existing lists. Note that `InkList` uses a hash map where the key is an `InkListItem` (which has `origin_name` and `item_name` fields), and the value is the int value:

```zig
var new_list = ink.InkList.init(allocator);
defer new_list.deinit();
const fruit = story.variables_state.get("fruit").?.list;
const places = story.variables_state.get("places").?.list;
var it = fruit.iterator();
while (it.next()) |entry| try new_list.add(entry.key, entry.value);
it = places.iterator();
while (it.next()) |entry| try new_list.add(entry.key, entry.value);
try story.variables_state.set("myList", .{ .list = new_list });
```

To test if your list contains a particular item:

```zig
const fruit = story.variables_state.get("fruit").?.list;
if (fruit.containsItemNamed("Apple")) {
    // We're eating apples tonight!
}
```

Lists also expose many of the operations you can do in ink:

```zig
list.minItem                // equivalent to calling LIST_MIN(list) in ink
list.maxItem                // equivalent to calling LIST_MAX(list) in ink
list.inverse                // equivalent to LIST_INVERT(list) in ink
list.all                    // equivalent to LIST_ALL(list) in ink
list.union(other_list)      // equivalent to (list + other_list) in ink
list.intersect(other_list)  // equivalent to (list ^ other_list) in ink
list.without(other_list)    // equivalent to (list - other_list) in ink
list.contains(other_list)   // equivalent to (list ? other_list) in ink
```

## Using the compiler

Precompiling your stories is more efficient than loading `.ink` at runtime. That said, it's a useful approach for some situations, and can be done with the following code:

```zig
// ink_source: e.g. @embedFile("story.ink") or loaded from disk
const ink_source: []const u8 = ...;
var compiler = try ink.Compiler.init(allocator, ink_source, .{});
defer compiler.deinit();
var story = try compiler.compile();
defer story.deinit();
std.debug.print("{s}\n", .{try story.cont()});
```

Note that if your story is broken up into several ink files using `INCLUDE`, you will need to provide a file handler:

```zig
var compiler = try ink.Compiler.init(allocator, ink_source, .{
    .count_all_visits = true,
    .file_handler = ink.FileHandler.fromDir(ink_dir),
});
defer compiler.deinit();
var story = try compiler.compile();
defer story.deinit();
std.debug.print("{s}\n", .{try story.cont()});
```
