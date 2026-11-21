// PR #2 review: a divert through a variable that holds a string, a list, a bool or a float
// says what it held, in ink's words (its ToString); only the integer 0 is 'empty/null'.
VAR s = "hi"
LIST l = a, b
VAR li = (b, a)
VAR none = ()
VAR yes = true
VAR f = 1.5
-> END
== by_string
-> s
== by_list
-> li
== by_empty_list
-> none
== by_bool
-> yes
== by_float
-> f
