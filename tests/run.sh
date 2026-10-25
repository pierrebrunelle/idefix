#!/bin/bash
# Trouble-path tests against the stub. Requires ./idefix built and IDEFIX_MODEL set.
set -u
cd "$(dirname "$0")/.."
export IDEFIX_BASE_URL="http://127.0.0.1:18923/v1"
export IDEFIX_MODEL="${IDEFIX_MODEL:-test-model}"
export IDEFIX_STATE_DIR=/tmp/idefix-test-state   # keep tests out of real $HOME
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
out=$(run_mode normal ./idefix --repo . "task" 2>/dev/null); rc=$?
check "normal exit" 0 "$rc"
check "normal answer" "Done." "$out"

# 2. badargs: invalid arguments JSON -> error result, no exec, then final, exit 0
out=$(run_mode badargs ./idefix --repo . "task" 2>/dev/null); rc=$?
check "badargs exit" 0 "$rc"
grep -q "not valid JSON" /tmp/stub_badargs.log && echo "PASS badargs error result" || { echo "FAIL badargs error result"; FAIL=1; }

# 3. malformed: invalid envelope -> exit 3
out=$(run_mode malformed ./idefix --repo . "task" 2>/dev/null); rc=$?
check "malformed exit" 3 "$rc"

# 4. batch: two calls -> two results in order
out=$(run_mode batch ./idefix --repo . "task" 2>/dev/null); rc=$?
check "batch exit" 0 "$rc"
check "batch answer" "Done." "$out"
n=$(grep -c "tool_call_id" /tmp/stub_batch.log || true)
grep -q "call_a.*call_b\|expected=\['call_a', 'call_b'\]" /tmp/stub_batch.log && echo "PASS batch pairing" || { echo "FAIL batch pairing"; cat /tmp/stub_batch.log; FAIL=1; }

# 5. sleep: timeout kills process group -> tool result exit_code 124, then final
start=$(python3 -c 'import time;print(time.time())')
out=$(run_mode sleep ./idefix --repo . --max-command-seconds 1 "task" 2>/dev/null); rc=$?
elapsed=$(python3 -c "import time;print(int(time.time()-$start))")
check "sleep exit" 0 "$rc"
check "sleep killed fast" 1 "$([ "$elapsed" -le 6 ] && echo 1 || echo 0)"
grep -q "exit_code..124" /tmp/stub_sleep.log && echo "PASS sleep 124" || { echo "FAIL sleep 124"; cat /tmp/stub_sleep.log; FAIL=1; }
# post-exec the cmdline is "sleep 37"; match it, not the wrapper text
pgrep -f "sleep 37" >/dev/null && { echo "FAIL orphan survived"; FAIL=1; } || echo "PASS no orphan"

# 6. budget: max-requests 1 -> exit 2
out=$(run_mode normal ./idefix --repo . --max-requests 1 "task" 2>/dev/null); rc=$?
check "budget exit" 2 "$rc"

# 7. transcript written
rm -f /tmp/idefix_t.json
run_mode normal ./idefix --repo . --transcript /tmp/idefix_t.json "task" >/dev/null 2>&1
python3 -c "import json;d=json.load(open('/tmp/idefix_t.json'));assert [m['role'] for m in d]==['system','user','assistant','tool','assistant'],d" && echo "PASS transcript" || { echo "FAIL transcript"; FAIL=1; }

# 8. --help exits cleanly
out=$(./idefix --help 2>&1); rc=$?
check "help rc" 0 "$rc"
echo "$out" | grep -q "usage: idefix" && echo "PASS help text" || { echo "FAIL help text"; FAIL=1; }

# 9. REPL: piped lines share one session; /quit exits clean; EOF-clean exit
out=$(printf 'one\ntwo\n/quit\n' | run_mode normal ./idefix --repo . 2>/dev/null); rc=$?
check "repl exit" 0 "$rc"
check "repl two turns" $'Done.\nDone.' "$out"
out=$(./idefix </dev/null 2>&1); rc=$?
check "repl EOF exit" 0 "$rc"

# 10. flaky: server 500 once -> retry succeeds
rm -rf /tmp/idefix-state-flaky
out=$(run_mode flaky ./idefix --repo . --state-dir /tmp/idefix-state-flaky "task" 2>/dev/null); rc=$?
check "flaky exit" 0 "$rc"
check "flaky answer" "Done." "$out"
grep -q '"ev":"retry"' /tmp/idefix-state-flaky/sessions/*/journal.jsonl && echo "PASS flaky journal" || { echo "FAIL flaky journal"; FAIL=1; }

# 11. bigusage: prompt_tokens over --compact-at -> next request carries cleared tool output
rm -rf /tmp/idefix-state-compact
out=$(run_mode bigusage ./idefix --repo . --compact-keep 0 --state-dir /tmp/idefix-state-compact "task" 2>/dev/null); rc=$?
check "bigusage exit" 0 "$rc"
check "bigusage answer" "Done." "$out"
grep -q "cleared; re-run" /tmp/stub_bigusage.log && echo "PASS bigusage cleared" || { echo "FAIL bigusage cleared"; cat /tmp/stub_bigusage.log; FAIL=1; }
grep -q '"ev":"compact"' /tmp/idefix-state-compact/sessions/*/journal.jsonl && echo "PASS bigusage journal" || { echo "FAIL bigusage journal"; FAIL=1; }

