VAR score = 0
~ add_to(score, 5)
{score}
~ temp target = -> elsewhere
-> go(target)
== function add_to(ref value, amount) ==
~ value = value + amount
== go(-> where) ==
-> where
== elsewhere ==
Elsewhere.
-> tunnel ->-> after
== tunnel ==
->-> after
== after ==
After.
-> DONE
