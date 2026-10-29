# WaccomDrive

A native macOS driver and settings app for the Wacom Intuos Pro Large PTH-851/K over direct USB. Developed on macOS 27.0.1 / Apple silicon with Swift 6.4. No third-party dependencies or kernel extension.

## Build and open

```sh
./script/build_and_run.sh
```

The Codex **Run** action uses the same script. It builds both executables, runs the checks, signs `build/WaccomDrive.app`, and opens it as a macOS app. Other modes: `--build`, `--verify`, `--debug`, `--logs`, `--telemetry`.


## Signing your build

Install a signing certificate **and its private key** in your macOS Keychain. List available application identities with `security find-identity -v -p codesigning`, then build using your own identity:

```sh
WACCOM_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)' ./script/build_and_run.sh --build
# For distribution outside the App Store, use Developer ID Application:
WACCOM_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./script/build_and_run.sh --build
```

The build automatically selects an available Developer ID Application or Apple Development identity when no override is supplied. Without one it falls back to **ad hoc signing**. To explicitly build locally without an Apple certificate:

```sh
WACCOM_SIGN_IDENTITY=- ./script/build_and_run.sh --build
```

Ad hoc signing is not a stable developer identity. Rebuilding can invalidate saved Input Monitoring and Accessibility approvals: the app may launch but fail to read the tablet or post pen, pointer, and shortcut events until you remove the old privacy entry, add the rebuilt app, and relaunch. Use the same certificate and bundle identifier across builds to help macOS recognize updates. Changing identities can also require renewed approval. See [Apple's code identity explanation](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

Signing never grants permissions automatically. WaccomDrive still needs **Input Monitoring** to read tablet reports and **Accessibility** to post events. This is a user-space app, so no kernel-extension approval is needed. Truly unsigned builds are not provided by the build script; use its ad hoc fallback for local development.

To create a distribution-signed app ZIP or installer:

```sh
# Requires Developer ID Application:
WACCOM_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./script/package.sh --signed-app
# A signed installer additionally requires Developer ID Installer:
WACCOM_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
WACCOM_INSTALLER_IDENTITY='Developer ID Installer: Your Name (TEAMID)' \
./script/package.sh --release
```

Certificate signing alone does not ensure downloaded builds pass default Gatekeeper checks. Public distribution also requires Apple's notarization process; see [Apple's distribution requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Keep private keys, certificate exports, and credentials outside the repository.

## Window and status bar

- **Overview:** USB, tablet wireless-module presence, battery percentage and charging state, Wacom receiver presence, Mac Bluetooth radio status (choose Check), and live pressure/tilt/proximity.
- **Mapping:** display selection with stable UUIDs, main-display fallback, proportional mapping, 180° rotation, and tablet active-area controls.
- **Pen:** pressure sensitivity curve, live response preview, tip activation threshold, and two side-button action pickers.
- **Touch:** saved surface on/off, pen-range palm rejection, tap-to-click, pointer speed, and live contact/suppression status.
- **Tablet buttons:** eight ExpressKeys and the ring center switch, with a numbered tablet diagram. Selecting a diagram key or row targets that key; hovering a row previews its location. Physical presses light up green. The diagram shows buttons on the left. Physical ordering still needs verification against hardware.
- **Settings:** Save & Apply, backup of saved settings, validated import for review, restore defaults, and Show in Finder.
- **Help:** explains the two macOS permissions, why each is needed, exact setup steps, direct settings actions, and recovery for stale permission entries. Short input/accessibility status messages link here through Permission Help.
- **Status-bar menu:** Open Settings, USB/driver status, Start/Pause Driver, and Quit. The app runs as a menu-bar utility (`LSUIElement`) without a Dock icon. Closing the single settings window leaves the app running. Quit releases held inputs and stops HID monitoring.

Actions: no action, right/middle mouse, Undo/Redo, B/E, Space, Shift, Option, Command, Control. Held mappings release on release/disconnect/pause/settings change/quit; shortcuts run once per press. Two controls assigned the same action share its held state. Ring rotation changes brush size using [ and ] shortcuts, with enable, reverse-direction, and response-speed controls. Arbitrary shortcut recording is not implemented.

## Permissions and first run

The GUI starts paused unless you previously quit with driver output active. Allow **WaccomDrive** in System Settings → Privacy & Security → **Input Monitoring** for tablet reads and **Accessibility** for event posting. Codex's permissions do not substitute for the standalone app's permissions. Open **Permission Help**, choose **Open Input Monitoring Settings**, then return to the app or choose Retry USB. Start Driver requests event-posting access if needed.

HID opening is the access source of truth. `IOHIDCheckAccess` is not used as a gate: a broad listen-event precheck incorrectly prevented attempts to open the tablet. If macOS retains an outdated privacy entry after rebuilding, remove the previous WaccomDrive entry and re-add `build/WaccomDrive.app`, then relaunch/retry.

Only one driver instance should post events. The previous command-line prototype may still be running during development; stop it before starting GUI output to avoid duplicate input. No other tablet driver is removed or disabled.

## Settings

Saved settings live in `~/Library/Application Support/WaccomDrive/settings.json`. Save & Apply validates and atomically writes before changing the active driver configuration. Failed saves preserve the last active settings. Backup exports saved settings as JSON. Import checks version, required fields, array lengths, finite numeric ranges, display identifiers, and file size; it loads a draft without overwriting saved settings. Save & Apply activates the imported draft.

Default pressure is linear and default mapping preserves the owner-tested prototype. Sensitivity changes the pressure curve; activation threshold remains a separate calibration control. Display removal safely releases held inputs and falls back to the main display.

## Wireless and Bluetooth

USB status reports identify whether the tablet's wireless module is installed and report its battery level and charging state. These readings appear in Overview and the status-bar menu; they clear on disconnect or after 30 seconds without a status report. Missing or reserved battery readings remain unknown. Captured tablet reports exercise module detection, battery conversion, and charging in the runnable self-check and replay checks.

The PTH-851 uses the [Wacom wireless accessory kit](https://support.wacom.com/hc/en-us/articles/1500006340602-What-is-the-Wacom-Wireless-Accessory-kit-ACK40401), with a USB receiver. The app distinguishes receiver presence from Bluetooth radio power. It does not claim that Bluetooth power means the tablet is connected. Wireless pen delivery remains unimplemented. Surface touch supports one-finger pointer/tap and two-finger scrolling; advanced trackpad gestures such as pinch/rotate are not implemented.

## Command-line diagnostic

```sh
build/waccom-capture --probe
build/waccom-capture | tee /tmp/waccom-raw.txt
build/waccom-capture --decode | tee /tmp/waccom-decoded.txt
build/waccom-capture --drive --threshold=10
build/waccom-capture --self-check
build/waccom-capture --replay=captures/first-session-excerpt.txt
```

Hardware commands need execution outside Codex's tool sandbox. Both GUI and CLI reuse `TabletSession`, `PenDecoder`, and `PenOutput`. The GUI adds saved configuration and button mappings; the CLI uses neutral defaults. SIGINT/SIGTERM, disconnect, proximity exit, and a one-second pen-report timeout release the tip. Forced termination cannot run cleanup.

## Verification and limits

- Swift 6 build with warnings as errors; decoding/event lifecycle checks and 527-sample replay pass.
- Runnable settings/button checks cover JSON round-trip, rejected writes/imports preserving existing data, geometry, rotation/aspect mapping, sensitivity bounds, pad switch parsing, deduplicated held actions, shortcut edges, and modifier cleanup. Checks post no events and use temporary settings files.
- Initial USB prototype: owner tested Krita and reported “works perfect” on 2026-10-29. This predates the settings UI and mapped actions; those changes need renewed drawing-app acceptance.
- Live USB probe detects three interfaces at `056A:0317`, advertising `Intuos5 touch L`.
- UI inspected: mapping, sensitivity, pen/ExpressKey controls, and target diagram. Native backup/export and import-for-review completed successfully with a temporary JSON file.
- GUI launches and now reports USB connected after authorization. No claim of renewed live GUI drawing acceptance or physical ExpressKey order validation is made.

The first capture excerpt is incomplete because terminal output was truncated. It contains 527 general pen samples, with observed pressure 0–1769 and tilt X -3–12 / Y -8–19; these are observations, not calibration limits. `captures/pen-buttons.txt` has 1418 decoded samples: both side buttons press/release in hover, and button bit 1 during contact. Eraser tool `1080a` appeared in later live logs. Separate tilt-specific brush behavior and live cleanup acceptance remain open.

## References

- [Apple IOHIDManager](https://developer.apple.com/documentation/iokit/1438383-iohidmanagercreate)
- [Apple CoreGraphics event fields](https://developer.apple.com/documentation/coregraphics/cgeventfield)
- [PTH-851 device configuration](https://github.com/hawku/TabletDriver/blob/master/TabletDriverService/config/wacom.cfg)
- [Linux Wacom protocol reference](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_wac.c): wire fields and proximity/pad packet meanings. No platform driver code is vendored.

## Install and uninstall

Build the local installer without installing anything:

```sh
./script/package.sh --local
```

Open the generated `.pkg` in `build/installer/` and follow macOS Installer. It installs the app at `/Applications/WaccomDrive.app`, requires macOS 27 / Apple silicon, and asks you to close the app before an upgrade. Bundle relocation is disabled so Installer cannot choose the development checkout as an upgrade destination. Existing settings are preserved. Open the installed app, grant its input/event permissions as needed, and use **Settings → Start at login** to register the native login item. No root daemon or kernel extension is installed. An active driver resumes on later app launches if access is already granted; pausing it disables that resume behavior.

The companion `build/installer/Uninstall WaccomDrive.command` or **Settings → Uninstall WaccomDrive…** opens the Terminal uninstaller. It asks for confirmation, unregisters the current user's login item, quits the app, requests administrator authentication to remove the fixed Applications bundle and package receipt, and preserves settings by default. It refuses symbolic-link/unrelated app destinations. Run it as your normal user, not under sudo.

```sh
# Read-only preview:
bash 'build/installer/Uninstall WaccomDrive.command' --dry-run
# Also remove your saved settings/preferences during uninstall:
bash 'build/installer/Uninstall WaccomDrive.command' --remove-settings
```

Other users' saved settings and macOS-managed privacy entries are not deleted. Other users can remove their own stale login/privacy entries if necessary.

Read-only package verification can be repeated with:

```sh
python3 script/check_package.py build/installer/WaccomDrive-0.1.0-local.pkg
```

It expands a temporary copy, verifies the embedded app signature and uninstall resource, checks OS/architecture/install destination requirements, exercises destination guards against temporary unrelated/symlink apps, and invokes only the uninstaller's dry-run path. Build checks still cover pen replay, settings, and button lifecycles.

Packaging verification: macOS Installer successfully parsed the final product archive against the startup volume in read-only `-showChoicesXML` mode. The development UI correctly disables installed-only startup/uninstall actions. The full system install, login launch, and destructive uninstall remain untested.

## GitHub Actions

GitHub Actions are not published for now: `.github/` is ignored, so sharing this source does not enable automatic builds. Local build and packaging scripts remain part of the source.

## Touch-ring brush size

`captures/touch-ring.txt` records 210 real pad reports, eight touch gestures, positions 0–71, wraparound in both directions, finger lifts, and center-button press/release. The shared button mapper turns relative ring motion into paired [ / ] key events, reusing the same smaller/larger brush actions available for pen and ExpressKey mappings. Clockwise is larger by default; reverse direction is available. This requires the active drawing app's brush-size shortcuts to use those bracket keys.

In **Tablet buttons → Touch ring**, enable brush size control, adjust Slow/Fast response, optionally reverse direction, then **Save & Apply**. The ring's center switch retains its independent assignment. New/legacy settings default to enabled, normal direction, one shortcut per three ring positions; existing version-1 backups remain readable through optional ring configuration. Response is a physical calibration control, validated on import.

First touch only establishes a baseline; release, pause, settings changes, or disconnect clear it. Shortest signed distance handles the 71↔0 boundary. Ambiguous half-turn jumps are ignored. Tests cover clockwise/counterclockwise wraparound, contact release, repeated positions, reversal, response scaling, disabled behavior, reset, invalid positions/configuration, and settings round-trip/legacy decoding. The captured pad reports also replay through the same session path with event posting disabled:

```sh
build/waccom-capture --replay=captures/touch-ring.txt
```

Physical brush-size response in Krita still needs owner acceptance after this change; packet capture and event checks alone do not prove drawing-app delivery.

## Surface touch and palm rejection

The completed `captures/touch-surface-retry.txt` capture contains 2804 surface reports and 3976 pen reports; decoding sees up to three contacts and replays 3466 identified pen samples. The tablet presents an FF00/usage-1/64-byte surface interface separate from the FF0D pen/pad interface and compatibility mouse interface. A live test confirmed that closing/reopening only the touch handle with Apple's exclusive-open option succeeds, continues receiving surface reports, and can return to shared access.

While the driver is active, it claims the surface interface exclusively. **Touch → Enable surface touch** is off by default; turning it on provides relative one-finger pointer movement, short tap-to-click, and two-finger scrolling. **Block touch while the pen is in range** is on by default and suppresses all surface output beginning at the pen's entry/range report, before tip contact. Existing fingers/palms must lift before touch resumes after the pen leaves. The ring and ExpressKeys remain independent of surface touch.

Touch controls, calibration speed, and palm rejection participate in Save & Apply, backup, and validated import. Older backups load the new defaults without losing prior settings. Keep the hardware touch switch on to use surface input. Pausing/quitting releases the touch interface; this app cannot enforce rejection while it is stopped. If exclusive control fails, no surface events are posted and the UI reports **Touch control unavailable** rather than claiming that other clients' touch is blocked.

The driver rejects three-or-more-contact gestures, resets baselines when contact identities change, and never turns a pre-existing contact into a tap after a setting change or pen exit. A stale pen report timeout releases the tip but conservatively keeps touch blocked until explicit pen state returns. Finger size is not used as an unverified palm-classification heuristic.

Checks cover captured contact parsing, per-slot releases, ignored status messages, malformed lengths, independent pen range/proximity, surface disabled/uncontrolled states, pen-entry suppression, lift-to-resume, pointer/scroll/tap generation, and settings compatibility. Replay uses the same session path without posting events:

```sh
build/waccom-capture --replay=captures/touch-surface-retry.txt
```

The running app acquired the touch interface, and the Touch page was visually checked through saved Off → On → Off transitions; it was left Off. Actual pointer/scroll/palm behavior still needs owner testing in the drawing app. Multi-finger OS trackpad gestures and full gesture customization are outside this first surface-touch implementation.
