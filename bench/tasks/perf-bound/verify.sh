#!/bin/bash
cd "$1" && out=$(python3 -c "
import time, subprocess, sys
t = time.time()
try:
    r = subprocess.run(['python3', 'fibs.py'], capture_output=True, text=True, timeout=12)
except subprocess.TimeoutExpired:
    sys.exit(1)
print(r.stdout.strip() + '|' + str(time.time() - t))") \
  && [ "${out%%|*}" = "102334155" ] \
  && python3 -c "import sys; sys.exit(0 if float('${out##*|}') < 5 else 1)"
