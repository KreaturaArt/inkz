// Audit S2: Continue returns one line; glue after a newline joins it to the next.
First line.
Second <>
line. #second
Third line
{true:
    <> still third.
}
-> END
