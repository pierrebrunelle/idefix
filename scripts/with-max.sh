#!/bin/bash
# with-max.sh [max args...] — lazily serve MAX_MODEL via `max serve`, then
# run ./max. If a server already answers at MAX_BASE_URL, it is left alone.
set -euo pipefail
cd "$(dirname "$0")/.."

MAXCLI="${MAXCLI:-max}"
export MAX_MODEL="${MAX_MODEL:-Qwen/Qwen3-1.7B}"
BASE="${MAX_BASE_URL:-http://127.0.0.1:8000/v1}"

started=""
LOG=""
if ! curl -sf -m 2 "$BASE/models" >/dev/null; then
    if ! "$MAXCLI" --help 2>&1 | grep -qi serve; then
        echo "with-max: $MAXCLI has no 'serve' command (the agent binary shadows Modular's max?); set MAXCLI=/path/to/modular-max" >&2
        exit 1
    fi
    LOG="$(mktemp "${TMPDIR:-/tmp}/max-serve.XXXXXX")"
    echo "with-max: starting max serve ($MAX_MODEL) ..." >&2
    serve_args=(serve --model "$MAX_MODEL")
    if [ "${MAX_GPU:-0}" != "1" ]; then
        serve_args+=(--devices cpu --quantization-encoding float32)
    fi
    "$MAXCLI" "${serve_args[@]}" >"$LOG" 2>&1 &
    started=$!
    keep_log=""
    trap 'kill "$started" 2>/dev/null; wait "$started" 2>/dev/null; [ -n "$LOG" ] && [ -z "$keep_log" ] && rm -f "$LOG"' EXIT
    for _ in $(seq 1 150); do
        curl -sf -m 2 "$BASE/models" >/dev/null && break
        sleep 2
    done
    curl -sf -m 2 "$BASE/models" >/dev/null || {
        keep_log=1
        echo "with-max: server did not come up; see $LOG" >&2
        exit 1
    }
fi
./max "$@"
rc=$?
# Plain exit so the EXIT trap fires: kill the server we started, drop its log.
exit "$rc"