# 12. ctxerr: 400 context-length -> compact + retry -> Done
rm -rf /tmp/idefix-state-ctx
out=$(run_mode ctxerr ./idefix --repo . --compact-keep 0 --state-dir /tmp/idefix-state-ctx "task" 2>/dev/null); rc=$?
check "ctxerr exit" 0 "$rc"
check "ctxerr answer" "Done." "$out"
grep -q "cleared; re-run" /tmp/stub_ctxerr.log && echo "PASS ctxerr cleared" || { echo "FAIL ctxerr cleared"; cat /tmp/stub_ctxerr.log; FAIL=1; }

# 12b. ctxbig: capitalized context error also triggers compaction
rm -rf /tmp/idefix-state-ctx2
out=$(run_mode ctxbig ./idefix --repo . --compact-keep 0 --state-dir /tmp/idefix-state-ctx2 "task" 2>/dev/null); rc=$?
check "ctxbig exit" 0 "$rc"
check "ctxbig answer" "Done." "$out"
grep -q "cleared; re-run" /tmp/stub_ctxbig.log && echo "PASS ctxbig cleared" || { echo "FAIL ctxbig cleared"; cat /tmp/stub_ctxbig.log; FAIL=1; }

# 13. loop: same command every turn -> loop_warning, then doom stop at 5
find "$IDEFIX_STATE_DIR" -name journal.jsonl -delete 2>/dev/null
out=$(run_mode loop ./idefix --repo . --max-requests 6 "task" 2>/dev/null); rc=$?
check "loop exit" 2 "$rc"
grep -q "loop_warning" /tmp/stub_loop.log && echo "PASS loop warning" || { echo "FAIL loop warning"; cat /tmp/stub_loop.log; FAIL=1; }
grep -q '"stop":true' "$IDEFIX_STATE_DIR"/sessions/*/journal.jsonl 2>/dev/null && echo "PASS loop doom stop" || { echo "FAIL loop doom stop"; FAIL=1; }

# 13doomwarn. --doom-warn: 5th repeat returns a warn result and loops once more;
# the repeat after that still stops with exit 2
out=$(run_mode loop ./idefix --repo . --max-requests 8 --doom-warn "task" 2>/dev/null); rc=$?
check "doomwarn exit" 2 "$rc"
grep -q "do not re-issue" /tmp/stub_loop.log && echo "PASS doom warn result" || { echo "FAIL doom warn result"; cat /tmp/stub_loop.log; FAIL=1; }
find "$IDEFIX_STATE_DIR" -name journal.jsonl -exec grep -l '"warn":true' {} \; 2>/dev/null | grep -q . && echo "PASS doom warn journal" || { echo "FAIL doom warn journal"; FAIL=1; }

# 13gate. --done-gate: write-shaped last command then text reply -> one
# verification nudge (2 pairing requests vs 1 without the flag)
out=$(run_mode writefinal ./idefix --repo . --done-gate "task" 2>/dev/null); rc=$?
check "gate exit" 0 "$rc"
check "gate answer" "Done." "$out"
check "gate re-asked" 2 "$(grep -c 'STUB pairing' /tmp/stub_writefinal.log)"
rm -f gate-wrote.txt

out=$(run_mode writefinal ./idefix --repo . "task" 2>/dev/null); rc=$?
check "nogate exit" 0 "$rc"
check "nogate no re-ask" 1 "$(grep -c 'STUB pairing' /tmp/stub_writefinal.log)"
rm -f gate-wrote.txt

# 13gate2. --done-gate2: a second write-then-done attempt earns an evidence
# nudge (4 pairing requests); --done-gate still stops at one nudge; --bare
# keeps the gate off entirely
out=$(run_mode writefinal2 ./idefix --repo . --done-gate2 "task" 2>/dev/null); rc=$?
check "gate2 exit" 0 "$rc"
check "gate2 answer" "Done." "$out"
check "gate2 re-asked twice" 4 "$(grep -c 'STUB pairing' /tmp/stub_writefinal2.log)"
grep -qF 'Commands since your last write: `echo more >> gate2-wrote.txt` (exit 0)' /tmp/stub_writefinal2.log && echo "PASS gate2 evidence echo" || { echo "FAIL gate2 evidence echo"; cat /tmp/stub_writefinal2.log; FAIL=1; }
rm -f gate2-wrote.txt

out=$(run_mode writefinal2 ./idefix --repo . --done-gate "task" 2>/dev/null); rc=$?
check "gate1-on-writefinal2 exit" 0 "$rc"
check "gate1 still one nudge" 3 "$(grep -c 'STUB pairing' /tmp/stub_writefinal2.log)"
grep -q "Commands since your last write" /tmp/stub_writefinal2.log && { echo "FAIL gate1 fired strike2"; FAIL=1; } || echo "PASS gate1 no strike2"
rm -f gate2-wrote.txt

out=$(run_mode writefinal2 ./idefix --repo . --bare --done-gate2 "task" 2>/dev/null); rc=$?
check "gate2 bare exit" 0 "$rc"
check "gate2 bare no nudge" 1 "$(grep -c 'STUB pairing' /tmp/stub_writefinal2.log)"
rm -f gate2-wrote.txt

# 13digest. --loop-digest: identical outcomes from varying commands get a
# result-kind loop_warning; off by default
out=$(run_mode resultloop ./idefix --repo . --max-requests 8 --loop-digest "task" 2>/dev/null); rc=$?
check "digest exit" 2 "$rc"
grep -q "same outcome" /tmp/stub_resultloop.log && echo "PASS digest warning" || { echo "FAIL digest warning"; cat /tmp/stub_resultloop.log; FAIL=1; }
find "$IDEFIX_STATE_DIR" -name journal.jsonl -exec grep -l '"kind":"result"' {} \; 2>/dev/null | grep -q . && echo "PASS digest journal" || { echo "FAIL digest journal"; FAIL=1; }

out=$(run_mode resultloop ./idefix --repo . --max-requests 8 "task" 2>/dev/null); rc=$?
check "digest off exit" 2 "$rc"
grep -q "same outcome" /tmp/stub_resultloop.log && { echo "FAIL digest off"; FAIL=1; } || echo "PASS digest off"

# 13reason. thinking-mode servers answer in `reasoning` with empty content;
# a stray orphan </think> should be stripped too
out=$(run_mode reasoning ./idefix --repo . "task" 2>/dev/null); rc=$?
check "reasoning exit" 0 "$rc"
check "reasoning fallback" "Reasoned answer." "$out"
out=$(run_mode thinkleak ./idefix --repo . "task" 2>/dev/null); rc=$?
check "thinkleak exit" 0 "$rc"
check "thinkleak stripped" "Leaked answer." "$out"

# 13b. wall deadline stops a runaway loop and clamps command timeout
start=$(python3 -c 'import time;print(time.time())')
out=$(run_mode loop ./idefix --repo . --max-seconds 1 --no-loop-guard "task" 2>/dev/null); rc=$?
elapsed=$(python3 -c "import time;print(int(time.time()-$start))")
check "deadline exit" 2 "$rc"
check "deadline fast" 1 "$([ "$elapsed" -le 6 ] && echo 1 || echo 0)"
start=$(python3 -c 'import time;print(time.time())')
out=$(run_mode sleep ./idefix --repo . --max-seconds 1 --max-command-seconds 30 "task" 2>/dev/null)
elapsed=$(python3 -c "import time;print(int(time.time()-$start))")
check "deadline clamp" 1 "$([ "$elapsed" -le 6 ] && echo 1 || echo 0)"

# 13c. sednoop: exit-0 write-shaped command with no file change -> warning
out=$(run_mode sednoop ./idefix --repo . "task" 2>/dev/null); rc=$?
check "sednoop exit" 0 "$rc"
grep -q "may not have applied" /tmp/stub_sednoop.log && echo "PASS noop warning" || { echo "FAIL noop warning"; cat /tmp/stub_sednoop.log; FAIL=1; }

# 13d. medit: `idefix edit` reachable on scrubbed PATH, applies unique SEARCH block
out=$(run_mode medit ./idefix --repo . "task" 2>/dev/null); rc=$?
check "medit exit" 0 "$rc"
grep -q "block(s) applied" /tmp/stub_medit.log && grep -q "x = 9" /tmp/stub_medit.log && echo "PASS medit apply" || { echo "FAIL medit apply"; cat /tmp/stub_medit.log; FAIL=1; }
rm -f e.py

# 13e. ediff: changed file -> compact unified diff in tool result (non-bare)
out=$(run_mode ediff ./idefix --repo . "task" 2>/dev/null); rc=$?
check "ediff exit" 0 "$rc"
grep -q '"diff"' /tmp/stub_ediff.log && grep -q "+a" /tmp/stub_ediff.log && echo "PASS diff echo" || { echo "FAIL diff echo"; cat /tmp/stub_ediff.log; FAIL=1; }
rm -f d.txt

# 13f. redirnoop: 2>&1 is fd duplication, not a file write -> no warning
out=$(run_mode redirnoop ./idefix --repo . "task" 2>/dev/null); rc=$?
check "redirnoop exit" 0 "$rc"
grep -q "may not have applied" /tmp/stub_redirnoop.log && { echo "FAIL redir false warning"; cat /tmp/stub_redirnoop.log; FAIL=1; } || echo "PASS no redir warning"

# 13g. injname: model-created filename reaching the diff echo must not execute
rm -f pwned.txt 'x$(touch pwned.txt)'
out=$(run_mode injname ./idefix --repo . "task" 2>/dev/null); rc=$?
check "injname exit" 0 "$rc"
[ -f pwned.txt ] && { echo "FAIL filename injection"; FAIL=1; } || echo "PASS filename quoting"
rm -f 'x$(touch pwned.txt)'

# 13h. badmarkup: unparseable tool_call markup -> nudge + retry, then Done.
out=$(run_mode badmarkup ./idefix --repo . --max-requests 5 "task" 2>/dev/null); rc=$?
check "badmarkup exit" 0 "$rc"
check "badmarkup recovered" "Done." "$out"
grep -q "could not be parsed" /tmp/stub_badmarkup.log && echo "PASS badmarkup nudge" || { echo "FAIL badmarkup nudge"; cat /tmp/stub_badmarkup.log; FAIL=1; }

# 13i. markup: well-formed <tool_call> markup is rescued and executed
out=$(run_mode markup ./idefix --repo . "task" 2>/dev/null); rc=$?
check "markup exit" 0 "$rc"
grep -q "markup-ok" /tmp/stub_markup.log && echo "PASS markup rescued" || { echo "FAIL markup rescued"; cat /tmp/stub_markup.log; FAIL=1; }

# 13j. think: <think> block stripped from the final answer
out=$(run_mode think ./idefix --repo . "task" 2>/dev/null); rc=$?
check "think exit" 0 "$rc"
check "think final" "Done." "$out"

# 13k. flood: --max-output-bytes caps output and counts the discard
out=$(run_mode flood ./idefix --repo . --max-output-bytes 1000 "task" 2>/dev/null); rc=$?
check "flood exit" 0 "$rc"
grep -q '"discarded_bytes":[1-9]' /tmp/stub_flood.log && echo "PASS flood discarded" || { echo "FAIL flood discarded"; cat /tmp/stub_flood.log; FAIL=1; }

# 13l. many: tool_calls over the cap get a limit error, never run
out=$(run_mode many ./idefix --repo . --max-calls-per-response 3 "task" 2>/dev/null); rc=$?
check "many exit" 0 "$rc"
grep -q "call limit reached" /tmp/stub_many.log && echo "PASS call cap" || { echo "FAIL call cap"; cat /tmp/stub_many.log; FAIL=1; }

# 13m. stall: --max-seconds kills a stalled request
out=$(run_mode stall ./idefix --repo . --max-seconds 3 "task" 2>/dev/null); rc=$?
check "stall exit" 2 "$rc"

# 13n. REPL: --max-requests is per turn, not per session
out=$(printf 'a\nb\n/quit\n' | run_mode finalans ./idefix --repo . --max-requests 1 2>/dev/null); rc=$?
check "repl exit" 0 "$rc"
[ "$(echo "$out" | grep -c 'Done.')" = "2" ] && echo "PASS repl per-turn budget" || { echo "FAIL repl per-turn budget: $out"; FAIL=1; }

# 13o. idefix edit failure contract: loud rc1, file untouched
printf 'x = 1\n' > e.py
printf '<<<<<<< SEARCH\nnope\n=======\nx = 2\n>>>>>>> REPLACE\n' | ./idefix edit e.py >/dev/null 2>&1; rc=$?
check "edit nomatch exit" 1 "$rc"
grep -q "x = 1" e.py && ! grep -q "x = 2" e.py && echo "PASS edit nomatch unchanged" || { echo "FAIL edit nomatch"; FAIL=1; }
printf 'x = 1\n' > e.py
printf '<<<<<<< SEARCH\nx = 1\n=======\nx = (\n>>>>>>> REPLACE\n' | ./idefix edit e.py >/dev/null 2>&1; rc=$?
check "edit badpy exit" 1 "$rc"
grep -q "x = 1" e.py && echo "PASS edit badpy unchanged" || { echo "FAIL edit badpy"; FAIL=1; }
rm -f e.py __pycache__ -r

# 13p. --version and bare `idefix edit` (no FILE) exit clean, no server touched
out=$(./idefix --version); rc=$?
check "version exit" 0 "$rc"
echo "$out" | grep -q "^idefix 0" && echo "PASS version" || { echo "FAIL version: $out"; FAIL=1; }
./idefix edit </dev/null >/dev/null 2>&1; rc=$?
check "bare edit exit" 64 "$rc"

# 13q. detach: (cmd &) strays in the child pgroup die with the command
out=$(run_mode detach ./idefix --repo . "task" 2>/dev/null); rc=$?
check "detach exit" 0 "$rc"
sleep 1
! pgrep -f "sleep 29" >/dev/null && echo "PASS detach orphan killed" || { echo "FAIL detach orphan killed"; pgrep -fl "sleep 29"; pkill -f "sleep 29"; FAIL=1; }

# 13r. --max-prompt-tokens halts the run with exit 2
out=$(run_mode bigusage ./idefix --repo . --max-prompt-tokens 50 "task" 2>/dev/null); rc=$?
check "promptcap exit" 2 "$rc"

# 13s. --notify CMD runs when the run finishes
nf=/tmp/idefix-notify-$$
rm -f "$nf"
out=$(run_mode normal ./idefix --repo . --notify "touch $nf" "task" 2>/dev/null); rc=$?
check "notify exit" 0 "$rc"
[ -f "$nf" ] && echo "PASS notify ran" || { echo "FAIL notify ran"; FAIL=1; }
rm -f "$nf"

# 13t. mid-batch-cut journal: --resume drops unpaired assistant tool_calls
jf=/tmp/idefix-journal-cut-$$.jsonl
cat > "$jf" <<'JEOF'
{"ev":"run","ts":1}
{"ev":"msg","m":{"role":"user","content":"hi"}}
{"ev":"msg","m":{"role":"assistant","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo x\"}"}}]}}
JEOF
out=$(run_mode finalans ./idefix --repo . --resume "$jf" "task" 2>/dev/null); rc=$?
check "resumecut exit" 0 "$rc"
check "resumecut answer" "Done." "$out"
rm -f "$jf"

# 13u. misc one-liners: IDEFIX_MODEL required, nan temp, /exit alias
out=$(env -u IDEFIX_MODEL -u MAX_MODEL IDEFIX_BASE_URL=http://127.0.0.1:1/v1 ./idefix --repo . "task" 2>&1); rc=$?
check "modelreq exit" 64 "$rc"
IDEFIX_BASE_URL=http://127.0.0.1:1/v1 IDEFIX_MODEL=test ./idefix --repo . --temperature nan "task" >/dev/null 2>&1; rc=$?
check "nantemp exit" 64 "$rc"
out=$(printf 'a\n/exit\n' | run_mode finalans ./idefix --repo . 2>/dev/null); rc=$?
check "exitalias exit" 0 "$rc"
[ "$(echo "$out" | grep -c 'Done.')" = "1" ] && echo "PASS /exit alias" || { echo "FAIL /exit alias: $out"; FAIL=1; }

# 13v. with-max.sh: server already answering -> runs task, never serves
out=$(run_mode normal env IDEFIX_MODEL=test-model bash scripts/with-max.sh --repo . "task" 2>/dev/null); rc=$?
check "with-max exit" 0 "$rc"
check "with-max answer" "Done." "$out"

# 13w. legacy MAX_* env vars still work as fallbacks
out=$(run_mode normal env -u IDEFIX_MODEL MAX_MODEL=test-model bash scripts/with-max.sh --repo . "task" 2>/dev/null); rc=$?
check "legacy-env exit" 0 "$rc"
check "legacy-env answer" "Done." "$out"

# 13d. sandbox (macOS seatbelt): writes outside repo denied, inside allowed
if command -v sandbox-exec >/dev/null 2>&1; then
    rm -f .sbx-ok "$HOME/.sbx-denied-xyz"
    out=$(run_mode sbx ./idefix --repo . --sandbox "task" 2>/dev/null); rc=$?
    check "sbx exit" 0 "$rc"
    [ -f .sbx-ok ] && echo "PASS sbx repo write" || { echo "FAIL sbx repo write"; FAIL=1; }
    [ ! -f "$HOME/.sbx-denied-xyz" ] && echo "PASS sbx home denied" || { echo "FAIL sbx home denied"; FAIL=1; }
    grep -qi "permitted\|denied\|deny" /tmp/stub_sbx.log && echo "PASS sbx deny msg" || { echo "FAIL sbx deny msg"; cat /tmp/stub_sbx.log; FAIL=1; }
    rm -f .sbx-ok
else
    echo "SKIP sandbox (no sandbox-exec)"
fi

# 14. status file + journal events for a normal run
rm -rf /tmp/idefix-state-obs
run_mode normal ./idefix --repo . --state-dir /tmp/idefix-state-obs "task" >/dev/null 2>&1
ls /tmp/idefix-state-obs/sessions/*/status >/dev/null 2>&1 && echo "PASS status file" || { echo "FAIL status file"; FAIL=1; }
J=$(ls /tmp/idefix-state-obs/sessions/*/journal.jsonl 2>/dev/null)
grep -q '"ev":"run"' $J && grep -q '"ev":"done"' $J && echo "PASS journal events" || { echo "FAIL journal events"; cat $J 2>/dev/null; FAIL=1; }

# 15. --continue: resumes this repo's journal
rm -rf /tmp/idefix-state-cont
run_mode normal ./idefix --repo . --state-dir /tmp/idefix-state-cont "task" >/dev/null 2>&1
out=$(run_mode normal ./idefix --repo . --state-dir /tmp/idefix-state-cont --continue "task2" 2>&1); rc=$?
check "continue exit" 0 "$rc"
echo "$out" | grep -q "resumed from" && echo "PASS continue resumed" || { echo "FAIL continue resumed"; echo "$out"; FAIL=1; }
JC=$(ls /tmp/idefix-state-cont/sessions/*/journal.jsonl 2>/dev/null)
n_run=$(grep -c '"ev":"run"' $JC)
check "continue two runs" 2 "$n_run"

