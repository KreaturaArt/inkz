// The public API test's story (src/vm/api_test.zig): globals, a list, an external, tags,
// choices with tags, a knot with tags, a function and a knot with a parameter.
# author: tester
VAR score = 0
VAR name = "x"
LIST colours = red, green
EXTERNAL greet(who)
Hello # line tag
~ score = greet("you")
* [Left # choice tag] Went left
* Right
- (end) Done {score}
-> END
== knot ==
# knot tag
In knot
-> END
== with_parameter(word) ==
Said {word}
-> END
== function double(x) ==
~ return x * 2
== print_name ==
{name}
-> END
== in_function ==
~ two_lines()
-> END
== function two_lines() ==
First
Second
== function shout() ==
~ return greet("loud")
