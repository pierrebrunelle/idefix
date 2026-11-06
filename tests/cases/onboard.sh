# Test --onboard flag prepends context to user message
out=$(run_mode onboard ./idefix --repo . --onboard "find this file" 2>/dev/null); rc=$?
check "onboard exit" 0 "$rc"
check "onboard answer" "Done." "$out"
# Verify the context block was sent (check for file tree marker in stub log)
grep -q "=== file tree ===" /tmp/stub_onboard.log && echo "PASS onboard context" || { echo "FAIL onboard context"; cat /tmp/stub_onboard.log; FAIL=1; }
# Verify AGENTS.md excerpt was included
grep -q "=== AGENTS.md" /tmp/stub_onboard.log && echo "PASS onboard agents" || { echo "FAIL onboard agents"; FAIL=1; }
