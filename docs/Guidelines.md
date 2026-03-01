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



## AST Parsers

Node data should be stored as a MultiArrayList, the tree is represented by parent_idx, first_child_idx and child_len all idx should index into this one MultiArrayList.
