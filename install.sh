#!/bin/bash
# install.sh — build the bundle and install under ~/.local/max.
# `max` becomes a self-contained binary + runtime dylibs, no Mojo toolchain,
# no Python. Requires `mojo` on PATH only at install time. Note: installing
# `max` shadows Modular's `max` CLI wherever ~/.local/bin precedes it on PATH.
set -euo pipefail
cd "$(dirname "$0")"

make bundle
DEST="$HOME/.local/max"
rm -rf "$DEST"
mkdir -p "$DEST" "$HOME/.local/bin"
cp -R bundle/. "$DEST/"
cat > "$HOME/.local/bin/max" <<EOF
#!/bin/bash
exec "$DEST/max" "\$@"
EOF
chmod +x "$HOME/.local/bin/max"
echo "installed: $HOME/.local/bin/max (-> $DEST)"
echo "usage:     MAX_MODEL=<model> max --repo . 'task'"
