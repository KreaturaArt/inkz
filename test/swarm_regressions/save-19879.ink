VAR v0 = 25
VAR v1 = "text"
VAR v2 = true
CONST c0 = 186
LIST l0 = a, (b), c
EXTERNAL e0(x)
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
VAR n13 = 13
VAR n14 = 14
VAR n15 = 15
VAR n16 = 16
VAR n17 = 17
VAR n18 = 18
VAR n19 = 19
VAR n20 = 20
VAR n21 = 21
VAR n22 = 22
VAR n23 = 23
VAR n24 = 24
VAR n25 = 25
VAR n26 = 26
VAR n27 = 27
VAR n28 = 28
VAR n29 = 29
VAR n30 = 30
VAR n31 = 31
VAR n32 = 32
VAR n33 = 33
VAR n34 = 34
VAR n35 = 35
VAR n36 = 36
VAR n37 = 37
VAR n38 = 38
VAR n39 = 39
VAR n40 = 40
VAR n41 = 41
VAR n42 = 42
VAR n43 = 43
VAR n44 = 44
VAR n45 = 45
VAR n46 = 46
VAR n47 = 47
VAR n48 = 48
VAR n49 = 49
VAR n50 = 50
VAR n51 = 51
VAR n52 = 52
VAR n53 = 53
VAR n54 = 54
VAR n55 = 55
VAR n56 = 56
VAR n57 = 57
VAR n58 = 58
VAR n59 = 59
VAR n60 = 60
VAR n61 = 61
VAR n62 = 62
VAR n63 = 63
VAR d0 = -> hub
-
-> hub
=== hub ===
-
+ Go 1 -> k2
* Go 2 -> k2
+ Go 3 -> k1
+ [Go 4 # ct4] -> k1
=== tunnel0 ===
->->
=== k0 ===
~ d0 = -> hub
+++ -> hub
*** [Only choice]
Line # tag1
-
* [Go 6 # ct6] -> k1
+ Go 7 -> k2
+ Go 8 -> k0.s0
= s0
-
+ [Go 9] -> k0
+ [Go 10 # ct10] -> hub
=== k1 ===
{ c0 <= TURNS():
If yes
- else:
If no
}
Before <>
<> after
~ d0 = -> hub
+ -> hub
+ Start # ct11a [choice # ct11b] end # ct11c
Line # tag0
the cat
~ SEED_RANDOM(c0)
~ f2(v2)
~ f2(n33)
{ RANDOM(1, 3):
If yes
- else:
If no
}
-
+ [Go 12 # ct12] -> k0
+ [Go 13 # ct13] -> hub
* Go 14 -> k0
+ Go 15 -> k1
=== k2 ===
{ l0.a:
If yes
- else:
If no
}
~ temp u2 = INT(-122) < c0 + f0(1) < false
<- hub
-
+ Go 16 -> k2
+ Go 17 -> k0
+ Go 18 -> k1
+ Go 19 -> k0.s0
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
~ return CHOICE_COUNT()
=== function f1() ===
~ d0 = -> hub
~ d0 = -> hub
~ f2(n56)
~ d0 = -> hub
{ c0 - false - f3(v2) and LIST_COUNT(l0):
If yes
- else:
If no
}
~ SEED_RANDOM(-56)
~ e0(TURNS())
~ d0 = -> hub
~ e0(INT(c0) / LIST_VALUE(l0) / f2(v2) - 157.5)
{ stopping:
- First
- Second
}
~ return RANDOM(1, 3) > v2 - false >= k1
=== function e0(x) ===
Hello
{ stopping:
- First
- Second
}
~ return LIST_COUNT(l0) <= c0
=== function f2(ref x) ===
~ x++
~ return x
=== function f3(ref y) ===
~ f2(y)
~ return y
