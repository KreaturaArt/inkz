// P5.9: RANDOM with the largest range ink numbers allow, a seeded sequence, then a range
// whose max - min + 1 overflows an int, which ink reports as an error.
~ SEED_RANDOM(7)
Widest: {RANDOM(0, 2147483646)}
Dice: {RANDOM(1, 6)} {RANDOM(1, 6)} {RANDOM(1, 6)}
Negative: {RANDOM(-10, -5)}
Too wide: {RANDOM(-2000000000, 2000000000)}
-> END
