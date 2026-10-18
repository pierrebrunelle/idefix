#!/bin/bash
# Trouble-path tests against the stub. Requires ./agent built and MAX_MODEL set.
set -u
cd "$(dirname "$0")/.."
export MAX_BASE_URL="http://127.0.0.1:18923/v1"
export MAX_MODEL="${MAX_MODEL:-test-model}"
FAIL=0

run_mode() {
    local mode="$1"; shift
    python3 tests/stub_server.py 18923 "$mode" 2>/tmp/stub_$mode.log &
    local pid=$!
    sleep 0.6
    "$@" ; local rc=$?
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return $rc
}

check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want=$2 got=$3)"; FAIL=1; fi
}

# 1. normal: tool_calls then final, exit 0
out=$(run_mode normal ./agent --repo . "task" 2>/dev/null); rc=$?
check "normal exit" 0 "$rc"
check "normal answer" "Done." "$out"

# 2. badargs: invalid arguments JSON -> error result, no exec, then final, exit 0
out=$(run_mode badargs ./agent --repo . "task" 2>/dev/null); rc=$?
check "badargs exit" 0 "$rc"
grep -q "not valid JSON" /tmp/stub_badargs.log && echo "PASS badargs error result" || { echo "FAIL badargs error result"; FAIL=1; }

# 3. malformed: invalid envelope -> exit 3
out=$(run_mode malformed ./agent --repo . "task" 2>/dev/null); rc=$?
check "malformed exit" 3 "$rc"

# 4. batch: two calls -> two results in order
out=$(run_mode batch ./agent --repo . "task" 2>/dev/null); rc=$?
check "batch exit" 0 "$rc"
check "batch answer" "Done." "$out"
n=$(grep -c "tool_call_id" /tmp/stub_batch.log || true)
grep -q "call_a.*call_b\|expected=\['call_a', 'call_b'\]" /tmp/stub_batch.log && echo "PASS batch pairing" || { echo "FAIL batch pairing"; cat /tmp/stub_batch.log; FAIL=1; }

# 5. sleep: timeout kills process group -> tool result exit_code 124, then final
start=$(python3 -c 'import time;print(time.time())')
out=$(run_mode sleep ./agent --repo . --max-command-seconds 1 "task" 2>/dev/null); rc=$?
elapsed=$(python3 -c "import time;print(int(time.time()-$start))")
check "sleep exit" 0 "$rc"
check "sleep killed fast" 1 "$([ "$elapsed" -le 6 ] && echo 1 || echo 0)"
grep -q "exit_code..124" /tmp/stub_sleep.log && echo "PASS sleep 124" || { echo "FAIL sleep 124"; cat /tmp/stub_sleep.log; FAIL=1; }
pgrep -f "exec sleep 30" >/dev/null && { echo "FAIL orphan survived"; FAIL=1; } || echo "PASS no orphan"

# 6. budget: max-requests 1 -> exit 2
out=$(run_mode normal ./agent --repo . --max-requests 1 "task" 2>/dev/null); rc=$?
check "budget exit" 2 "$rc"

# 7. transcript written
rm -f /tmp/agent_t.json
run_mode normal ./agent --repo . --transcript /tmp/agent_t.json "task" >/dev/null 2>&1
python3 -c "import json;d=json.load(open('/tmp/agent_t.json'));assert [m['role'] for m in d]==['system','user','assistant','tool'],d" && echo "PASS transcript" || { echo "FAIL transcript"; FAIL=1; }

# 8. --help exits cleanly
out=$(./agent --help 2>&1); rc=$?
check "help rc" 0 "$rc"
echo "$out" | grep -q "usage: agent" && echo "PASS help text" || { echo "FAIL help text"; FAIL=1; }

exit $FAIL
