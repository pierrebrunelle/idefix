#!/bin/bash
# bench setup: check the tools the internal arms (mojo, max, ref) need.
# External-harness tools (aider/pi/dsh/opencode) are reported but not
# required; their configs live in max-results/compare/ (BENCH_EXT_DIR).
set -eu
cd "$(dirname "$0")"

want_pi=1.3.0
want_dsh=0.2.0-rc.2
want_aider=0.86.2
want_opencode=1.19.3
missing=0

if [ -x "../max" ]; then echo "ok    max (./max)"; else
    echo "MISS  max - build: ./install.sh or see Makefile"; missing=1; fi
for tool in curl python3 uv; do
    if command -v "$tool" >/dev/null 2>&1; then echo "ok    $tool"; else
        echo "MISS  $tool"; missing=1; fi
done

echo "-- external arms (optional) --"

if [ "$(pi --version 2>/dev/null)" = "$want_pi" ]; then
    echo "ok    pi $want_pi"
else
    echo "warn  pi $want_pi (have: $(pi --version 2>/dev/null || echo none)) - npm install -g @earendil-works/pi-coding-agent@$want_pi"
fi
if [ "$(dsh --version 2>/dev/null)" = "$want_dsh" ]; then
    echo "ok    dsh $want_dsh"
else
    echo "warn  dsh $want_dsh (have: $(dsh --version 2>/dev/null || echo none)) - npm install -g @deepseek-ai/dsh@$want_dsh"
fi
if [ "$(opencode --version 2>/dev/null)" = "$want_opencode" ]; then
    echo "ok    opencode $want_opencode"
else
    echo "warn  opencode $want_opencode (have: $(opencode --version 2>/dev/null || echo none)) - npm install -g opencode-ai@$want_opencode"
fi
if ! command -v pnpm >/dev/null 2>&1; then
    echo "warn  pnpm missing - dsh materializes profile bundles via pnpm"
fi
# aider runs via `uv tool run --from aider-chat==<ver>` (see aider_cmd);
# this resolves and caches it so the first bench run is not the install
if command -v uv >/dev/null 2>&1 \
    && uv tool run --python 3.12 --from "aider-chat==$want_aider" aider --version >/dev/null 2>&1; then
    echo "ok    aider $want_aider"
else
    echo "warn  aider $want_aider - uv tool run --python 3.12 --from aider-chat==$want_aider aider --version"
fi

for url in "${MAX_BASE_URL:-http://127.0.0.1:8000/v1}" "${BENCH_TOOLCALL_BASE:-http://127.0.0.1:8001/v1}"; do
    if curl -sf -m 3 "$url/models" >/dev/null 2>&1; then
        echo "up    $url"
    else
        echo "down  $url - needed at matrix time, not for setup"
    fi
done

[ "$missing" -eq 0 ]
