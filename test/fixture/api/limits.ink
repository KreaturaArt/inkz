// Stories for the limit errors of the public API test: each knot runs into one limit when
// the story's limits are small.
VAR x = 0
VAR y = 0
LIST letters = alpha, beta, gamma
-> DONE
== deep_expression ==
{1 + (2 + (3 + (4 + 5)))}
-> DONE
== recursion ==
{count_down(20)}
-> DONE
== threads ==
<- side
<- side
Main
-> DONE
== side ==
* Side
-> DONE
== many_temps ==
~ temp a = 1
~ temp b = 2
~ temp c = 3
~ temp d = 4
~ temp e = 5
{a + b + c + d + e}
-> DONE
== long_line ==
a {1} b {2} c {3} d {4} e {5} f {6} g {7} h {8}
-> DONE
== many_choices ==
* One
* Two
* Three
- -> DONE
== tagged_choices ==
* One # a # b # c
* Two # d # e # f
- -> DONE
== concatenation ==
~ temp s = "abcdefghij"
~ s = s + s
~ s = s + s
~ s = s + s
~ s = s + s
{s}
-> DONE
== tunnel_choice ==
-> chooser ->
-> DONE
== chooser ==
* Pick
- ->->
== lists ==
{LIST_ALL(letters)}
-> DONE
== globals_after_newline ==
Line
~ x = 1
~ y = 2
More
-> DONE
== two_globals ==
~ x = 1
~ y = 2
Line
-> DONE
== loop ==
- (top) -> top
== function count_down(n) ==
{ n > 0:
    ~ return count_down(n - 1)
}
~ return 0