# 16. --temperature reaches the request body
run_mode normal ./idefix --repo . --temperature 0.7 "task" >/dev/null 2>&1
grep -q "STUB temp: 0.7" /tmp/stub_normal.log && echo "PASS temperature" || { echo "FAIL temperature"; cat /tmp/stub_normal.log; FAIL=1; }

# 17. --resume FILE: replays a copied journal; missing file exits 64
rm -rf /tmp/idefix-state-res
run_mode normal ./idefix --repo . --state-dir /tmp/idefix-state-res "task" >/dev/null 2>&1
cp /tmp/idefix-state-res/sessions/*/journal.jsonl /tmp/idefix-res.jsonl
out=$(run_mode normal ./idefix --repo . --resume /tmp/idefix-res.jsonl "task2" 2>&1); rc=$?
check "resume exit" 0 "$rc"
echo "$out" | grep -q "resumed from" && echo "PASS resume" || { echo "FAIL resume"; echo "$out"; FAIL=1; }
out=$(run_mode normal ./idefix --repo . --resume /tmp/idefix-missing.jsonl "task" 2>&1); rc=$?
check "resume missing exits 64" 64 "$rc"

# 18. REPL !cmd: runs locally, no model request; bare "!" warns, still no request
out=$(printf '!echo PASSTHRU\n/quit\n' | run_mode normal ./idefix --repo . 2>/dev/null)
echo "$out" | grep -q "PASSTHRU" && echo "PASS bang ran" || { echo "FAIL bang ran"; FAIL=1; }
[ ! -s /tmp/stub_normal.log ] && echo "PASS bang no request" || { echo "FAIL bang made request"; cat /tmp/stub_normal.log; FAIL=1; }
out=$(printf '!\n/quit\n' | run_mode normal ./idefix --repo . 2>&1)
echo "$out" | grep -q "empty command" && echo "PASS bare bang warns" || { echo "FAIL bare bang warns"; echo "$out"; FAIL=1; }
[ ! -s /tmp/stub_normal.log ] && echo "PASS bare bang no request" || { echo "FAIL bare bang made request"; cat /tmp/stub_normal.log; FAIL=1; }

# 19. AGENTS.md auto-loads into the system prompt; --bare does not
rm -rf /tmp/idefix-agents-repo
mkdir -p /tmp/idefix-agents-repo && echo "RULE: always eat oranges" > /tmp/idefix-agents-repo/AGENTS.md
run_mode normal ./idefix --repo /tmp/idefix-agents-repo "task" >/dev/null 2>&1
grep -q "eat oranges" /tmp/stub_normal.log && echo "PASS agents.md loaded" || { echo "FAIL agents.md loaded"; cat /tmp/stub_normal.log; FAIL=1; }
rm -f /tmp/stub_normal.log
run_mode normal ./idefix --repo /tmp/idefix-agents-repo --bare "task" >/dev/null 2>&1
grep -q "eat oranges" /tmp/stub_normal.log && { echo "FAIL bare loaded agents.md"; FAIL=1; } || echo "PASS bare skips agents.md"

# 20. --bare writes no state
rm -rf /tmp/idefix-state-bare
run_mode normal ./idefix --repo . --bare --state-dir /tmp/idefix-state-bare "task" >/dev/null 2>&1
[ ! -e /tmp/idefix-state-bare ] && echo "PASS bare no state" || { echo "FAIL bare wrote state"; FAIL=1; }

# 21. UTF-8 reaches the wire unmodified (json_quote pass-through)
run_mode normal ./idefix --repo . --bare "café" >/dev/null 2>&1
grep -q "STUB user: café" /tmp/stub_normal.log && echo "PASS utf8" || { echo "FAIL utf8"; grep "STUB user" /tmp/stub_normal.log; FAIL=1; }

# 22. chatty command still hits --max-command-seconds
printf '!yes\n' | ./idefix --repo . --max-command-seconds 1 >/dev/null 2>&1 &
pid=$!; sleep 4
if kill -0 "$pid" 2>/dev/null; then echo "FAIL chatty timeout"; kill "$pid" 2>/dev/null; FAIL=1; else echo "PASS chatty timeout"; fi
wait "$pid" 2>/dev/null

# 23. /reset survives --continue: pre-reset messages are not replayed
rm -rf /tmp/idefix-state-reset
printf 'first-one\n/reset\nsecond-two\n/quit\n' | run_mode normal ./idefix --repo . --state-dir /tmp/idefix-state-reset >/dev/null 2>&1
grep -q '"ev":"reset"' /tmp/idefix-state-reset/sessions/*/journal.jsonl && echo "PASS reset journaled" || { echo "FAIL reset journaled"; FAIL=1; }
run_mode normal ./idefix --repo . --state-dir /tmp/idefix-state-reset --continue "third" >/dev/null 2>&1
grep "STUB users" /tmp/stub_normal.log | tail -1 | grep -q "first-one" && { echo "FAIL reset replay"; FAIL=1; } || echo "PASS reset replay"

