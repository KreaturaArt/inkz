// Audit S8: ink integers are 32-bit and wrap; floats are 32-bit.
VAR big = 2147483647
~ big = big + 1
{big}
{7 / 3.0}
{0.1 + 0.2}
{1000000.0 * 3.3}
