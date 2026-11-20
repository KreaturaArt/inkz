// P5.6: returning from a function or tunnel restores the pointer without a divert, so the
// caller's containers are not counted again.
-> knot
== knot ==
Before: {knot}
~ helper()
After function: {knot}
-> tunnel ->
After tunnel: {knot}
- (gather) Gather: {gather}, knot: {knot}
-> END
== function helper() ==
~ return 1
== tunnel ==
In tunnel: {tunnel}
->->
