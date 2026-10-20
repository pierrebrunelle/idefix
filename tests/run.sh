#!/bin/bash
# Trouble-path tests against the stub. Requires ./max built and MAX_MODEL set.
set -u
cd "$(dirname "$0")/.."
export MAX_BASE_URL="http://127.0.0.1:18923/v1"
export MAX_MODEL="${MAX_MODEL:-test-model}"
export MAX_STATE_DIR=/tmp/max-test-state   # keep tests out of real $HOME
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
rm -f /tmp/max_t.json
run_mode normal ./max --repo . --transcript /tmp/max_t.json "task" >/dev/null 2>&1
python3 -c "import json;d=json.load(open('/tmp/max_t.json'));assert [m['role'] for m in d]==['system','user','assistant','tool','assistant'],d" && echo "PASS transcript" || { echo "FAIL transcript"; FAIL=1; }

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
rm -rf /tmp/max-state-flaky
out=$(run_mode flaky ./max --repo . --state-dir /tmp/max-state-flaky "task" 2>/dev/null); rc=$?
check "flaky exit" 0 "$rc"
check "flaky answer" "Done." "$out"
grep -q '"ev":"retry"' /tmp/max-state-flaky/sessions/*/journal.jsonl && echo "PASS flaky journal" || { echo "FAIL flaky journal"; FAIL=1; }

# 11. bigusage: prompt_tokens over --compact-at -> next request carries cleared tool output
rm -rf /tmp/max-state-compact
out=$(run_mode bigusage ./max --repo . --compact-keep 0 --state-dir /tmp/max-state-compact "task" 2>/dev/null); rc=$?
check "bigusage exit" 0 "$rc"
check "bigusage answer" "Done." "$out"
grep -q "cleared; re-run" /tmp/stub_bigusage.log && echo "PASS bigusage cleared" || { echo "FAIL bigusage cleared"; cat /tmp/stub_bigusage.log; FAIL=1; }
grep -q '"ev":"compact"' /tmp/max-state-compact/sessions/*/journal.jsonl && echo "PASS bigusage journal" || { echo "FAIL bigusage journal"; FAIL=1; }

# 12. ctxerr: 400 context-length -> compact + retry -> Done
rm -rf /tmp/max-state-ctx
out=$(run_mode ctxerr ./max --repo . --compact-keep 0 --state-dir /tmp/max-state-ctx "task" 2>/dev/null); rc=$?
check "ctxerr exit" 0 "$rc"
check "ctxerr answer" "Done." "$out"
grep -q "cleared; re-run" /tmp/stub_ctxerr.log && echo "PASS ctxerr cleared" || { echo "FAIL ctxerr cleared"; cat /tmp/stub_ctxerr.log; FAIL=1; }

# 12b. ctxbig: capitalized context error also triggers compaction
rm -rf /tmp/max-state-ctx2
out=$(run_mode ctxbig ./max --repo . --compact-keep 0 --state-dir /tmp/max-state-ctx2 "task" 2>/dev/null); rc=$?
check "ctxbig exit" 0 "$rc"
check "ctxbig answer" "Done." "$out"
grep -q "cleared; re-run" /tmp/stub_ctxbig.log && echo "PASS ctxbig cleared" || { echo "FAIL ctxbig cleared"; cat /tmp/stub_ctxbig.log; FAIL=1; }

# 13. loop: same command every turn -> loop_warning in tool result
out=$(run_mode loop ./max --repo . --max-requests 6 "task" 2>/dev/null); rc=$?
check "loop exit" 2 "$rc"
grep -q "loop_warning" /tmp/stub_loop.log && echo "PASS loop warning" || { echo "FAIL loop warning"; cat /tmp/stub_loop.log; FAIL=1; }

# 14. status file + journal events for a normal run
rm -rf /tmp/max-state-obs
run_mode normal ./max --repo . --state-dir /tmp/max-state-obs "task" >/dev/null 2>&1
ls /tmp/max-state-obs/sessions/*/status >/dev/null 2>&1 && echo "PASS status file" || { echo "FAIL status file"; FAIL=1; }
J=$(ls /tmp/max-state-obs/sessions/*/journal.jsonl 2>/dev/null)
grep -q '"ev":"run"' $J && grep -q '"ev":"done"' $J && echo "PASS journal events" || { echo "FAIL journal events"; cat $J 2>/dev/null; FAIL=1; }