# 24. numeric flag validation: missing/garbage/negative values exit 64 cleanly
out=$(./idefix --repo . --max-requests 2>&1); rc=$?
check "missing value exit" 64 "$rc"
echo "$out" | grep -q "missing value" && echo "PASS missing value msg" || { echo "FAIL missing value msg: $out"; FAIL=1; }
./idefix --repo . --max-requests abc "task" >/dev/null 2>&1; check "bad integer exit" 64 "$?"
./idefix --repo . --max-output-bytes -1 "task" >/dev/null 2>&1; check "negative value exit" 64 "$?"
./idefix --repo . --temperature abc "task" >/dev/null 2>&1; check "bad float exit" 64 "$?"
./idefix --repo . one two >/dev/null 2>&1; check "extra positional exit" 64 "$?"

# 25. signal-killed command reports 128+signo, not 0
out=$(printf '!kill -9 $$\n/quit\n' | ./idefix --repo . --state-dir /tmp/idefix-state-sig 2>&1)
echo "$out" | grep -q "!exit 137" && echo "PASS signal exit 137" || { echo "FAIL signal exit"; echo "$out"; FAIL=1; }

# 26. model tool name with a quote can't corrupt the wire JSON
out=$(run_mode weirdname ./idefix --repo . "task" 2>/dev/null); rc=$?
check "weirdname exit" 0 "$rc"
check "weirdname answer" "Done." "$out"
grep -q "STUB tool json ok: True" /tmp/stub_weirdname.log && echo "PASS weirdname json" || { echo "FAIL weirdname json"; cat /tmp/stub_weirdname.log; FAIL=1; }
grep -q '"name":"weird' /tmp/stub_weirdname.log && echo "PASS weirdname name" || { echo "FAIL weirdname name"; FAIL=1; }

