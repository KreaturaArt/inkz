VAR x = 2
{x > 1: big|small}
{x: yes}
{
- x == 1: one
- x == 2: two
- else: many
}
{ x:
- 1: One
- 2: Two
- else: Other
}
-> DONE
