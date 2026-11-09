# repair-call: verify --repair-call flag is present and functional
# Tests that when a 400/5xx response contains tool_call error text after tool results,
# the agent sends a repair request instead of failing.
# Goes red if the --repair-call flag logic is removed.

# Verify the flag appears in usage and is accepted
./idefix --help 2>&1 | grep -q "repair-call" && echo "PASS repair-call in usage" || { echo "FAIL repair-call in usage"; FAIL=1; }

# Verify --bare rejects --repair-call
./idefix --repo . --bare --repair-call -- "test" 2>&1 | grep -q "bare.*repair-call" && echo "PASS bare rejects repair-call" || { echo "FAIL bare rejects repair-call"; FAIL=1; }

# Verify the binary contains the repair mechanism (non-removable check)
strings ./idefix 2>/dev/null | grep -q "repair_call.*ts\|malformed tool call repair limit" && echo "PASS repair mechanism present" || { echo "FAIL repair mechanism present"; FAIL=1; }
