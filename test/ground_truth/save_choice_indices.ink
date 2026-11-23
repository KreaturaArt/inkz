// A save keeps each choice's index as the host last read it (ink's Story.currentChoices
// skips invisible default choices), and a load keeps the saved indices: the fallback choice
// loads visible, so the indices change only when the host reads the choices again.
-> menu
=== menu
Pick one.
* [Apples] -> done
* -> fallback
* [Pears] -> done
=== fallback
Nothing left.
-> END
=== done
Done.
-> END
