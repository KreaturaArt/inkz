// P7.5: sequences.
{a|b|c}
{&a|b}
{!once|twice}
{~shuffled|ones}
{$stop|ping}
{&~cycle|shuffle} // inkz-error
{|empty first|}
{once: a|b}
{shuffle once: a|b}
{cycle:
- one
- two
}
{stopping:
- first
-
- third
}
