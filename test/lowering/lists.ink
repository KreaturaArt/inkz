LIST colours = red, (green), blue = 5
VAR picked = (red, blue)
{colours} {picked} {LIST_COUNT(picked)}
~ picked += green
{picked has green} {colours(1)} {colours()}
-> DONE
