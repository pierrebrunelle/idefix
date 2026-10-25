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
echo "usage:     max 'fix the parser bug'   # from inside any repo"
