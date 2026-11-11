// Audit: current choices, tags and the random state must survive save and load.
VAR roll = 0
~ roll = RANDOM(1, 1000)
First roll {roll}. #first
* Pick A #a
* Pick B #b
- ~ roll = RANDOM(1, 1000)
Second roll {roll}.
-> END
