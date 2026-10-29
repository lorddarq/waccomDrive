#!/bin/bash
set -euo pipefail
APP="/Applications/WaccomDrive.app"
BUNDLE_ID="local.waccomDrive"
RECEIPT="local.waccomDrive.pkg"
REMOVE_SETTINGS=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --remove-settings) REMOVE_SETTINGS=true ;;
        --dry-run) DRY_RUN=true ;;
        *) echo "usage: $0 [--dry-run] [--remove-settings]" >&2; exit 2 ;;
    esac
done
if [[ $EUID == 0 ]]; then
    echo "Run this as your normal macOS user. It requests sudo only to remove the installed app and receipt." >&2
    exit 1
fi
SETTINGS="$HOME/Library/Application Support/WaccomDrive"
PREFERENCES="$HOME/Library/Preferences/local.waccomDrive.plist"
if [[ -e "$APP" || -L "$APP" ]]; then
    [[ ! -L "$APP" ]] || { echo "Refusing to uninstall a symbolic-link app." >&2; exit 1; }
    ACTUAL_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
    [[ "$ACTUAL_ID" == "$BUNDLE_ID" ]] || { echo "The installed app has a different identifier; nothing was removed." >&2; exit 1; }
fi
if $DRY_RUN; then
    echo "Would unregister this user's WaccomDrive login item, stop the installed app, and remove $APP and receipt $RECEIPT."
    if $REMOVE_SETTINGS; then echo "Would also remove this user's WaccomDrive settings and preferences."
    else echo "Would preserve this user's settings and preferences."; fi
    exit 0
fi
if [[ ! -d "$APP" ]]; then echo "WaccomDrive is not installed at $APP. Nothing was removed."; exit 0; fi
printf 'Uninstall WaccomDrive from /Applications? '
if $REMOVE_SETTINGS; then printf 'Your saved settings will also be removed. '; else printf 'Saved settings will be kept. '; fi
printf '[y/N] '
read -r ANSWER
[[ "$ANSWER" == y || "$ANSWER" == Y ]] || exit 0
# Disable login startup in the owning user's session before removing its executable.
"$APP/Contents/MacOS/WaccomDrive" --unregister-login
if pgrep -x WaccomDrive >/dev/null; then
    /usr/bin/osascript -e 'tell application id "local.waccomDrive" to quit'
fi
for attempt in {1..20}; do
    if ! pgrep -x WaccomDrive >/dev/null; then break; fi
    sleep 0.1
done
if pgrep -x WaccomDrive >/dev/null; then
    echo "WaccomDrive is still running. Quit it and retry; nothing was deleted." >&2; exit 1
fi
# Only these fixed system paths are removed with administrator privileges.
sudo /bin/rm -rf -- "$APP"
if /usr/sbin/pkgutil --pkg-info "$RECEIPT" >/dev/null 2>&1; then sudo /usr/sbin/pkgutil --forget "$RECEIPT"; fi
if $REMOVE_SETTINGS; then
    /bin/rm -rf -- "$SETTINGS"
    if [[ -e "$PREFERENCES" ]]; then /usr/bin/defaults delete "$BUNDLE_ID"; fi
fi
echo "WaccomDrive uninstalled. macOS privacy entries can be removed manually in Privacy & Security."
