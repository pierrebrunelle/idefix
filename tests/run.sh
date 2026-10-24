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
# post-exec the cmdline is "sleep 37"; match it, not the wrapper text
pgrep -f "sleep 37" >/dev/null && { echo "FAIL orphan survived"; FAIL=1; } || echo "PASS no orphan"

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

# 13. loop: same command every turn -> loop_warning, then doom stop at 5
find "$MAX_STATE_DIR" -name journal.jsonl -delete 2>/dev/null
out=$(run_mode loop ./max --repo . --max-requests 6 "task" 2>/dev/null); rc=$?
check "loop exit" 2 "$rc"
grep -q "loop_warning" /tmp/stub_loop.log && echo "PASS loop warning" || { echo "FAIL loop warning"; cat /tmp/stub_loop.log; FAIL=1; }
grep -q '"stop":true' "$MAX_STATE_DIR"/sessions/*/journal.jsonl 2>/dev/null && echo "PASS loop doom stop" || { echo "FAIL loop doom stop"; FAIL=1; }

# 13b. wall deadline stops a runaway loop and clamps command timeout
start=$(python3 -c 'import time;print(time.time())')
out=$(run_mode loop ./max --repo . --max-seconds 1 --no-loop-guard "task" 2>/dev/null); rc=$?
elapsed=$(python3 -c "import time;print(int(time.time()-$start))")
check "deadline exit" 2 "$rc"
check "deadline fast" 1 "$([ "$elapsed" -le 6 ] && echo 1 || echo 0)"
start=$(python3 -c 'import time;print(time.time())')
out=$(run_mode sleep ./max --repo . --max-seconds 1 --max-command-seconds 30 "task" 2>/dev/null)
elapsed=$(python3 -c "import time;print(int(time.time()-$start))")
check "deadline clamp" 1 "$([ "$elapsed" -le 6 ] && echo 1 || echo 0)"

# 13c. sednoop: exit-0 write-shaped command with no file change -> warning
out=$(run_mode sednoop ./max --repo . "task" 2>/dev/null); rc=$?
check "sednoop exit" 0 "$rc"
grep -q "may not have applied" /tmp/stub_sednoop.log && echo "PASS noop warning" || { echo "FAIL noop warning"; cat /tmp/stub_sednoop.log; FAIL=1; }

# 13d. sandbox (macOS seatbelt): writes outside repo denied, inside allowed
if command -v sandbox-exec >/dev/null 2>&1; then
    rm -f .sbx-ok "$HOME/.sbx-denied-xyz"
    out=$(run_mode sbx ./max --repo . --sandbox "task" 2>/dev/null); rc=$?
    check "sbx exit" 0 "$rc"
    [ -f .sbx-ok ] && echo "PASS sbx repo write" || { echo "FAIL sbx repo write"; FAIL=1; }
    [ ! -f "$HOME/.sbx-denied-xyz" ] && echo "PASS sbx home denied" || { echo "FAIL sbx home denied"; FAIL=1; }
    grep -qi "permitted\|denied\|deny" /tmp/stub_sbx.log && echo "PASS sbx deny msg" || { echo "FAIL sbx deny msg"; cat /tmp/stub_sbx.log; FAIL=1; }
    rm -f .sbx-ok
else
    echo "SKIP sandbox (no sandbox-exec)"
fi

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

# 29. binout: invalid UTF-8 in tool output is sanitized, request still parses
out=$(run_mode binout ./max --repo . "task" 2>/dev/null); rc=$?
check "binout exit" 0 "$rc"
check "binout answer" "Done." "$out"
grep -q "STUB tool json ok: True" /tmp/stub_binout.log && echo "PASS binout json" || { echo "FAIL binout json"; cat /tmp/stub_binout.log; FAIL=1; }
grep -q "$(printf '\357\277\275')" /tmp/stub_binout.log && echo "PASS binout sanitized" || { echo "FAIL binout sanitized"; FAIL=1; }

# 30. unknown flags exit 64; -- gates a task starting with -
out=$(./max --repo . --retriess 2>&1); rc=$?
check "unknown flag exit" 64 "$rc"
echo "$out" | grep -q "unknown flag" && echo "PASS unknown flag msg" || { echo "FAIL unknown flag msg: $out"; FAIL=1; }
out=$(run_mode normal ./max --repo . -- "-weird-task" 2>/dev/null); rc=$?
check "dashdash task exit" 0 "$rc"
check "dashdash answer" "Done." "$out"

# 31. --max-requests counts retries: cap 1 + flaky 500 -> no retry, exit 3
out=$(run_mode flaky ./max --repo . --max-requests 1 "task" 2>/dev/null); rc=$?
check "cap counts retries exit" 3 "$rc"

# 32. --bare keeps v1 wire behavior: context 400 -> exit 3, never compacts
out=$(run_mode ctxerr ./max --repo . --bare "task" 2>/dev/null); rc=$?
check "bare ctxerr exit" 3 "$rc"
grep -q "cleared; re-run" /tmp/stub_ctxerr.log && { echo "FAIL bare compacted"; FAIL=1; } || echo "PASS bare no compact"

# 33. --bare rejects session/notify flags instead of silently dropping them
./max --repo . --bare --continue "task" >/dev/null 2>&1; check "bare continue exit" 64 "$?"
./max --repo . --bare --resume /tmp/max-res.jsonl "task" >/dev/null 2>&1; check "bare resume exit" 64 "$?"
./max --repo . --bare --notify true "task" >/dev/null 2>&1; check "bare notify exit" 64 "$?"

# 34. --repo must be a directory; unusable state dir warns but runs
out=$(./max --repo ./README.md "task" 2>&1); rc=$?
check "repo file exit" 64 "$rc"
echo "$out" | grep -q "not a directory" && echo "PASS repo file msg" || { echo "FAIL repo file msg: $out"; FAIL=1; }
touch /tmp/max-statefile
out=$(run_mode normal ./max --repo . --state-dir /tmp/max-statefile "task" 2>&1 >/dev/null); rc=$?
check "state-dir fail runs" 0 "$rc"
echo "$out" | grep -q "journal/status off" && echo "PASS state-dir fail note" || { echo "FAIL state-dir fail note: $out"; FAIL=1; }
rm -f /tmp/max-statefile

# 35. chunked response has no Content-Length: --max-http-bytes still caps it
out=$(run_mode chunked ./max --repo . --max-http-bytes 1024 --retries 0 "task" 2>&1); rc=$?
check "chunked cap exit" 3 "$rc"
echo "$out" | grep -q "exceeds --max-http-bytes" && echo "PASS chunked cap msg" || { echo "FAIL chunked cap msg: $out"; FAIL=1; }

# 36. env scrub: model commands see no credential-named vars, others pass through
rm -f /tmp/stub_envdump.log
out=$(run_mode envdump env MAX_API_KEY=sekrit-xy KEEP_ME_PLAIN=visible ./max --repo . "task" 2>/dev/null); rc=$?
check "envdump exit" 0 "$rc"
grep -q "KEEP_ME_PLAIN=visible" /tmp/stub_envdump.log && echo "PASS env plain kept" || { echo "FAIL env plain kept"; cat /tmp/stub_envdump.log; FAIL=1; }
grep -q "sekrit-xy\|MAX_API_KEY" /tmp/stub_envdump.log && { echo "FAIL env leaked credential"; FAIL=1; } || echo "PASS env scrubbed"

# 37. changed_files: tool result lists files the command actually changed
rm -f /tmp/max_cf.json /tmp/max_cf_bare.json cf-out.txt
run_mode cfdiff ./max --repo . --transcript /tmp/max_cf.json "task" >/dev/null 2>&1
python3 -c "import json;d=json.load(open('/tmp/max_cf.json'));t=[m for m in d if m['role']=='tool'];assert 'cf-out.txt' in t[0]['content'],t[0]" && echo "PASS changed_files reported" || { echo "FAIL changed_files reported"; FAIL=1; }
run_mode cfdiff ./max --bare --repo . --transcript /tmp/max_cf_bare.json "task" >/dev/null 2>&1
python3 -c "import json;d=json.load(open('/tmp/max_cf_bare.json'));assert 'changed_files' not in json.dumps(d)" && echo "PASS bare omits changed_files" || { echo "FAIL bare omits changed_files"; FAIL=1; }
rm -f cf-out.txt

exit $FAIL
