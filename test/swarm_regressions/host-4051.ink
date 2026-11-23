CONST c0 = 40
LIST l1 = a, d
<- thread1(CHOICE_COUNT())
<- thread1(f0(1))
~ e0(MIN(1, 58))
- !
- the cat
- a
~ temp u1 = e0(2)
~ u1++

-
-> hub
=== hub ===
-
+ Go 4 -> hub
+ Go 5 -> hub
+ Go 6 -> k0
* Go 7 -> k0
=== k0 ===
~ temp u3 = e0(2)
-
+ Go 8 -> hub
+ Go 9 -> k0
+ Go 10 -> k0
= s0
-
+ Go 11 -> hub
+ [Go 12 # ct12] -> hub
+ [Go 13 # ct13] -> k0
+ [Go 14 # ct14] -> hub
=== k1 ===
-
+ Go 15 -> k0
* Go 16 -> k0
+ [Go 17 # ct17] -> hub
=== k2 ===
~ temp u2 = false
-
+ Go 18 -> k0
+ Go 19 -> hub
* Go 20 -> hub
=== tunnel1(x) ===
Tunnel {x}
~ x++
->->
=== thread1(x) ===
Thread {x}
* [Thread {x}] -> hub
-> DONE
=== jump1(x, -> t) ===
Jump {x}
-> t
=== function f0(x) ===
~ f0(MIN(1, 116.5))
~ f0(x)
~ temp t0 = l1.d
  spaced  
x\{y\}
~ temp u3 = k0
~ temp u0 = CEILING(1)
~ return c0
=== function f1() ===
~ f0(CHOICE_COUNT())
~ temp u2 = k0
~ return k0
=== function e0(x) ===
~ return k0
