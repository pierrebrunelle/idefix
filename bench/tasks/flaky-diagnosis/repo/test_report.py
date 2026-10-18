import os, sys
sys.setswitchinterval(0.0001)  # perturb scheduling so order varies across runs
from report import first_key
d = {"alpha": 1, "beta": 2, "gamma": 3}
assert first_key(d) == "alpha", f"expected alpha, got {first_key(d)}"
print("TEST PASSED")
