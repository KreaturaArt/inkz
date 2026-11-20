// Variable pointers with contexts -1, 0 and n (P16.9): a ref parameter passed a global, a
// temp, and a function's own parameter, passed on as a pointer to a pointer.
VAR g = 1
~ temp t = 10
~ add(g)
~ add(t)
~ pass_on(g)
~ pass_on(t)
{g} {t} {outer(5)}
-> END
=== function add(ref x) ===
~ x = x + 1
=== function pass_on(ref y) ===
~ add(y)
~ add(y)
=== function outer(n) ===
~ pass_on(n)
~ return n
