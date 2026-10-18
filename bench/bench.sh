#!/bin/bash
# Benchmark: mojo agent vs python reference client, same model/task/budgets.
# Each run gets a fresh copy of the fixture; pass = calc.py fixed AND test prints TEST PASSED.
# Usage: bench.sh [RUNS]   (default 3)
set -u
RUNS="${1:-3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_SRC="$(dirname "$0")/fixture"
OUT="$(dirname "$0")/results.tsv"
TASK="In this repo, calc.py has a bug: add() subtracts instead of adding. Use bash to fix the file, then run 'python3 test_calc.py' to verify it prints TEST PASSED. Keep using the bash tool until the test passes, then report."
export MAX_MODEL="${MAX_MODEL:-Qwen/Qwen3-1.7B}"
export MAX_BASE_URL="${MAX_BASE_URL:-http://127.0.0.1:8000/v1}"

printf "client\trun\tpass\trequests\tcommands\tprompt_tokens\twall_s\n" > "$OUT"
for client in mojo ref; do
  for run in $(seq 1 "$RUNS"); do
    repo=$(mktemp -d)
    cp "$FIXTURE_SRC"/* "$repo"/
    start=$(python3 -c 'import time; print(time.time())')
    if [ "$client" = mojo ]; then
      log=$("$ROOT/agent" --repo "$repo" --max-requests 15 --max-seconds 420 --temperature 0.6 --transcript "$repo/t.json" "$TASK" 2>&1)
    else
      python3 "$ROOT/tests/ref_client.py" --repo "$repo" "$TASK" >"$repo/log.txt" 2>&1 &
      local_pid=$!
      (sleep 420; kill "$local_pid" 2>/dev/null) & watchdog=$!
      wait "$local_pid" 2>/dev/null; kill "$watchdog" 2>/dev/null
      log=$(cat "$repo/log.txt")
    fi
    end=$(python3 -c 'import time; print(time.time())')
    wall=$(python3 -c "print(f'{$end-$start:.1f}')")
    pass=0
    if grep -q "a + b" "$repo/calc.py" && (cd "$repo" && python3 test_calc.py >/dev/null 2>&1); then
      pass=1
    fi
    req=$(echo "$log" | grep -o "requests=[0-9]*" | tail -1 | cut -d= -f2)
    cmd=$(echo "$log" | grep -o "commands=[0-9]*" | tail -1 | cut -d= -f2)
    tok=$(echo "$log" | grep -o "prompt_tokens=[0-9]*" | tail -1 | cut -d= -f2)
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$client" "$run" "$pass" "${req:-?}" "${cmd:-?}" "${tok:-?}" "$wall" >> "$OUT"
    rm -rf "$repo"
  done
done
column -t -s$'\t' "$OUT"
