// Audit S1: evaluate_function keeps its side effects on globals and visit counts.
VAR total = 0
Start {total}.
* [Next] Now {total}, visited {add.inside} times.
    -> END

=== function add(amount) ===
- (inside)
~ total += amount
Added {amount}.
~ return total
