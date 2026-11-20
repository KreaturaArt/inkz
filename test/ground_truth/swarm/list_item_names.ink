// List items by full and bare name across two lists (P16.9): a bare name only one list has,
// full names for the one both have, and a global that holds a list.
LIST colours = red, (green), blue
LIST moods = (calm), red
VAR seen = green
~ temp pick = blue
{pick} {colours.red} {moods.red} {calm} {seen}
~ seen += colours.red
{seen} {LIST_COUNT(seen)} {seen ? green}
-> END
