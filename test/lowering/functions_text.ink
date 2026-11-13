Before {describe(2)} after.
~ describe(3)
{describe(1)}
-> DONE
== function describe(n) ==
{n > 1:
  many
- else:
  one
}
~ return n
