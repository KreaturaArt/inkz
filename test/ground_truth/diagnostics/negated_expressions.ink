LIST l = a
VAR v = 1
{not (v + 1) ? a}
{not f(v, 2) ? a}
{not -v ? a}
-> END
=== function f(x, y) ===
~ return x
