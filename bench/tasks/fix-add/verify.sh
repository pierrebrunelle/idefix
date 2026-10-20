#!/bin/bash
cd "$1" && python3 test_calc.py >/dev/null 2>&1 && python3 -c "
from calc import add
assert add(2, 3) == 5
assert add(-1, 1) == 0
assert add(10, -4) == 6
assert add(0.5, 0.25) == 0.75
"