# 27. --max-http-bytes caps the response body -> transport error -> exit 3
out=$(run_mode normal ./idefix --repo . --max-http-bytes 10 --retries 0 "task" 2>/dev/null); rc=$?
check "http cap exit" 3 "$rc"

# 28. session dir is private
rm -rf /tmp/idefix-state-perms
run_mode normal ./idefix --repo . --state-dir /tmp/idefix-state-perms "task" >/dev/null 2>&1
check "session dir perms" "rwx------" "$(ls -ld /tmp/idefix-state-perms/sessions/*/ | cut -c2-10)"

# 29. binout: invalid UTF-8 in tool output is sanitized, request still parses
out=$(run_mode binout ./idefix --repo . "task" 2>/dev/null); rc=$?
check "binout exit" 0 "$rc"
check "binout answer" "Done." "$out"
grep -q "STUB tool json ok: True" /tmp/stub_binout.log && echo "PASS binout json" || { echo "FAIL binout json"; cat /tmp/stub_binout.log; FAIL=1; }
grep -q "$(printf '\357\277\275')" /tmp/stub_binout.log && echo "PASS binout sanitized" || { echo "FAIL binout sanitized"; FAIL=1; }

# 30. unknown flags exit 64; -- gates a task starting with -
out=$(./idefix --repo . --retriess 2>&1); rc=$?
check "unknown flag exit" 64 "$rc"
echo "$out" | grep -q "unknown flag" && echo "PASS unknown flag msg" || { echo "FAIL unknown flag msg: $out"; FAIL=1; }
out=$(run_mode normal ./idefix --repo . -- "-weird-task" 2>/dev/null); rc=$?
check "dashdash task exit" 0 "$rc"
check "dashdash answer" "Done." "$out"

