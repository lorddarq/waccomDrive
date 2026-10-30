#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/waccom-artwork.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
CHECK_APP="$CHECK_DIR/ArtworkCheck.app/Contents"
mkdir -p "$CHECK_APP/MacOS" "$CHECK_APP/Resources/assets"
cp -R "$ROOT_DIR/assets/tablet" "$ROOT_DIR/assets/connection" "$ROOT_DIR/assets/battery" "$CHECK_APP/Resources/assets/"
xcrun swiftc -D APP -swift-version 6 -warnings-as-errors -module-cache-path "$ROOT_DIR/build/module-cache" \
    "$ROOT_DIR/Sources/Views/TabletArtwork.swift" "$ROOT_DIR/script/check_tablet_artwork.swift" \
    -o "$CHECK_APP/MacOS/ArtworkCheck"
"$CHECK_APP/MacOS/ArtworkCheck"
