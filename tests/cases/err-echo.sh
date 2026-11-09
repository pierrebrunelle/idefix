# err-echo: transport error feedback allows continuing within budget
# With --err-echo, after retries exhaust on a 500 error, inject a user message
# and continue; without it, exit 3 as before. Uses err500 (infinite 500s) mode
# to test the injection and continuation attempt.

# Test 1: --err-echo with limited retries -> error feedback message injected
rm -rf /tmp/idefix-state-err-echo-on
out=$(run_mode err500 ./idefix --repo . --state-dir /tmp/idefix-state-err-echo-on --err-echo --retries 1 --max-requests 5 "task" 2>/dev/null); rc=$?
check "err-echo-on exit" 3 "$rc"
J=$(ls /tmp/idefix-state-err-echo-on/sessions/*/journal.jsonl 2>/dev/null)
# Verify the error feedback message was injected: should contain "the server rejected"
grep -q "the server rejected your last request" "$J" && echo "PASS err-echo injected message" || { echo "FAIL err-echo no injection"; cat "$J" 2>/dev/null; FAIL=1; }

# Test 2: --bare forbids --err-echo
out=$(./idefix --repo . --bare --err-echo "task" 2>&1); rc=$?
check "bare err-echo exit" 64 "$rc"
echo "$out" | grep -q "err-echo" && echo "PASS bare rejects err-echo" || { echo "FAIL bare err-echo msg"; echo "$out"; FAIL=1; }

# Test 3: without --err-echo, behavior unchanged (still exits 3 after retries)
rm -rf /tmp/idefix-state-err-echo-off
out=$(run_mode err500 ./idefix --repo . --state-dir /tmp/idefix-state-err-echo-off --retries 1 --max-requests 5 "task" 2>/dev/null); rc=$?
check "err-echo-off exit" 3 "$rc"
