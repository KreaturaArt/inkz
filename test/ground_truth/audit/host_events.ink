// P6.3: where ink fires its host events: each Continue, each choice, each evaluated
// function (start and end), each ChoosePathString.
VAR score = 0
Start
* [Go] Gone
- Middle
-> END
== elsewhere ==
Elsewhere
-> END
== function bump(x) ==
Bumping
~ score = score + x
~ return score
