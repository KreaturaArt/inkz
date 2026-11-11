// Audit (compiler): list items after an explicit value continue from it.
LIST levels = low = 5, mid, (high = 10), top
{LIST_VALUE(mid)} {LIST_VALUE(high)} {LIST_VALUE(top)} {levels}
