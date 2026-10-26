#!/usr/bin/env bash
# Points the Homebrew cask (banastas/homebrew-tap) at the newest release and
# pushes the tap. Run after scripts/deploy-site.sh.
#
#   scripts/update-cask.sh
#
# Expects the tap checked out at ../homebrew-tap (override with TAP_DIR).
set -euo pipefail
cd "$(dirname "$0")/.."

TAP_DIR=${TAP_DIR:-../homebrew-tap}
CASK=$TAP_DIR/Casks/flatline.rb
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -f $CASK ]] || fail "no cask at $CASK; clone banastas/homebrew-tap there or set TAP_DIR"
VERSION=$(awk '/MARKETING_VERSION:/ { print $2; exit }' project.yml)
DMG=releases/flatline-$VERSION.dmg
[[ -f $DMG ]] || fail "$DMG is missing; run scripts/release.sh first"

# Homebrew checks the download against this checksum, so it must describe the
# file that is actually published.
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
LIVE=$(curl -fsSL "https://flatline.banast.as/releases/flatline-$VERSION.dmg" | shasum -a 256 | cut -d' ' -f1)
[[ $LIVE == "$SHA" ]] || fail "the published $VERSION DMG doesn't match $DMG; run scripts/deploy-site.sh first"

sed -i '' -E \
    -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
    "$CASK"

if git -C "$TAP_DIR" diff --quiet; then
    echo "==> cask already at $VERSION"
    exit 0
fi
git -C "$TAP_DIR" commit -qam "flatline $VERSION"
git -C "$TAP_DIR" push -q origin main
echo "==> cask updated to flatline $VERSION"
