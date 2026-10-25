#!/bin/bash
# install.sh — build the bundle and install under ~/.local/idefix.
# `idefix` becomes a self-contained binary + runtime dylibs, no Mojo toolchain,
# no Python. Requires `mojo` on PATH only at install time. The installed
# wrapper is scripts/with-max.sh pointed at the install dir, so `idefix "task"`
# lazily boots a model server when none answers. Modular's `max` CLI is used
# only as the model server (MAXCLI); nothing else is named `idefix`.
set -euo pipefail
cd "$(dirname "$0")"

make bundle
DEST="$HOME/.local/idefix"
rm -rf "$DEST"
mkdir -p "$DEST" "$HOME/.local/bin"
cp -R bundle/. "$DEST/"
# bin/idefix is a symlink to the bundle's lazy-serve wrapper (with-max).
ln -sf "$DEST/with-max" "$HOME/.local/bin/idefix"
echo "installed: $HOME/.local/bin/idefix (-> $DEST)"

# Reachability check: `idefix` is only usable if it resolves to this symlink.
resolved="$(command -v idefix 2>/dev/null || true)"
if [ "$resolved" != "$HOME/.local/bin/idefix" ]; then
    echo
    echo "NOTE: 'idefix' on PATH resolves to '${resolved:-nothing}', not this install."
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) echo "     ~/.local/bin is not on PATH." ;;
    esac
    echo "     fix:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
    echo "     or run directly: $HOME/.local/bin/idefix 'task'"
else
    echo "usage:     idefix 'fix the parser bug'   # from inside any repo"
fi