# 31. --max-requests counts retries: cap 1 + flaky 500 -> no retry, exit 3
out=$(run_mode flaky ./idefix --repo . --max-requests 1 "task" 2>/dev/null); rc=$?
check "cap counts retries exit" 3 "$rc"

# 32. --bare keeps v1 wire behavior: context 400 -> exit 3, never compacts
out=$(run_mode ctxerr ./idefix --repo . --bare "task" 2>/dev/null); rc=$?
check "bare ctxerr exit" 3 "$rc"
grep -q "cleared; re-run" /tmp/stub_ctxerr.log && { echo "FAIL bare compacted"; FAIL=1; } || echo "PASS bare no compact"

# 33. --bare rejects session/notify flags instead of silently dropping them
./idefix --repo . --bare --continue "task" >/dev/null 2>&1; check "bare continue exit" 64 "$?"
./idefix --repo . --bare --resume /tmp/idefix-res.jsonl "task" >/dev/null 2>&1; check "bare resume exit" 64 "$?"
./idefix --repo . --bare --notify true "task" >/dev/null 2>&1; check "bare notify exit" 64 "$?"

# 34. --repo must be a directory; unusable state dir warns but runs
out=$(./idefix --repo ./README.md "task" 2>&1); rc=$?
check "repo file exit" 64 "$rc"
echo "$out" | grep -q "not a directory" && echo "PASS repo file msg" || { echo "FAIL repo file msg: $out"; FAIL=1; }
touch /tmp/idefix-statefile
out=$(run_mode normal ./idefix --repo . --state-dir /tmp/idefix-statefile "task" 2>&1 >/dev/null); rc=$?
check "state-dir fail runs" 0 "$rc"
echo "$out" | grep -q "journal/status off" && echo "PASS state-dir fail note" || { echo "FAIL state-dir fail note: $out"; FAIL=1; }
rm -f /tmp/idefix-statefile

