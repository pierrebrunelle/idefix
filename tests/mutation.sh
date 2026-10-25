#!/bin/bash
# mutation.sh: canary proving the stub suite can fail (AGENTS.md:
# "Verification must be able to fail"). Each mutation below is applied in
# place, the binary is rebuilt and the affected check re-run; the check
# must FAIL. An observed PASS means the test has no teeth and this script
# exits nonzero. Sources are restored after every probe and the tree is
# rebuilt clean at the end. Deliberately not wired into tests/run.sh:
# manual/CI use only.
set -u
cd "$(dirname "$0")/.."

MOJO="${MOJO:-/Users/pjlb/mojo-agent-spike/.venv/bin/mojo}"
export MAX_BASE_URL="http://127.0.0.1:18923/v1"
export MAX_MODEL="${MAX_MODEL:-test-model}"
export MAX_STATE_DIR=/tmp/max-mutation-state   # keep probes out of real $HOME

RESULT=0

kill_stub() { lsof -ti:18923 2>/dev/null | xargs kill -9 2>/dev/null || true; }

cleanup() {
    cp /tmp/max-mut-max.mojo max.mojo 2>/dev/null || true
    cp /tmp/max-mut-max_shim.c max_shim.c 2>/dev/null || true
    cp /tmp/max-mut-bindings.mojo bindings.mojo 2>/dev/null || true
    rm -f pwned.txt 'x$(touch pwned.txt)'
    pkill -f "sleep 29" 2>/dev/null || true
    kill_stub
}
trap cleanup EXIT

# same stub wrapper as tests/run.sh
run_mode() {
    local mode="$1"; shift
    python3 tests/stub_server.py 18923 "$mode" 2>/tmp/stub_$mode.log &
    local pid=$!
    sleep 0.6
    "$@" >/dev/null 2>&1
    local rc=$?
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return $rc
}

report() { # site test observed
    echo "MUTATED $1 -> expected FAIL $2 -> observed $3"
    [ "$3" = "FAIL" ] || RESULT=1
}

build() {
    make MOJO="$MOJO" >/dev/null || { echo "build failed; aborting" >&2; exit 1; }
}

kill_stub

# pristine copies; cleanup() restores from these even on early exit
cp max.mojo /tmp/max-mut-max.mojo
cp max_shim.c /tmp/max-mut-max_shim.c
cp bindings.mojo /tmp/max-mut-bindings.mojo

# a. looks_write: make '>' in 2>&1 count as a write -> false noop warning
echo "== a. looks_write fd-dup rule (nxt != 0x26 -> 0x21)"
sed -i.bak 's/and nxt != 0x26:/and nxt != 0x21:/' max.mojo && rm -f max.mojo.bak
grep -q 'nxt != 0x21' max.mojo || { echo "edit did not apply" >&2; exit 1; }
build
rm -f /tmp/stub_redirnoop.log
run_mode redirnoop ./max --repo . "task"
grep -q "may not have applied" /tmp/stub_redirnoop.log && obs=FAIL || obs=PASS
cp /tmp/max-mut-max.mojo max.mojo
report "max.mojo looks_write nxt!=0x26->0x21" "redirnoop" "$obs"

# b. diff-echo: interpolate changed filenames unquoted -> pwned.txt executes
echo "== b. diff-echo filename quoting (unquoted fname)"
sed -i.bak 's|qf += .*|qf += fname + " "|' max.mojo && rm -f max.mojo.bak
grep -q 'qf += fname + " "' max.mojo || { echo "edit did not apply" >&2; exit 1; }
build
rm -f pwned.txt 'x$(touch pwned.txt)'
run_mode injname ./max --repo . "task"
[ -f pwned.txt ] && obs=FAIL || obs=PASS
rm -f pwned.txt 'x$(touch pwned.txt)'
cp /tmp/max-mut-max.mojo max.mojo
report "max.mojo diff-echo unquoted fname" "injname" "$obs"

# c. env scrub: drop the 'key' name marker -> api_key leaks into env dump
echo "== c. shim_scrubbed_env pattern (key -> zzz)"
sed -i.bak 's/"key"/"zzz"/' max_shim.c && rm -f max_shim.c.bak
grep -q '"zzz"' max_shim.c || { echo "edit did not apply" >&2; exit 1; }
build
rm -f /tmp/stub_envdump.log
run_mode envdump env MAX_API_KEY=sekrit-xy api_key=sk-lower KEEP_ME_PLAIN=visible \
    ./max --repo . "task"
grep -q 'sk-lower\|api_key' /tmp/stub_envdump.log && obs=FAIL || obs=PASS
cp /tmp/max-mut-max_shim.c max_shim.c
report "max_shim.c scrub key->zzz" "envdump" "$obs"

# d. detached-grandchild killpg: skip the group kill after normal
#    completion -> (sleep 29 &) survives -> pgrep finds it -> FAIL
echo "== d. post-drain killpg (elif not timed_out -> elif timed_out)"
sed -i.bak 's/elif not timed_out:/elif timed_out:/' bindings.mojo && rm -f bindings.mojo.bak
grep -q 'elif timed_out:' bindings.mojo || { echo "edit did not apply" >&2; exit 1; }
build
pkill -f "sleep 29" 2>/dev/null || true
run_mode detach ./max --repo . "task"
sleep 1
pgrep -f "sleep 29" >/dev/null && obs=FAIL || obs=PASS
pkill -f "sleep 29" 2>/dev/null || true
cp /tmp/max-mut-bindings.mojo bindings.mojo
report "bindings.mojo killpg guard inverted" "detach" "$obs"

echo "== restoring clean binary"
build

exit $RESULT
