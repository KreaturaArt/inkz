# Zig Guidelines

## AST Parsers

Node data should be stored as a MultiArrayList, the tree is represented by parent_idx, first_child_idx and child_len all idx should index into this one MultiArrayList.
