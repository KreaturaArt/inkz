// Audit (P2.4): shuffle seeds hash a container's path as UTF-16 code units, so names outside
// ASCII and outside the Basic Multilingual Plane must hash like ink.
-> café
=== café ===
{~one|two|three|four} {~a|b|c}
-> naïve.ünïcode
=== naïve ===
= ünïcode
{~one|two|three|four}
-> END
