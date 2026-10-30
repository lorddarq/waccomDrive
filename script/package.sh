#!/usr/bin/env bash
set -euo pipefail
MODE="${1:---local}"
[[ "$MODE" == --local || "$MODE" == --release || "$MODE" == --signed-app ]] || { echo "usage: $0 [--local|--signed-app|--release]" >&2; exit 2; }
NOTARY_OPTIONS=(--keychain-profile "${WACCOM_NOTARY_PROFILE:-}")
if [[ -n "${WACCOM_NOTARY_KEYCHAIN:-}" ]]; then NOTARY_OPTIONS+=(--keychain "$WACCOM_NOTARY_KEYCHAIN"); fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
INSTALLER_IDENTITY="${WACCOM_INSTALLER_IDENTITY:-$(security find-identity -v | awk '/Developer ID Installer:/ {print $2; exit}')}"
if [[ "$MODE" == --release && -z "$INSTALLER_IDENTITY" ]]; then
    echo 'Release packaging needs a Developer ID Installer certificate (WACCOM_INSTALLER_IDENTITY).' >&2
    exit 1
fi
./script/build_and_run.sh --build
APP="$ROOT_DIR/build/WaccomDrive.app"
if [[ "$MODE" != --local ]]; then ./script/sign.sh --distribution "$APP"; fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUTPUT="$ROOT_DIR/build/installer"
mkdir -p "$OUTPUT"
STAGE="$(mktemp -d "$ROOT_DIR/build/pkg-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/payload/Applications" "$STAGE/resources"
COVER=cover.png
if [[ "$MODE" == --local ]]; then COVER=cover-dev.png; fi
if [[ "$MODE" == --signed-app ]]; then
    if [[ -n "${WACCOM_NOTARY_PROFILE:-}" ]]; then
        ditto -c -k --keepParent "$APP" "$STAGE/notary-input.zip"
        xcrun notarytool submit "$STAGE/notary-input.zip" "${NOTARY_OPTIONS[@]}" --wait
        xcrun stapler staple "$APP"
        xcrun stapler validate "$APP"
        spctl --assess --type execute --verbose=2 "$APP"
    fi
    ditto -c -k --keepParent "$APP" "$OUTPUT/WaccomDrive-$VERSION-macOS-arm64.zip"
fi
ditto "$APP" "$STAGE/payload/Applications/WaccomDrive.app"
codesign --verify --strict "$STAGE/payload/Applications/WaccomDrive.app"
pkgbuild --analyze --root "$STAGE/payload" "$STAGE/components.plist"
/usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$STAGE/components.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsVersionChecked false' "$STAGE/components.plist"
pkgbuild --root "$STAGE/payload" --component-plist "$STAGE/components.plist" --identifier local.waccomDrive.pkg --version "$VERSION" --install-location / --ownership recommended --scripts packaging/scripts "$STAGE/component.pkg"
cat > "$STAGE/distribution.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<installer-gui-script minSpecVersion="2">
    <title>WaccomDrive</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check script="true"><allowed-os-versions><os-version min="27.0"/></allowed-os-versions></volume-check>
    <welcome file="Welcome.rtfd" mime-type="text/rtfd"/>
    <readme file="ReadMe.txt" mime-type="text/plain"/>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" visible="false"><pkg-ref id="local.waccomDrive.pkg"/></choice>
    <pkg-ref id="local.waccomDrive.pkg">component.pkg</pkg-ref>
    <pkg-ref id="local.waccomDrive.pkg"><must-close><app id="local.waccomDrive"/></must-close></pkg-ref>
</installer-gui-script>
XML
# A single-file RTFD embeds a native image attachment and works with productbuild.
swift -module-cache-path "$ROOT_DIR/build/module-cache" "$ROOT_DIR/script/installer_welcome.swift" "$ROOT_DIR/previews/$COVER" "$STAGE/resources/Welcome.rtfd"
cat > "$STAGE/resources/ReadMe.txt" <<'TEXT'
WaccomDrive — Wacom Intuos Pro Large PTH-851/K USB driver

Requires macOS 27 or later on Apple silicon.

Quit any running WaccomDrive instance before installing. This package installs WaccomDrive.app in Applications. It preserves your saved settings and does not replace Apple's system drivers or install a kernel extension.

After installation, open WaccomDrive from Applications. Grant Input Monitoring and Accessibility to the installed app, then choose Start driver. Settings offers Start at login and Uninstall.

Uninstall is also available using the companion Uninstall WaccomDrive.command. Saved settings are kept by default.
TEXT
SUFFIX=local
if [[ -n "$INSTALLER_IDENTITY" ]]; then SUFFIX=signed; fi
PACKAGE="$OUTPUT/WaccomDrive-$VERSION-$SUFFIX.pkg"
if [[ -n "$INSTALLER_IDENTITY" ]]; then
    productbuild --distribution "$STAGE/distribution.xml" --resources "$STAGE/resources" --package-path "$STAGE" --sign "$INSTALLER_IDENTITY" --timestamp "$PACKAGE"
else
    productbuild --distribution "$STAGE/distribution.xml" --resources "$STAGE/resources" --package-path "$STAGE" "$PACKAGE"
fi
cp 'packaging/Uninstall WaccomDrive.command' "$OUTPUT/Uninstall WaccomDrive.command"
chmod +x "$OUTPUT/Uninstall WaccomDrive.command"
python3 script/check_package.py "$PACKAGE" "$MODE"
if [[ -n "$INSTALLER_IDENTITY" ]]; then pkgutil --check-signature "$PACKAGE"; fi
if [[ "$MODE" == --release && -n "${WACCOM_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$PACKAGE" "${NOTARY_OPTIONS[@]}" --wait
    xcrun stapler staple "$PACKAGE"
    xcrun stapler validate "$PACKAGE"
    spctl --assess --type install --verbose=2 "$PACKAGE"
fi
echo "Package: $PACKAGE"
if [[ -z "$INSTALLER_IDENTITY" ]]; then echo 'The app is signed; the local installer package is unsigned (no Developer ID Installer certificate found).'; fi
if [[ "$MODE" == --release && -z "${WACCOM_NOTARY_PROFILE:-}" ]]; then echo 'Signed release package created; notarization was not requested. Set WACCOM_NOTARY_PROFILE to submit.'; fi

if [[ "$MODE" == --signed-app && -z "${WACCOM_NOTARY_PROFILE:-}" ]]; then echo 'App signed for distribution; notarization was not requested. Set WACCOM_NOTARY_PROFILE to submit.'; fi
