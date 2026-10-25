#!/bin/bash
# with-max.sh [max args...] — lazily serve MAX_MODEL via `max serve`, then
# run the built max binary. If a server already answers at MAX_BASE_URL, it
# is left alone. Runs from the caller's cwd: --repo paths are relative to it.
set -euo pipefail
# Resolve symlinks so $SELF is where the script physically lives. Repo
# layout: scripts/with-max.sh drives ../idefix. Bundle/install layout:
# with-max sits next to the idefix binary it drives.
SELF="$0"
while [ -L "$SELF" ]; do
    dir="$(cd "$(dirname "$SELF")" && pwd)"
    SELF="$(readlink "$SELF")"
    case "$SELF" in /*) ;; *) SELF="$dir/$SELF" ;; esac
done
ROOT="$(cd "$(dirname "$SELF")" && pwd)"
# -ef keeps a wrapper installed under any name from resolving to itself; -f
# because a directory passes -x.
if [ ! -f "$ROOT/idefix" ] || [ "$ROOT/idefix" -ef "$SELF" ]; then
    ROOT="$(cd "$ROOT/.." && pwd)"
fi

# subcommands that never need a model server go straight to the binary
case "${1:-}" in
    edit|-h|--help|--version) exec "$ROOT/idefix" "$@" ;;
esac

# The model-server CLI defaults to `max` (Modular's). If this script is
# itself on PATH (any name, via symlink or not), skip candidates
# that resolve to it: -ef compares files, not strings.
# <state>/config (key=value) seeds unset vars; env always wins.
conf="${IDEFIX_STATE_DIR:-${MAX_STATE_DIR:-$HOME/.idefix}}/config"
if [ -f "$conf" ]; then
    while IFS='=' read -r k v; do
        case "$k" in
            model)    : "${IDEFIX_MODEL:=$v}" ;;
            base_url) : "${IDEFIX_BASE_URL:=$v}" ;;
            api_key)  : "${IDEFIX_API_KEY:=$v}" ;;
            maxcli)   : "${IDEFIX_MAXCLI:=$v}" ;;
        esac
    done < "$conf"
fi

# IDEFIX_* are the canonical agent env vars; legacy MAX_* still work.
export MAX_MODEL="${IDEFIX_MODEL:-${MAX_MODEL:-}}"
export MAX_API_KEY="${IDEFIX_API_KEY:-${MAX_API_KEY:-}}"
MAXCLI="${IDEFIX_MAXCLI:-${MAXCLI:-}}"
MAX_GPU="${IDEFIX_GPU:-${MAX_GPU:-}}"
if [ -z "$MAXCLI" ]; then
    while IFS= read -r c; do
        [ -n "$c" ] && [ ! "$c" -ef "$SELF" ] && MAXCLI="$c" && break
    done <<EOF
$(type -aP max 2>/dev/null)
EOF
fi
USER_MODEL="${MAX_MODEL:-}"   # an explicit choice beats whatever is served
BASE="${IDEFIX_BASE_URL:-${MAX_BASE_URL:-}}"
if [ -z "$BASE" ]; then
    # probe the usual local servers first so `idefix` just works when
    # ollama/LM Studio is already up: ollama :11434, max serve :8000,
    # LM Studio :1234. Default stays :8000 for the lazy-boot path.
    for port in 11434 8000 1234; do
        if curl -sf -m 1 "http://127.0.0.1:$port/v1/models" >/dev/null 2>&1; then
            BASE="http://127.0.0.1:$port/v1"
            break
        fi
    done
    BASE="${BASE:-http://127.0.0.1:8000/v1}"
fi
# the binary reads its own env; hand it whichever BASE won.
export IDEFIX_BASE_URL="$BASE"

# Server up? Sends MAX_API_KEY when set so authenticated endpoints probe true.
up() {
    if [ -n "${MAX_API_KEY:-}" ]; then
        curl -sf -m 2 -H "Authorization: Bearer $MAX_API_KEY" "$BASE/models" >/dev/null
    else
        curl -sf -m 2 "$BASE/models" >/dev/null
    fi
}

# "id" fields from GET /models, one per line; sed so jq stays optional.
served_ids() {
    if [ -n "${MAX_API_KEY:-}" ]; then
        curl -sf -m 2 -H "Authorization: Bearer $MAX_API_KEY" "$BASE/models"
    else
        curl -sf -m 2 "$BASE/models"
    fi | tr ',' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p'
}

# The actually-loaded model where the server reports one: ollama exposes
# /api/ps (resident model), so we don't adopt a stale id out of /models.
loaded_id() {
    curl -sf -m 2 "${BASE%/v1}/api/ps" 2>/dev/null \
        | tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | head -1
}

started=""
LOG=""
if up; then
    ids="$(served_ids || true)"
    if [ -z "$USER_MODEL" ]; then
        # no model requested: prefer the resident model, else first served id
        export MAX_MODEL="$(loaded_id || true)"
        [ -n "$MAX_MODEL" ] || export MAX_MODEL="$(printf '%s\n' "$ids" | head -1)"
        export MAX_MODEL="${MAX_MODEL:-Qwen/Qwen3-1.7B}"
    else
        export MAX_MODEL="$USER_MODEL"
        if [ -n "$ids" ] && ! printf '%s\n' "$ids" | grep -qx "$MAX_MODEL"; then
            echo "with-max: warning: $BASE serves [$(printf '%s ' $ids)] not MAX_MODEL=$MAX_MODEL" >&2
        fi
    fi
else
    export MAX_MODEL="${USER_MODEL:-Qwen/Qwen3-1.7B}"
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
if [ ! -f "$ROOT/idefix" ] || [ ! -x "$ROOT/idefix" ]; then
    echo "with-max: no runnable idefix binary at $ROOT/idefix" >&2
    exit 1
fi
# linux bundles rely on this when patchelf was unavailable at build time;
# on macOS the binary already carries @executable_path
export LD_LIBRARY_PATH="$ROOT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$ROOT/idefix" "$@"
rc=$?
# Plain exit so the EXIT trap fires: kill the server we started, drop its log.
exit "$rc"
