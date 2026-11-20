// P7.8: errors are recorded and parsing goes on; later knots still parse.
== first ==
~ temp = 5 // inkz-error
VAR = 1 // inkz-error
Text { unclosed // inkz-error
* {cond choice // inkz-error
-> knot(1 // inkz-error
~ x = 1 + // inkz-error
~ 5 + 4 // inkz-error
~ return
LIST = a // inkz-error
{ x:
- 1: one
- else: two
- 3: three
} // inkz-error
Fine.
== second ==
Still parsed.
== empty ==
== third == // inkz-error
Also parsed.
= stitch
In a stitch.
