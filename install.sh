#!/bin/bash
# install.sh — build the bundle and install under ~/.local/max.
# `max` becomes a self-contained binary + runtime dylibs, no Mojo toolchain,
# no Python. Requires `mojo` on PATH only at install time. The installed
# wrapper is scripts/with-max.sh pointed at the install dir, so `max "task"`
# lazily boots a model server when none answers. Note: installing `max`
# shadows Modular's `max` CLI wherever ~/.local/bin precedes it on PATH.
set -euo pipefail
cd "$(dirname "$0")"

make bundle
DEST="$HOME/.local/max"
rm -rf "$DEST"
mkdir -p "$DEST" "$HOME/.local/bin"
cp -R bundle/. "$DEST/"
# bin/max is a symlink to the bundle's lazy-serve wrapper (with-max).
ln -sf "$DEST/with-max" "$HOME/.local/bin/max"
echo "installed: $HOME/.local/bin/max (-> $DEST)"

# Reachability check: `max` is only usable if it resolves to this symlink.
resolved="$(command -v max 2>/dev/null || true)"
if [ "$resolved" != "$HOME/.local/bin/max" ]; then
    echo
    echo "NOTE: 'max' on PATH resolves to '${resolved:-nothing}', not this install."
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) echo "     ~/.local/bin is not on PATH." ;;
    esac
    if [ -n "$resolved" ]; then
        echo "     Modular's own 'max' CLI owns that name; the wrapper still"
        echo "     finds it as the model server."
    fi
    echo "     fix:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
    echo "     or run directly: $HOME/.local/bin/max 'task'"
else
    echo "usage:     max 'fix the parser bug'   # from inside any repo"
fi
