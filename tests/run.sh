#!/bin/bash
# Trouble-path tests against the stub. Requires ./max built and MAX_MODEL set.
set -u
cd "$(dirname "$0")/.."
export MAX_BASE_URL="http://127.0.0.1:18923/v1"
export MAX_MODEL="${MAX_MODEL:-test-model}"
export MAX_STATE_DIR=/tmp/mma-test-state   # keep tests out of real $HOME
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
out=$(run_mode normal ./max --repo . "task" 2>/dev/null); rc=$?
check "normal exit" 0 "$rc"
check "normal answer" "Done." "$out"

# 2. badargs: invalid arguments JSON -> error result, no exec, then final, exit 0
out=$(run_mode badargs ./max --repo . "task" 2>/dev/null); rc=$?
check "badargs exit" 0 "$rc"
grep -q "not valid JSON" /tmp/stub_badargs.log && echo "PASS badargs error result" || { echo "FAIL badargs error result"; FAIL=1; }

# 3. malformed: invalid envelope -> exit 3
out=$(run_mode malformed ./max --repo . "task" 2>/dev/null); rc=$?
check "malformed exit" 3 "$rc"

# 4. batch: two calls -> two results in order
out=$(run_mode batch ./max --repo . "task" 2>/dev/null); rc=$?
check "batch exit" 0 "$rc"
check "batch answer" "Done." "$out"
n=$(grep -c "tool_call_id" /tmp/stub_batch.log || true)
grep -q "call_a.*call_b\|expected=\['call_a', 'call_b'\]" /tmp/stub_batch.log && echo "PASS batch pairing" || { echo "FAIL batch pairing"; cat /tmp/stub_batch.log; FAIL=1; }

# 5. sleep: timeout kills process group -> tool result exit_code 124, then final
start=$(python3 -c 'import time;print(time.time())')
out=$(run_mode sleep ./max --repo . --max-command-seconds 1 "task" 2>/dev/null); rc=$?
elapsed=$(python3 -c "import time;print(int(time.time()-$start))")
check "sleep exit" 0 "$rc"
check "sleep killed fast" 1 "$([ "$elapsed" -le 6 ] && echo 1 || echo 0)"
grep -q "exit_code..124" /tmp/stub_sleep.log && echo "PASS sleep 124" || { echo "FAIL sleep 124"; cat /tmp/stub_sleep.log; FAIL=1; }
pgrep -f "exec sleep 30" >/dev/null && { echo "FAIL orphan survived"; FAIL=1; } || echo "PASS no orphan"

# 6. budget: max-requests 1 -> exit 2
out=$(run_mode normal ./max --repo . --max-requests 1 "task" 2>/dev/null); rc=$?
check "budget exit" 2 "$rc"

# 7. transcript written
rm -f /tmp/agent_t.json
run_mode normal ./max --repo . --transcript /tmp/agent_t.json "task" >/dev/null 2>&1
python3 -c "import json;d=json.load(open('/tmp/agent_t.json'));assert [m['role'] for m in d]==['system','user','assistant','tool','assistant'],d" && echo "PASS transcript" || { echo "FAIL transcript"; FAIL=1; }

# 8. --help exits cleanly
out=$(./max --help 2>&1); rc=$?
check "help rc" 0 "$rc"
echo "$out" | grep -q "usage: max" && echo "PASS help text" || { echo "FAIL help text"; FAIL=1; }

# 9. REPL: piped lines share one session; /quit exits clean; EOF-clean exit
out=$(printf 'one\ntwo\n/quit\n' | run_mode normal ./max --repo . 2>/dev/null); rc=$?
check "repl exit" 0 "$rc"
check "repl two turns" $'Done.\nDone.' "$out"
out=$(./max </dev/null 2>&1); rc=$?
check "repl EOF exit" 0 "$rc"

# 10. flaky: server 500 once -> retry succeeds
rm -rf /tmp/mma-state-flaky
out=$(run_mode flaky ./max --repo . --state-dir /tmp/mma-state-flaky "task" 2>/dev/null); rc=$?
check "flaky exit" 0 "$rc"
check "flaky answer" "Done." "$out"
grep -q '"ev":"retry"' /tmp/mma-state-flaky/sessions/*/journal.jsonl && echo "PASS flaky journal" || { echo "FAIL flaky journal"; FAIL=1; }

# 11. bigusage: prompt_tokens over --compact-at -> next request carries cleared tool output
rm -rf /tmp/mma-state-compact
out=$(run_mode bigusage ./max --repo . --compact-keep 0 --state-dir /tmp/mma-state-compact "task" 2>/dev/null); rc=$?
check "bigusage exit" 0 "$rc"
check "bigusage answer" "Done." "$out"
grep -q "cleared; re-run" /tmp/stub_bigusage.log && echo "PASS bigusage cleared" || { echo "FAIL bigusage cleared"; cat /tmp/stub_bigusage.log; FAIL=1; }
grep -q '"ev":"compact"' /tmp/mma-state-compact/sessions/*/journal.jsonl && echo "PASS bigusage journal" || { echo "FAIL bigusage journal"; FAIL=1; }

