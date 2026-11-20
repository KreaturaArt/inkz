// P5.7: observers fire once per variable per Continue, after the line, with the latest
// value; a host set outside Continue fires at once. The second line changes x after its
// newline, during the lookahead of the first.
VAR x = 0
VAR y = 0
~ x = 1
~ x = 2
~ y = 1
One
~ x = 3
Two
-> END
