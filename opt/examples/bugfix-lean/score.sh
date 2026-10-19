#!/bin/bash
# score = diff_lines vs .orig/  +  100 per failed edge probe.
# GATE first: main test suite failing -> 9999 (no fix, no score).
cd "$(dirname "$0")"
if ! python3 test_calc.py > /dev/null 2>&1; then
  echo 9999; exit 0
fi
# resilience probe: adversarial edge cases beyond the test suite
edge_fails=$(python3 - <<'PY' 2>/dev/null
from calc import pct_change
import math
fails = 0
for old, new in [(0,0), (0,-5), (-0.0, 5), (1e-9, 1e9), (-1e9, -1e-9)]:
    try:
        r = pct_change(old, new)
        if isinstance(r, complex) or (isinstance(r, float) and math.isnan(r)):
            fails += 1
    except Exception:
        fails += 1
print(fails)
PY
)
lines=$(diff -u .orig/calc.py calc.py | grep -cE '^[+-][^+-]')
python3 -c "print(${lines:-9999} + 100*${edge_fails:-5})"
