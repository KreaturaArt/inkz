// P19.8 (swarm construct mistyped_divert): TURNS_SINCE and READ_COUNT of a variable that
// holds no divert target are ink's error, which says what it saw and, for an integer, asks
// whether a read count was meant; READ_COUNT's message names TURNS_SINCE too.
VAR i = 5
VAR f = 2.5
VAR s = "text"
-> END
== of_integer
{TURNS_SINCE(i)}
-> END
== of_float
{READ_COUNT(f)}
-> END
== of_string
{TURNS_SINCE(s)}
-> END
