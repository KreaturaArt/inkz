VAR v0 = -126
VAR v1 = "text"
CONST c0 = 209
LIST l0 = a, (b), c
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
~ temp u2 = v0 * k0
-
-> hub
=== hub ===
-
+ Go 1 -> k0
+ Go 2 -> hub
=== tunnel0 ===
~ n34 = f2(n39)
->->
=== k0 ===
-> hub
-
+ Go 3 -> k0
+ Go 4 -> k0
+ Go 5 -> hub
* [Go 6] -> k0
= s0
{
- k0: Then
- else: Else
}
{
- k0: Then
- else: Else
}
{ v1:
- 1: One
- "text": Text
- else: Other
}
-> hub
=== function f0(x) ===
{ shuffle once:
- A
- B
}
~ return TURNS_SINCE(-> k0)
=== function f1() ===
{ shuffle once:
- A
- B
}
~ f3(n38)
{
- TURNS_SINCE(-> k0) or TURNS_SINCE(-> k0): Then
- else: Else
}
~ return v0 >= k0
=== function e0(x) ===
~ temp u2 = 25.5 or 193.5
~ return n30 % TURNS_SINCE(-> k0)
=== function f2(ref x) ===
~ x++
~ return x
=== function f3(ref y) ===
~ f2(y)
~ return y
