#!/bin/bash
cd "$1" && python3 test_calc.py >/dev/null 2>&1 && python3 -c "
from calc import square, pythag
assert square(3) == 9 and square(-2) == 4 and square(0) == 0
assert pythag(3, 4) == 25 and pythag(-1, 2) == 5 and pythag(0, 0) == 0
"
