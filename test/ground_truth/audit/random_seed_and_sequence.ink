// Audit S7: SEED_RANDOM keeps the sign, previousRandom advances, shuffles use the path hash.
~ SEED_RANDOM(-7)
{RANDOM(1, 1000)} {RANDOM(1, 1000)} {RANDOM(1, 1000)}
- (again)
{~a|b|c|d|e} {~1|2|3|4|5}
{ again < 6: -> again }
-> END
