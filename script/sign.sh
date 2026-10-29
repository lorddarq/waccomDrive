#!/usr/bin/env bash
set -euo pipefail
DISTRIBUTION=false
if [[ "${1:-}" == --distribution ]]; then DISTRIBUTION=true; shift; fi
[[ $# == 1 && -d "$1/Contents" ]] || { echo "usage: $0 [--distribution] path/to/WaccomDrive.app" >&2; exit 2; }
APP="$1"
if $DISTRIBUTION; then
    IDENTITY="${WACCOM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application:/ {print $2; exit}')}"
    [[ -n "$IDENTITY" && "$IDENTITY" != - ]] || { echo "Distribution requires a Developer ID Application certificate." >&2; exit 1; }
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    IDENTITY="${WACCOM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application:|Apple Development:/ {print $2; exit}')}"
    if [[ -z "$IDENTITY" ]]; then
        echo "No signing certificate found; using ad hoc signing. Rebuilds may need privacy permissions again." >&2
        IDENTITY=-
    fi
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
if $DISTRIBUTION; then
    DETAILS="$(codesign -dvv "$APP" 2>&1)"
    [[ "$DETAILS" == *"Authority=Developer ID Application:"* && "$DETAILS" == *"Timestamp="* ]] || {
        echo "Distribution signature must have a Developer ID Application authority and secure timestamp." >&2; exit 1;
    }
fi