# 15. --continue: resumes this repo's journal
rm -rf /tmp/max-state-cont
run_mode normal ./max --repo . --state-dir /tmp/max-state-cont "task" >/dev/null 2>&1
out=$(run_mode normal ./max --repo . --state-dir /tmp/max-state-cont --continue "task2" 2>&1); rc=$?
check "continue exit" 0 "$rc"
echo "$out" | grep -q "resumed from" && echo "PASS continue resumed" || { echo "FAIL continue resumed"; echo "$out"; FAIL=1; }
JC=$(ls /tmp/max-state-cont/sessions/*/journal.jsonl 2>/dev/null)
n_run=$(grep -c '"ev":"run"' $JC)
check "continue two runs" 2 "$n_run"

# 16. --temperature reaches the request body
run_mode normal ./max --repo . --temperature 0.7 "task" >/dev/null 2>&1
grep -q "STUB temp: 0.7" /tmp/stub_normal.log && echo "PASS temperature" || { echo "FAIL temperature"; cat /tmp/stub_normal.log; FAIL=1; }

# 17. --resume FILE: replays a copied journal; missing file exits 64
rm -rf /tmp/max-state-res
run_mode normal ./max --repo . --state-dir /tmp/max-state-res "task" >/dev/null 2>&1
cp /tmp/max-state-res/sessions/*/journal.jsonl /tmp/max-res.jsonl
out=$(run_mode normal ./max --repo . --resume /tmp/max-res.jsonl "task2" 2>&1); rc=$?
check "resume exit" 0 "$rc"
echo "$out" | grep -q "resumed from" && echo "PASS resume" || { echo "FAIL resume"; echo "$out"; FAIL=1; }
out=$(run_mode normal ./max --repo . --resume /tmp/max-missing.jsonl "task" 2>&1); rc=$?
check "resume missing exits 64" 64 "$rc"

# 18. REPL !cmd: runs locally, no model request; bare "!" warns, still no request
out=$(printf '!echo PASSTHRU\n/quit\n' | run_mode normal ./max --repo . 2>/dev/null)
echo "$out" | grep -q "PASSTHRU" && echo "PASS bang ran" || { echo "FAIL bang ran"; FAIL=1; }
[ ! -s /tmp/stub_normal.log ] && echo "PASS bang no request" || { echo "FAIL bang made request"; cat /tmp/stub_normal.log; FAIL=1; }
out=$(printf '!\n/quit\n' | run_mode normal ./max --repo . 2>&1)
echo "$out" | grep -q "empty command" && echo "PASS bare bang warns" || { echo "FAIL bare bang warns"; echo "$out"; FAIL=1; }
[ ! -s /tmp/stub_normal.log ] && echo "PASS bare bang no request" || { echo "FAIL bare bang made request"; cat /tmp/stub_normal.log; FAIL=1; }

# 19. AGENTS.md auto-loads into the system prompt; --bare does not
rm -rf /tmp/max-agents-repo
mkdir -p /tmp/max-agents-repo && echo "RULE: always eat oranges" > /tmp/max-agents-repo/AGENTS.md
run_mode normal ./max --repo /tmp/max-agents-repo "task" >/dev/null 2>&1
grep -q "eat oranges" /tmp/stub_normal.log && echo "PASS agents.md loaded" || { echo "FAIL agents.md loaded"; cat /tmp/stub_normal.log; FAIL=1; }
rm -f /tmp/stub_normal.log
run_mode normal ./max --repo /tmp/max-agents-repo --bare "task" >/dev/null 2>&1
grep -q "eat oranges" /tmp/stub_normal.log && { echo "FAIL bare loaded agents.md"; FAIL=1; } || echo "PASS bare skips agents.md"

# 20. --bare writes no state
rm -rf /tmp/max-state-bare
run_mode normal ./max --repo . --bare --state-dir /tmp/max-state-bare "task" >/dev/null 2>&1
[ ! -e /tmp/max-state-bare ] && echo "PASS bare no state" || { echo "FAIL bare wrote state"; FAIL=1; }

# 21. UTF-8 reaches the wire unmodified (json_quote pass-through)
run_mode normal ./max --repo . --bare "café" >/dev/null 2>&1
grep -q "STUB user: café" /tmp/stub_normal.log && echo "PASS utf8" || { echo "FAIL utf8"; grep "STUB user" /tmp/stub_normal.log; FAIL=1; }

# 22. chatty command still hits --max-command-seconds
printf '!yes\n' | ./max --repo . --max-command-seconds 1 >/dev/null 2>&1 &
pid=$!; sleep 4
if kill -0 "$pid" 2>/dev/null; then echo "FAIL chatty timeout"; kill "$pid" 2>/dev/null; FAIL=1; else echo "PASS chatty timeout"; fi
wait "$pid" 2>/dev/null

# 23. /reset survives --continue: pre-reset messages are not replayed
rm -rf /tmp/max-state-reset
printf 'first-one\n/reset\nsecond-two\n/quit\n' | run_mode normal ./max --repo . --state-dir /tmp/max-state-reset >/dev/null 2>&1
grep -q '"ev":"reset"' /tmp/max-state-reset/sessions/*/journal.jsonl && echo "PASS reset journaled" || { echo "FAIL reset journaled"; FAIL=1; }
run_mode normal ./max --repo . --state-dir /tmp/max-state-reset --continue "third" >/dev/null 2>&1
grep "STUB users" /tmp/stub_normal.log | tail -1 | grep -q "first-one" && { echo "FAIL reset replay"; FAIL=1; } || echo "PASS reset replay"

# 24. numeric flag validation: missing/garbage/negative values exit 64 cleanly
out=$(./max --repo . --max-requests 2>&1); rc=$?
check "missing value exit" 64 "$rc"
echo "$out" | grep -q "missing value" && echo "PASS missing value msg" || { echo "FAIL missing value msg: $out"; FAIL=1; }
./max --repo . --max-requests abc "task" >/dev/null 2>&1; check "bad integer exit" 64 "$?"
./max --repo . --max-output-bytes -1 "task" >/dev/null 2>&1; check "negative value exit" 64 "$?"
./max --repo . --temperature abc "task" >/dev/null 2>&1; check "bad float exit" 64 "$?"
./max --repo . one two >/dev/null 2>&1; check "extra positional exit" 64 "$?"

# 25. signal-killed command reports 128+signo, not 0
out=$(printf '!kill -9 $$\n/quit\n' | ./max --repo . --state-dir /tmp/max-state-sig 2>&1)
echo "$out" | grep -q "!exit 137" && echo "PASS signal exit 137" || { echo "FAIL signal exit"; echo "$out"; FAIL=1; }

# 26. model tool name with a quote can't corrupt the wire JSON
out=$(run_mode weirdname ./max --repo . "task" 2>/dev/null); rc=$?
check "weirdname exit" 0 "$rc"
check "weirdname answer" "Done." "$out"
grep -q "STUB tool json ok: True" /tmp/stub_weirdname.log && echo "PASS weirdname json" || { echo "FAIL weirdname json"; cat /tmp/stub_weirdname.log; FAIL=1; }
grep -q '"name":"weird' /tmp/stub_weirdname.log && echo "PASS weirdname name" || { echo "FAIL weirdname name"; FAIL=1; }

# 27. --max-http-bytes caps the response body -> transport error -> exit 3
out=$(run_mode normal ./max --repo . --max-http-bytes 10 --retries 0 "task" 2>/dev/null); rc=$?
check "http cap exit" 3 "$rc"

# 28. session dir is private
rm -rf /tmp/max-state-perms
run_mode normal ./max --repo . --state-dir /tmp/max-state-perms "task" >/dev/null 2>&1
check "session dir perms" "rwx------" "$(ls -ld /tmp/max-state-perms/sessions/*/ | cut -c2-10)"

exit $FAIL
