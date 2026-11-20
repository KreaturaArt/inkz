VAR count = 3
VAR name = "Ink"
VAR flag = true
VAR price = 1.5
VAR where = -> knot
CONST LIMIT = 10
~ count = count + LIMIT
~ count++
~ count -= 2
{count} {name} {flag} {price}
-> where
== knot ==
Done.
-> DONE
