// Smoke case for the reference harness: text, glue, tags, choices and a seeded shuffle.
Hello, <>
world. #greeting #first
-> start

=== start ===
{~Red|Green|Blue} light.
* [Left] You go left. #path
    -> finish
* Right # right
    You go right.
    -> finish

=== finish ===
The end.
-> END
