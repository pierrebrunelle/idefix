import math, sys
from calc import pct_change

assert pct_change(100, 110) == 10.0
assert abs(pct_change(200, 250) - 25.0) < 1e-9
try:
    r = pct_change(0, 50)
    assert math.isinf(r) or r == 0.0
except Exception:
    sys.exit(1)
r = pct_change(-100, -50)
assert isinstance(r, float)
print("PASS")
