#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
command -v python3 >/dev/null || { echo 'Python 3 is required.' >&2; exit 1; }
command -v xcrun >/dev/null || { echo 'Apple Command Line Tools are required (xcode-select --install).' >&2; exit 1; }
mkdir -p build/module-cache
# Build just the diagnostic executable; do not launch or replace the GUI app.
xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path build/module-cache Sources/*.swift -o build/waccom-capture.new
mv build/waccom-capture.new build/waccom-capture
exec python3 script/capture_tablet.py "$@"
