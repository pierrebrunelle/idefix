#!/bin/bash
# score = wall seconds of fibs.py, but ONLY if the output is correct.
# Wrong answer -> worst possible score. Prints one float, lower is better.
# expected output from a fast reference (no recursion) — the oracle
expected=$(python3 - <<'EOF'
a, b = 0, 1
for _ in range(40):
    a, b = b, a + b
print(a)
EOF
)
out=$(cd "$(dirname "$0")" && /usr/bin/time -p python3 fibs.py 2>/tmp/fib-time.$$ | head -1)
secs=$(awk '/^real/ {print $2}' /tmp/fib-time.$$)
if [ "$out" != "$expected" ]; then
  { echo "expected '$expected', got '${out:-<no output>}'"
    grep -vE '^(real|user|sys)' /tmp/fib-time.$$ | tail -5; } >&2
  rm -f /tmp/fib-time.$$
  echo 9999
else
  rm -f /tmp/fib-time.$$
  echo "${secs:-9999}"
fi
