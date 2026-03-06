# Zig Guidelines

## IO

io parameter need to be passed into all functions that require it. For unit-tests please use:

`std.testing.io`

In the application use: 

```zig
var threaded: Io.Threaded = if (builtin.single_threaded)
    .init_single_threaded
else
    .init(gpa);
defer threaded.deinit();
const io = threaded.io();
```

## Tokenizers

Should be written using zigs labelled switch syntax:

```zig
pub fn next(t: *Tokenizer, src: [:0]const u8, skip_comments: bool) Token {
    var tok: Token = .{
        .tag = undefined,
        .loc = .{
            .start = t.idx,
            .end = undefined,
        },
    };

    // defer std.debug.print("returning '{s}' {t} \n", .{ tok.loc.slice(src), tok.tag });
    state: switch (State.start) {
        .start => switch (src[t.idx]) {
            0 => {
                tok.tag = .eof;
                tok.loc.start = @intCast(src.len); // code.len may == 0
                tok.loc.end = @intCast(src.len);
                return tok;
            },
            ' ', '\t', '\r' => {
                t.idx += 1;
                tok.loc.start += 1;
                continue :state .start;
            }

        ...

    }
    comptime unreachable;
}
```



## Shared DOP AST & Zero Runtime Allocation

The compiler and runtime share the same **Data Oriented Programming (DOP) AST**:

- The compiler builds the DOP AST from `.ink` source and serializes it to `.ink.json`.
- The runtime deserializes `.ink.json` into the **same** DOP AST structure at startup (`Story.initFromJson()`).
- **All memory allocation must happen at startup or during JSON deserialization.** There must be **zero dynamic heap allocation** during story execution (`step()`, `cont()`).

This means:
- Do not call `allocator.alloc` / `ArrayList.append` inside `step()` or any function called from the hot evaluation path.
- Pre-allocate buffers, use fixed-size stack arrays, or slice into already-allocated memory.
- Output strings should be slices into the source JSON buffer or a pre-allocated intern pool.

## AST Parsers

Node data should be stored as a MultiArrayList, the tree is represented by parent_idx, first_child_idx and child_len all idx should index into this one MultiArrayList.
