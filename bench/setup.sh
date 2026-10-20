#!/bin/bash
# bench setup: check tools, verify the harness versions RESULTS.md was
# produced with, create the gitignored dsh home skeleton. The matrix itself
# still needs `max serve` on :8000 and toolcall_proxy.py on :8001.
set -u
cd "$(dirname "$0")"

want_pi=1.3.0
want_dsh=0.2.0-rc.2
want_aider=0.86.2
missing=0

if [ -x "../max" ]; then echo "ok    max (./max)"; else
    echo "MISS  max - build: ./install.sh or see Makefile"; missing=1; fi
for tool in curl python3 uv; do
    if command -v "$tool" >/dev/null 2>&1; then echo "ok    $tool"; else
        echo "MISS  $tool"; missing=1; fi
done

if [ "$(pi --version 2>/dev/null)" = "$want_pi" ]; then
    echo "ok    pi $want_pi"
else
    echo "MISS  pi $want_pi (have: $(pi --version 2>/dev/null || echo none)) - npm install -g @earendil-works/pi-coding-agent@$want_pi"
    missing=1
fi
if [ "$(dsh --version 2>/dev/null)" = "$want_dsh" ]; then
    echo "ok    dsh $want_dsh"
else
    echo "MISS  dsh $want_dsh (have: $(dsh --version 2>/dev/null || echo none)) - npm install -g @deepseek-ai/dsh@$want_dsh"
    missing=1
fi
if command -v opencode >/dev/null 2>&1; then
    echo "ok    opencode $(opencode --version 2>/dev/null)"
else
    echo "MISS  opencode - npm install -g opencode-ai"; missing=1
fi
# aider runs via `uv tool run --from aider-chat==<ver>` (see aider_cmd);
# this resolves and caches it so the first bench run is not the install
if command -v uv >/dev/null 2>&1 \
    && uv tool run --python 3.12 --from "aider-chat==$want_aider" aider --version >/dev/null 2>&1; then
    echo "ok    aider $want_aider"
else
    echo "MISS  aider $want_aider - uv tool run --python 3.12 --from aider-chat==$want_aider aider --version"
    missing=1
fi

if [ ! -d dsh-home/profiles/headless ]; then
    mkdir -p dsh-home/profiles/headless
    cat > dsh-home/profiles/headless/cordis.yml <<'EOF'
# dsh profile root — an empty entry list. The tree is composed as patches:
# each bundle in package.json's dsh.profile.bundles, then cordis.patch.yml, then any
# --patch overlays. Edit cordis.patch.yml, not this file.
[]
EOF
    cat > dsh-home/profiles/headless/package.json <<'EOF'
{
  "name": "dsh-profile-headless",
  "private": true,
  "dependencies": {},
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-headless"
      ]
    }
  }
}
EOF
    cat > dsh-home/profiles/headless/cordis.patch.yml <<'EOF'
# Your patch layer for this dsh profile, applied after every bundle layer:
# a top-level YAML array of loader patch entries (id-targeted config
# overrides, disables, and insert lists; `!!js` expressions allowed).
[]
EOF
    cat > dsh-home/profiles/headless/pnpm-workspace.yaml <<'EOF'
packages:
  - .

nodeLinker: hoisted
autoInstallPeers: false
EOF
    echo "made  dsh-home/profiles/headless (gitignored)"
else
    echo "ok    dsh-home/profiles/headless"
fi

for url in http://127.0.0.1:8000/v1 http://127.0.0.1:8001/v1; do
    if curl -sf -m 3 "$url/models" >/dev/null 2>&1; then
        echo "up    $url"
    else
        echo "down  $url - needed at matrix time, not for setup"
    fi
done

[ "$missing" -eq 0 ]
