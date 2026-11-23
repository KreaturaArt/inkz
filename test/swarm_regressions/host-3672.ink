VAR v0 = 8
VAR v1 = "text"
VAR v2 = true
CONST c0 = 56
LIST l0 = a, (b), c
LIST l1 = a, d
VAR n0 = 0
VAR n1 = 1
VAR n2 = 2
VAR n3 = 3
VAR n4 = 4
VAR n5 = 5
VAR n6 = 6
VAR n7 = 7
VAR n8 = 8
VAR n9 = 9
VAR n10 = 10
VAR n11 = 11
VAR n12 = 12
-> k0
-
-> hub
=== hub ===
-
+ [Go 1] -> k0
+ Go 2 -> k0
+ Go 3 -> hub
* [Go 4] -> hub
=== k0 ===
~ n9 = FLOAT(107.5) == f3(v0) / f0(1)
x\{y\}
-
+ Go 5 -> hub
+ [Go 6 # ct6] -> hub
+ [Go 7 # ct7] -> k0
= s0
-
* [Go 8] -> k0.s0
+ Go 9 -> k0
+ [Go 10 # ct10] -> hub
=== tunnel1(x) ===
Tunnel {x}
~ x++
->->
=== thread1(x) ===
Thread {x}
* [Thread {x}] -> hub
=== jump1(x, -> t) ===
Jump {x}
-> t
=== function f0(x) ===
Before <>
<> after
~ return TURNS_SINCE(-> k0) or TURNS_SINCE(-> k0) / LIST_COUNT(l0)
=== function f1() ===
~ f2(v2)
~ return n4 / TURNS_SINCE(-> k0) - TURNS_SINCE(-> k0)
=== function e0(x) ===
~ return TURNS_SINCE(-> k0)
=== function f2(ref x) ===
~ x++
~ return x
=== function f3(ref y) ===
~ f2(y)
~ return y
