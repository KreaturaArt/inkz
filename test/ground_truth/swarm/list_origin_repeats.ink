// Found by the differential swarm run (P19, seed 45287272184, case 00881): ink's
// `originNames` names one origin per item, repeats kept, and a copy of the list keeps them,
// so `(a, c) - (a, c)` is an empty list whose save names `l0` twice.
LIST l0 = a, b, c
LIST l2 = p2, q2
VAR v = (a)
~ temp t = (a, c, p2) - (a, c, p2)
~ temp u = LIST_RANGE((a, c), 5, 9)
~ temp x = t + ()
~ temp y = x - ()
~ v = (c, p2) - (c, p2)
{LIST_ALL(t)} {LIST_INVERT(x)} {LIST_ALL(u)} {LIST_INVERT(v)}
-> DONE
