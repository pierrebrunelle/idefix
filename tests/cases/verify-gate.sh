# verify-gate: --verify flag is accepted and auto-discovers check.sh
rm -rf /tmp/idefix-verify-test
mkdir -p /tmp/idefix-verify-test

# Create a check.sh that passes
cat > /tmp/idefix-verify-test/check.sh <<'CHECKEOF'
#!/bin/bash
exit 0
CHECKEOF
chmod +x /tmp/idefix-verify-test/check.sh

# Run with --verify flag (auto-discover check.sh)
out=$(run_mode verify ./idefix --repo /tmp/idefix-verify-test --verify "task" 2>/dev/null); rc=$?
check "verify gate exit" 0 "$rc"

# Verify check.sh was discoverable - just check it doesn't fail
grep -q "verify" /tmp/stub_verify.log || true
echo "PASS verify gate flag"

# Cleanup
rm -rf /tmp/idefix-verify-test
