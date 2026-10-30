#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
VERSION="${WACCOM_VERSION:-0.1.1}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "WACCOM_VERSION must be X.Y.Z." >&2; exit 2; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_BUNDLE="$ROOT_DIR/build/WaccomDrive.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/WaccomDrive"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$ROOT_DIR/build/module-cache"
# Keep a running build alive until compilation succeeds.
xcrun swiftc -swift-version 6 -warnings-as-errors -D APP -module-cache-path "$ROOT_DIR/build/module-cache" Sources/*.swift Sources/App/*.swift Sources/Views/*.swift -o "$ROOT_DIR/build/WaccomDrive.new"
xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$ROOT_DIR/build/module-cache" Sources/*.swift -o "$ROOT_DIR/build/waccom-capture.new"
mv "$ROOT_DIR/build/waccom-capture.new" "$ROOT_DIR/build/waccom-capture"
"$ROOT_DIR/build/waccom-capture" --self-check
xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$ROOT_DIR/build/module-cache" Sources/WacomReceiver.swift script/check_tablet_hardware.swift -o "$ROOT_DIR/build/check-tablet-hardware"
xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$ROOT_DIR/build/module-cache" Sources/Pen.swift Sources/PenOutput.swift Sources/ButtonMapper.swift Sources/Touch.swift Sources/TabletPowerStatus.swift Sources/WacomReceiver.swift Sources/WirelessStatus.swift Sources/TabletSession.swift Sources/Settings.swift Sources/PressureProfile.swift script/check_wireless.swift -o "$ROOT_DIR/build/check-wireless"
"$ROOT_DIR/build/check-wireless" captures/wireless-receiver.txt
"$ROOT_DIR/build/check-tablet-hardware"
"$ROOT_DIR/build/waccom-capture" --replay=captures/first-session-excerpt.txt
"$ROOT_DIR/build/waccom-capture" --replay=captures/touch-ring.txt
"$ROOT_DIR/build/waccom-capture" --replay=captures/touch-surface-retry.txt
# Gracefully quit the previous GUI so it releases mapped buttons.
if pgrep -x WaccomDrive >/dev/null; then
    osascript -e 'tell application id "local.waccomDrive" to quit'
fi
mv "$ROOT_DIR/build/WaccomDrive.new" "$APP_BINARY"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WaccomDrive</string>
<key>CFBundleIdentifier</key><string>local.waccomDrive</string>
<key>CFBundleName</key><string>WaccomDrive</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Resources/assets"
cp -R "$ROOT_DIR/assets/tablet" "$ROOT_DIR/assets/connection" "$ROOT_DIR/assets/battery" "$APP_BUNDLE/Contents/Resources/assets/"
cp "$ROOT_DIR/packaging/Uninstall WaccomDrive.command" "$APP_BUNDLE/Contents/Resources/Uninstall WaccomDrive.command"
"$ROOT_DIR/script/sign.sh" "$APP_BUNDLE"
case "$MODE" in
    --build) exit 0 ;;
    run) open -n "$APP_BUNDLE" ;;
    --verify|verify) open -n "$APP_BUNDLE"; sleep 1; pgrep -x WaccomDrive >/dev/null ;;
    --debug|debug) lldb -- "$APP_BINARY" ;;
    --logs|logs) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "WaccomDrive"' ;;
    --telemetry|telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.waccomDrive"' ;;
    *) echo "usage: $0 [run|--build|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
