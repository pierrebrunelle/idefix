#!/bin/bash
# with-max.sh [max args...] — lazily serve MAX_MODEL via `max serve`, then
# run the built max binary. If a server already answers at MAX_BASE_URL, it
# is left alone. Runs from the caller's cwd: --repo paths are relative to it.
set -euo pipefail
# Resolve symlinks so $SELF is where the script physically lives. Repo
# layout: scripts/with-max.sh drives ../max. Bundle/install layout:
# with-max sits next to the max binary it drives.
SELF="$0"
while [ -L "$SELF" ]; do
    dir="$(cd "$(dirname "$SELF")" && pwd)"
    SELF="$(readlink "$SELF")"
    case "$SELF" in /*) ;; *) SELF="$dir/$SELF" ;; esac
done
ROOT="$(cd "$(dirname "$SELF")" && pwd)"
# -ef keeps a wrapper installed as "max" from resolving to itself; -f
# because a directory passes -x.
if [ ! -f "$ROOT/max" ] || [ "$ROOT/max" -ef "$SELF" ]; then
    ROOT="$(cd "$ROOT/.." && pwd)"
fi

# The model-server CLI defaults to `max` (Modular's). If this script is
# itself on PATH as `max` (any name, via symlink or not), skip candidates
# that resolve to it: -ef compares files, not strings.
MAXCLI="${MAXCLI:-}"
if [ -z "$MAXCLI" ]; then
    while IFS= read -r c; do
        [ -n "$c" ] && [ ! "$c" -ef "$SELF" ] && MAXCLI="$c" && break
    done <<EOF
$(type -aP max 2>/dev/null)
EOF
fi
export MAX_MODEL="${MAX_MODEL:-Qwen/Qwen3-1.7B}"
BASE="${MAX_BASE_URL:-http://127.0.0.1:8000/v1}"

# Server up? Sends MAX_API_KEY when set so authenticated endpoints probe true.
up() {
    if [ -n "${MAX_API_KEY:-}" ]; then
        curl -sf -m 2 -H "Authorization: Bearer $MAX_API_KEY" "$BASE/models" >/dev/null
    else
        curl -sf -m 2 "$BASE/models" >/dev/null
    fi
}

started=""
LOG=""
if ! up; then
    if [ -z "$MAXCLI" ]; then
        echo "with-max: no server at $BASE and no model-server CLI on PATH; set MAXCLI=/path/to/modular-max or start a server" >&2
        exit 1
    fi
    if ! command -v "$MAXCLI" >/dev/null; then
        echo "with-max: '$MAXCLI' not found; set MAXCLI=/path/to/modular-max" >&2
        exit 1
    fi
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
        up && break
        sleep 2
    done
    up || {
        keep_log=1
        echo "with-max: server did not come up; see $LOG" >&2
        exit 1
    }
fi
if [ ! -f "$ROOT/max" ] || [ ! -x "$ROOT/max" ]; then
    echo "with-max: no runnable max binary at $ROOT/max" >&2
    exit 1
fi
"$ROOT/max" "$@"
rc=$?
# Plain exit so the EXIT trap fires: kill the server we started, drop its log.
exit "$rc"
