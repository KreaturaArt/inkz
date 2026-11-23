// Found by the differential swarm run (P19, seed 45282696297, case 00408): a divert to a
// target in a variable goes to the container itself (ink's PointerAtPath), so only that
// container is counted, not the knot around it, and a divert to the knot it is in counts
// that knot again. `n` ends the loop if it doesn't.
VAR d = -> k0.s0
VAR self = -> k1
VAR n = 0
-> k0
=== k0 ===
-> hop(d)
= s0
{k0} {k0.s0}
-> k1
=== k1 ===
~ n++
{k1}
{k1 < 3 && n < 5: -> self}
-> DONE
=== hop(-> t) ===
-> t
