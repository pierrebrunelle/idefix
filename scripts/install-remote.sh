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
json=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")
url=$(printf '%s\n' "$json" | grep '"browser_download_url"' \
    | grep "$artifact.tar.gz" | cut -d'"' -f4 || true)
[ -n "$url" ] || { echo "max: no $artifact asset on latest release" >&2; exit 1; }
sums_url=$(printf '%s\n' "$json" | grep '"browser_download_url"' \
    | grep "checksums.txt" | cut -d'"' -f4 || true)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp/$artifact.tar.gz"

# checksums.txt lines are "<sha256>  <basename>", so verify inside $tmp.
# Older releases have no checksums.txt: warn and continue.
if [ -n "$sums_url" ] && command -v shasum >/dev/null 2>&1; then
    curl -fsSL "$sums_url" -o "$tmp/checksums.txt"
    if ! grep " $artifact\.tar\.gz$" "$tmp/checksums.txt" > "$tmp/check.txt"; then
        echo "max: checksums.txt has no entry for $artifact.tar.gz" >&2; exit 1
    fi
    if ! (cd "$tmp" && shasum -a 256 -c check.txt); then
        echo "max: checksum verification FAILED for $artifact.tar.gz; aborting" >&2
        exit 1
    fi
elif [ -n "$sums_url" ]; then
    echo "max: warning: shasum not found; skipping integrity check" >&2
else
    echo "max: warning: no checksums.txt on the release; skipping integrity check" >&2
fi

rm -rf "$DEST"; mkdir -p "$DEST" "$BINDIR"
tar -xzf "$tmp/$artifact.tar.gz" -C "$DEST"
chmod +x "$DEST/max"

# the bundle ships with-max (lazy-serve wrapper); bin/max symlinks to it
chmod +x "$DEST/with-max"
ln -sf "$DEST/with-max" "$BINDIR/max"

echo "installed: $BINDIR/max (-> $DEST)"

# Reachability check: `max` is only usable if it resolves to this symlink.
resolved="$(command -v max 2>/dev/null || true)"
if [ "$resolved" != "$BINDIR/max" ]; then
    echo
    echo "max: note: 'max' on PATH resolves to '${resolved:-nothing}', not this install." >&2
    case ":$PATH:" in
        *":$BINDIR:"*) ;;
        *) echo "max: $BINDIR is not on PATH." >&2 ;;
    esac
    if [ -n "$resolved" ]; then
        echo "max: another 'max' CLI (likely Modular's) owns that name;" >&2
        echo "max: the wrapper still finds it as the model server." >&2
    fi
    echo "max: fix:  echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" >&2
    echo "max: or run directly: $BINDIR/max 'task'" >&2
else
    echo "next:      cd your-project && max 'fix the parser bug'"
fi
