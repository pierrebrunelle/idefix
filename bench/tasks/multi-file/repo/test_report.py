from report import summary
from stats import mean

assert mean([1, 2]) == 1.5, f"got {mean([1, 2])}"
assert mean([1, 2, 3]) == 2.0
assert summary([1, 2]) == "mean=1.5"
print("TEST PASSED")
