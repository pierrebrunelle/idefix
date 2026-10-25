#!/bin/bash
# install-remote.sh: curl installer for the max agent bundle.
# Usage: curl -fsSL https://raw.githubusercontent.com/pierrebrunelle/max/main/scripts/install-remote.sh | bash
#
# Downloads the latest release bundle (binary + runtime dylibs + with-max)
# for this OS/arch into ~/.local/{max,bin}, reproducing install.sh's layout
# without a mojo toolchain.
set -euo pipefail

REPO="pierrebrunelle/max"
DEST="${1:-$HOME/.local/max}"
BINDIR="${BINDIR:-$HOME/.local/bin}"

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  artifact="max-darwin-arm64" ;;
    Linux-x86_64)  artifact="max-linux-x86_64" ;;
    *) echo "max: unsupported platform $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

echo "max: fetching latest release for $artifact"
url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"browser_download_url"' | grep "$artifact.tar.gz" | cut -d'"' -f4)
[ -n "$url" ] || { echo "max: no $artifact asset on latest release" >&2; exit 1; }

rm -rf "$DEST"; mkdir -p "$DEST" "$BINDIR"
curl -fsSL "$url" | tar -xzf - -C "$DEST"
chmod +x "$DEST/max"

# the bundle ships with-max (lazy-serve wrapper); bin/max symlinks to it
chmod +x "$DEST/with-max"
ln -sf "$DEST/with-max" "$BINDIR/max"

echo "installed: $BINDIR/max (-> $DEST)"
echo "next:      cd your-project && max 'fix the parser bug'"
