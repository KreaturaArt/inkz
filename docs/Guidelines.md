# Zig Guidelines

## IO

io parameter need to be passed into all functions that require it. For unit tests please use:

```zig
var threaded: Io.Threaded = if (builtin.single_threaded)
    .init_single_threaded
else
    .init(gpa);
defer threaded.deinit();
const io = threaded.io();
```

## AST Parsers

Node data should be stored as a MultiArrayList, the tree is represented by parent_idx, first_child_idx and child_len all idx should index into this one MultiArrayList.