# 35. chunked response has no Content-Length: --max-http-bytes still caps it
out=$(run_mode chunked ./idefix --repo . --max-http-bytes 1024 --retries 0 "task" 2>&1); rc=$?
check "chunked cap exit" 3 "$rc"
echo "$out" | grep -q "exceeds --max-http-bytes" && echo "PASS chunked cap msg" || { echo "FAIL chunked cap msg: $out"; FAIL=1; }

# 36. env scrub: model commands see no credential-named vars, others pass through
rm -f /tmp/stub_envdump.log
out=$(run_mode envdump env IDEFIX_API_KEY=sekrit-xy api_key=sk-lower KEEP_ME_PLAIN=visible ./idefix --repo . "task" 2>/dev/null); rc=$?
check "envdump exit" 0 "$rc"
grep -q "KEEP_ME_PLAIN=visible" /tmp/stub_envdump.log && echo "PASS env plain kept" || { echo "FAIL env plain kept"; cat /tmp/stub_envdump.log; FAIL=1; }
grep -q "sekrit-xy\|IDEFIX_API_KEY" /tmp/stub_envdump.log && { echo "FAIL env leaked credential"; FAIL=1; } || echo "PASS env scrubbed"
grep -q "sk-lower\|api_key" /tmp/stub_envdump.log && { echo "FAIL env leaked lowercase credential"; FAIL=1; } || echo "PASS env scrubbed lowercase"

# 37. changed_files: tool result lists files the command actually changed
rm -f /tmp/idefix_cf.json /tmp/idefix_cf_bare.json cf-out.txt
run_mode cfdiff ./idefix --repo . --transcript /tmp/idefix_cf.json "task" >/dev/null 2>&1
python3 -c "import json;d=json.load(open('/tmp/idefix_cf.json'));t=[m for m in d if m['role']=='tool'];assert 'cf-out.txt' in t[0]['content'],t[0]" && echo "PASS changed_files reported" || { echo "FAIL changed_files reported"; FAIL=1; }
run_mode cfdiff ./idefix --bare --repo . --transcript /tmp/idefix_cf_bare.json "task" >/dev/null 2>&1
python3 -c "import json;d=json.load(open('/tmp/idefix_cf_bare.json'));assert 'changed_files' not in json.dumps(d)" && echo "PASS bare omits changed_files" || { echo "FAIL bare omits changed_files"; FAIL=1; }
rm -f cf-out.txt

exit $FAIL