# 12. ctxerr: 400 context-length -> compact + retry -> Done
rm -rf /tmp/mma-state-ctx
out=$(run_mode ctxerr ./max --repo . --compact-keep 0 --state-dir /tmp/mma-state-ctx "task" 2>/dev/null); rc=$?
check "ctxerr exit" 0 "$rc"
check "ctxerr answer" "Done." "$out"
grep -q "cleared; re-run" /tmp/stub_ctxerr.log && echo "PASS ctxerr cleared" || { echo "FAIL ctxerr cleared"; cat /tmp/stub_ctxerr.log; FAIL=1; }

# 13. loop: same command every turn -> loop_warning in tool result
out=$(run_mode loop ./max --repo . --max-requests 6 "task" 2>/dev/null); rc=$?
check "loop exit" 2 "$rc"
grep -q "loop_warning" /tmp/stub_loop.log && echo "PASS loop warning" || { echo "FAIL loop warning"; cat /tmp/stub_loop.log; FAIL=1; }

# 14. status file + journal events for a normal run
rm -rf /tmp/mma-state-obs
run_mode normal ./max --repo . --state-dir /tmp/mma-state-obs "task" >/dev/null 2>&1
ls /tmp/mma-state-obs/sessions/*/status >/dev/null 2>&1 && echo "PASS status file" || { echo "FAIL status file"; FAIL=1; }
J=$(ls /tmp/mma-state-obs/sessions/*/journal.jsonl 2>/dev/null)
grep -q '"ev":"run"' $J && grep -q '"ev":"done"' $J && echo "PASS journal events" || { echo "FAIL journal events"; cat $J 2>/dev/null; FAIL=1; }

# 15. --continue: resumes this repo's journal
rm -rf /tmp/mma-state-cont
run_mode normal ./max --repo . --state-dir /tmp/mma-state-cont "task" >/dev/null 2>&1
out=$(run_mode normal ./max --repo . --state-dir /tmp/mma-state-cont --continue "task2" 2>&1); rc=$?
check "continue exit" 0 "$rc"
echo "$out" | grep -q "resumed from" && echo "PASS continue resumed" || { echo "FAIL continue resumed"; echo "$out"; FAIL=1; }
JC=$(ls /tmp/mma-state-cont/sessions/*/journal.jsonl 2>/dev/null)
n_run=$(grep -c '"ev":"run"' $JC)
check "continue two runs" 2 "$n_run"

# 16. --temperature reaches the request body
run_mode normal ./max --repo . --temperature 0.7 "task" >/dev/null 2>&1
grep -q "STUB temp: 0.7" /tmp/stub_normal.log && echo "PASS temperature" || { echo "FAIL temperature"; cat /tmp/stub_normal.log; FAIL=1; }

# 17. --resume FILE: replays a copied journal; missing file exits 64
rm -rf /tmp/mma-state-res
run_mode normal ./max --repo . --state-dir /tmp/mma-state-res "task" >/dev/null 2>&1
cp /tmp/mma-state-res/sessions/*/journal.jsonl /tmp/mma-res.jsonl
out=$(run_mode normal ./max --repo . --resume /tmp/mma-res.jsonl "task2" 2>&1); rc=$?
check "resume exit" 0 "$rc"
echo "$out" | grep -q "resumed from" && echo "PASS resume" || { echo "FAIL resume"; echo "$out"; FAIL=1; }
out=$(run_mode normal ./max --repo . --resume /tmp/mma-missing.jsonl "task" 2>&1); rc=$?
check "resume missing exits 64" 64 "$rc"

# 17. REPL !cmd: runs locally, no model request
out=$(printf '!echo PASSTHRU\n/quit\n' | run_mode normal ./max --repo . 2>/dev/null)
echo "$out" | grep -q "PASSTHRU" && echo "PASS bang ran" || { echo "FAIL bang ran"; FAIL=1; }
[ ! -s /tmp/stub_normal.log ] && echo "PASS bang no request" || { echo "FAIL bang made request"; cat /tmp/stub_normal.log; FAIL=1; }

# 18. AGENTS.md auto-loads into the system prompt; --bare does not
rm -rf /tmp/mma-agents-repo
mkdir -p /tmp/mma-agents-repo && echo "RULE: always eat oranges" > /tmp/mma-agents-repo/AGENTS.md
run_mode normal ./max --repo /tmp/mma-agents-repo "task" >/dev/null 2>&1
grep -q "eat oranges" /tmp/stub_normal.log && echo "PASS agents.md loaded" || { echo "FAIL agents.md loaded"; cat /tmp/stub_normal.log; FAIL=1; }
rm -f /tmp/stub_normal.log
run_mode normal ./max --repo /tmp/mma-agents-repo --bare "task" >/dev/null 2>&1
grep -q "eat oranges" /tmp/stub_normal.log && { echo "FAIL bare loaded agents.md"; FAIL=1; } || echo "PASS bare skips agents.md"

# 19. --bare writes no state
rm -rf /tmp/mma-state-bare
run_mode normal ./max --repo . --bare --state-dir /tmp/mma-state-bare "task" >/dev/null 2>&1
[ ! -e /tmp/mma-state-bare ] && echo "PASS bare no state" || { echo "FAIL bare wrote state"; FAIL=1; }

exit $FAIL
