#!/bin/bash
# install-remote.sh: curl installer for the idefix agent bundle.
# Usage: curl -fsSL https://raw.githubusercontent.com/pierrebrunelle/idefix/main/scripts/install-remote.sh | bash
#
# Downloads the latest release bundle (binary + runtime dylibs + with-max)
# for this OS/arch into ~/.local/{idefix,bin}, reproducing install.sh's
# layout without a mojo toolchain.
set -euo pipefail

REPO="pierrebrunelle/idefix"
DEST="${1:-$HOME/.local/idefix}"
BINDIR="${BINDIR:-$HOME/.local/bin}"

# $1 becomes rm -rf'ed below; refuse paths that would take the disk or
# $HOME with them.
case "$DEST" in
    ""|"/"|"$HOME") echo "idefix: refusing to install into '$DEST'" >&2; exit 1 ;;
esac

os="$(uname -s)"
# A Rosetta 2 shell reports x86_64; the arm64 binary is still correct.
if [ "$os" = "Darwin" ] && [ "$(sysctl -in sysctl.proc_translated 2>/dev/null)" = "1" ]; then
    mach="arm64"
else
    mach="$(uname -m)"
fi
case "$os-$mach" in
    Darwin-arm64)   artifact="idefix-darwin-arm64" ;;
    Linux-x86_64)   artifact="idefix-linux-x86_64" ;;
    Windows_NT-*)   echo "idefix: no native Windows build; run inside WSL" >&2; exit 1 ;;
    *) echo "idefix: unsupported platform $os-$mach" >&2; exit 1 ;;
esac

# IDEFIX_VERSION pins a tag (e.g. v0.1.0); default follows latest release.
# Direct release URLs avoid the rate-limited api.github.com JSON lookup.
if [ -n "${IDEFIX_VERSION:-}" ]; then
    base="https://github.com/$REPO/releases/download/$IDEFIX_VERSION"
else
    base="https://github.com/$REPO/releases/latest/download"
fi
url="$base/$artifact.tar.gz"
sums_url="$base/checksums.txt"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp/$artifact.tar.gz" \
    || { echo "idefix: no $artifact asset on that release" >&2; exit 1; }

# checksums.txt lines are "<sha256>  <basename>", so verify inside $tmp.
# sha256sum is coreutils (Linux); shasum is perl (macOS). One is required
# to verify; if the release itself has no checksums.txt we warn and
# continue for pre-checksum releases.
sum_check() { (cd "$tmp" && "$@" -c check.txt); }
if curl -fsSL "$sums_url" -o "$tmp/checksums.txt" 2>/dev/null; then
    if ! grep " $artifact\.tar\.gz$" "$tmp/checksums.txt" > "$tmp/check.txt"; then
        echo "idefix: checksums.txt has no entry for $artifact.tar.gz" >&2; exit 1
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        sum_check sha256sum || { echo "idefix: checksum FAILED for $artifact.tar.gz" >&2; exit 1; }
    elif command -v shasum >/dev/null 2>&1; then
        sum_check shasum -a 256 || { echo "idefix: checksum FAILED for $artifact.tar.gz" >&2; exit 1; }
    else
        echo "idefix: warning: no sha256sum/shasum; skipping integrity check" >&2
    fi
else
    echo "idefix: warning: no checksums.txt on the release; skipping integrity check" >&2
fi

rm -rf "$DEST"; mkdir -p "$DEST" "$BINDIR"
tar -xzf "$tmp/$artifact.tar.gz" -C "$DEST"
chmod +x "$DEST/idefix"

# the bundle ships with-max (lazy-serve wrapper); bin/idefix symlinks to it
chmod +x "$DEST/with-max"
ln -sf "$DEST/with-max" "$BINDIR/idefix"

echo "installed: $BINDIR/idefix (-> $DEST)"

# Linux bundles link libcurl.so.4 dynamically; warn when it is absent.
if [ "$(uname -s)" = "Linux" ] && command -v ldconfig >/dev/null 2>&1 \
    && ! ldconfig -p 2>/dev/null | grep -q "libcurl\.so"; then
    echo "idefix: warning: libcurl.so.4 not found; install libcurl4 (e.g. apt install libcurl4)" >&2
fi

# Reachability check: `idefix` is only usable if it resolves to this symlink.
resolved="$(command -v idefix 2>/dev/null || true)"
if [ "$resolved" != "$BINDIR/idefix" ]; then
    echo
    echo "idefix: note: 'idefix' on PATH resolves to '${resolved:-nothing}', not this install." >&2
    case ":$PATH:" in
        *":$BINDIR:"*) ;;
        *) echo "idefix: $BINDIR is not on PATH." >&2 ;;
    esac
    echo "idefix: fix:  echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" >&2
    echo "idefix: or run directly: $BINDIR/idefix 'task'" >&2
else
    echo "next:      cd your-project && idefix 'fix the parser bug'"
fi
