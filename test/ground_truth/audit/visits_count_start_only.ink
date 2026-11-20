// P5.6: knots and stitches count visits only when entered at their start (count_start_only).
// Diverting to a label inside the knot from inside it, to the knot itself, and to a stitch
// from inside the stitch. A counter keeps the loops finite.
VAR loops = 0
-> hub
== hub ==
Hub visits: {hub}
- (again) Loop visits: {again}, hub: {hub}
~ loops = loops + 1
{ loops < 2: -> again }
{ loops < 4: -> hub }
-> inner
= inner
Inner stitch: {inner}, hub: {hub}
~ loops = loops + 1
{ loops < 6: -> inner }
-> END
