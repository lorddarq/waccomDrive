# Guided tablet report capture

Run from Terminal in the project folder:

```sh
./script/capture_tablet.command
# Optional new output directory:
./script/capture_tablet.command --output "$HOME/Desktop/wacom-capture"
```

- Requires macOS, Apple's Command Line Tools with Swift 6, and Python 3. No Python packages are needed.
- The launcher builds only the diagnostic executable, then starts the guide. It does not launch, install, or modify the driver app.
- Quit WaccomDrive and other tablet drivers before collecting reports. Connect or pair the tablet normally.
- Allow Input Monitoring for the terminal/capture tool if macOS requires it, then rerun. Accessibility is not required: the recorder never posts input events.
- Discovery covers Wacom HID vendor `056A` on every transport exposed by macOS, including models the driver cannot decode. Select the tablet and its receiver by their displayed product IDs. All interfaces with selected IDs are recorded; disconnect duplicate tablets with the same ID to isolate one.
- Enter the printed model label, number of ExpressKeys, number of rings/dials/strips, and pen side-button count. Zero means no controls configured for that category; it does not prove the hardware lacks them.

## Manual steps

- Every step shows its full action list before recording starts.
- Press Enter to start; perform all actions; press Enter to stop. Recording has no time limit.
- Explicitly choose **y** to confirm every listed action was completed, **r** to repeat, **a** to report not available, or **s** to skip. Empty confirmation answers are rejected.
- An unavailable/skipped step chosen before recording also requires a separate yes/no confirmation and notes.
- **d** rescans for new tablet/receiver identities and repeats the step. New product IDs are added to the original set, so USB reconnection remains capturable.
- **q** ends with a partial session. Ctrl-C preserves completed steps and partial recordings. Repeated attempts are retained separately.
- Failed or incomplete recordings cannot be marked complete. A step with zero reports can be user-confirmed, but remains insufficient evidence of hardware support.

The guide includes quiet category baselines; touch switch, single/multiple fingers, scrolling, pinch, rotation, palm and pen interaction; individual ExpressKeys; each dial/ring/strip's motion, contact and push/mode controls; pen proximity, area, pressure, tilt, rotation, eraser and individual side buttons; wireless transitions/reconnection; and battery/charging observations. Unsupported actions can be marked not available. Do not dismantle the tablet to check a battery or module.

## Saved files

The default is a unique folder under `captures/session-<UTC date>-<suffix>/`, ignored by Git. Existing output directories are never overwritten.

- `device.json`: advertised identity, USB IDs, transports, interfaces, raw report descriptors, HID element ranges/units, exposed power properties, descriptor capability evidence, and separate user-reported label/control counts.
- `session.json`: step instructions, statuses, timestamps, explicit confirmations, notes, selected product IDs, rescans, errors, and recording statistics.
- `summary.txt`: readable step outcomes.
- `<step>-attempt-<number>.txt`: newline-delimited JSON text. Input records contain host UTC time, monotonic elapsed microseconds, interface identity, report type/ID, payload length, and space-separated raw hex bytes. Other records describe connection/removal, readiness, errors, shutdown, and periodic device status.
- Matching `-stderr.txt` files preserve diagnostic errors. They are normally empty.
- `rescan-*.json`: device inventory when a wireless or reconnecting device exposes another product ID.

Raw records are independent of the Large tablet decoder. These files use a new metadata-rich format; the legacy `--replay` command does not consume them.

## Capability limits

- **Advertised** capabilities come from standard HID usages; vendor-defined descriptors often hide capabilities. Missing usages remain **unknown**.
- **Observed** evidence includes raw reports, their IDs/counts, transport changes, and available status properties. User confirmation records actions performed, not successful driver/application behavior.
- Battery properties and the selected interfaces' transports are sampled every two seconds while recording. Missing properties do not establish an absent battery or lack of Bluetooth support.
- Wireless recording does not initiate pairing or sniff Bluetooth radio traffic. Pair through macOS or use the appropriate receiver. Native Bluetooth, receiver presence, and USB are distinct observations.
- Collection is passive and nonexclusive: no feature/output commands, mode switches, synthetic input, or firmware writes are sent. Consequently, devices that need protocol initialization may expose no useful reports. Input reports and descriptors can be collected; outgoing commands and arbitrary feature-report polling are not intercepted.
- Serial numbers are not explicitly collected, but raw payloads may contain identifying data. Review the folder before sharing. Nothing is uploaded automatically.
- Capturing an unknown model does not add driver support for it.

## Checks and direct commands

```sh
python3 script/check_capture_wizard.py
build/waccom-capture --hid-inventory
build/waccom-capture --hid-record --products=0317,0084 > /tmp/wacom-input.txt
```

The check uses a clearly simulated recorder and does not access hardware. The direct raw command stops on Ctrl-C; use the wizard for guided, confirmed steps.
