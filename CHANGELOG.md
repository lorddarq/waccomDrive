# Changelog

## 0.1.6 — 2026-11-18

- Simplify perspective-circle editing to move, rotate, four deformation corners and radius, plus depth and cone scale when enabled. Remove the redundant global resize handle from ruler overlays; keep configuration on the Rulers page.
- Enclose the perspective circle with its deformation frame and keep corner controls nearby with collision clearance.
- Preserve cylinder/cone depth when moving, rotating, resizing or deforming the perspective circle; explain views with no visible side tangents.
- Recover Control-editing and picker shortcuts after missed key releases or disabled event listeners.
- Preserve small ordinary ellipse dimensions when releasing Control after resizing.

**Verification:** app/CLI builds, geometry and JSON self-checks, native overlay/picker checks, input-thread checks and captured-input replays passed. Includes the 0.1.5 stroke-start correction.

## 0.1.5 — 2026-11-17

- Fix wiggly stroke starts while automatic isometric, perspective or vanishing-line rulers acquire a direction. At 100% accuracy, the stroke stays at its pen-down point until an axis locks instead of drawing unprojected startup motion.
- Preserve partial-accuracy blending, exact zero-accuracy bypass, manual axis selection and existing acquisition calibration. Saved tablet mapping and proportions are unchanged.
- Add noisy Medium-tablet/wide-display regression traces across all three axis families and 0/50/100% accuracy, with family-lock and lift-cleanup checks.

**Distribution status:** Developer ID-signed installer built; notarization is pending because Apple returned HTTP 401 for the saved WaccomDrive profile.

**Verification:** automated app/CLI builds, capture replays and input-thread checks cover the fix. Physical drawing acceptance on the owner's Medium/wide-monitor setup remains pending.

## 0.1.4 — 2026-11-17

- Add an Advanced page with a shared **Advanced features** master switch, off by default; saved feature settings remain intact while bypassed.
- Add pulled-string position stabilization, advanced pressure modes and editable response curves, and pressure gain controlled by raw pen speed.
- Move tablet processing onto a dedicated input thread by default to keep drawing independent of UI stalls; retain an explicit main-thread option and delivery diagnostics.
- Add cross-app rulers: perspective, isometric, vanishing lines, radial lines, perspective ellipse, straight line, parallel lines, connected lines and ordinary ellipse, with adjustable snapping accuracy and guide appearance.
- Add Control-held guide editing, precise numeric geometry, keyboard movement/reset, and a Control–Option–R semicircular picker with direct 1–9 selection and ruler on/off.
- Extend construction tools with camera perspective, scene-line matching, measurements, boxes, depth ellipses, concentric rings, magnetic ticks and connected-stroke attachments.
- Save complete drawing profiles covering basic pressure and all advanced drawing settings. Add rename, duplicate, update, restore/defaults, Trash deletion and JSON import/export, while preserving older pressure/component profiles.
- Add profile selection/cycling through pen buttons and ExpressKeys, whole-profile activation at pen lift, display-aware ruler remapping and recovery copies for failed backup restores. Profiles preserve the Advanced master and device configuration.
- Expand geometry, JSON, replay, input-thread, held-button lifecycle and native UI checks. Existing settings are preserved during upgrade.

**Distribution status:** Developer ID-signed installer, notarized by Apple with its ticket stapled. Gatekeeper verification passed.

**Verification and limitations:** automated build/replay checks and native profile/ruler UI checks pass. Physical painting-app acceptance for the new straight/parallel/connected/ordinary ellipse modes and full-profile switching remains pending. Requires macOS 27 or later on Apple silicon.

## 0.1.3 — 2026-11-14

- Added a new application icon, including standard and Retina sizes so you can find the driver faster in spotlight search or raycast.
- Add Intuos Pro Medium PTH-651/K (056A:0315) detection, model-specific pen mapping, and receiver model selection.
- Reduce drawing lag by suspending background pen-preview updates and ignoring unchanged tablet-button reports.
- Show USB-powered tablets as Plugged in when no battery reading is available, hide the charging-status row. Apply the same power status in the menu bar.
- Add checks for Medium coordinates, receiver model switching, USB-power display states, and bundled application icons.

***Notes:***
- Tested alongside the official Wacom driver on the same mac. Did not detect any issue.

***Included in release:***
- Signed and notarized installer
- Uninstall script

## 0.1.2 — 2026-11-03

- Display the bundled driver version on Overview; keep tablet model and serial-number rows visible when device metadata is unavailable.
- Improve pen delivery with non-coalesced movement events, HID callbacks in common run-loop modes, and cached display mapping bounds. Smooth drawing confirmed in a live tablet test.
- Add adjustable pressure smoothing from 0–50 ms (12 ms default), with immediate reset on pen lift.
- Add custom pressure curves with light, medium, and firm input controls, numeric output entry, 0.1% steppers, and linear reset.
- Save curve and smoothing settings in local pressure profiles, backups, and profile cycling; retain compatibility with existing settings and profiles.
- Fix pressure-control layout and remove dense slider tick marks.
- Add regression checks for pressure curves, smoothing, and delivery of every point in a constant-pressure circle.

## 0.1.1 — 2026-10-30

- Reorganize Overview, Mapping, and tablet-button settings to reduce duplicated information and actions.
- Replace placeholder tablet previews with SVG artwork and add an Intuos Pro model image catalog.
- Show customized ExpressKeys in blue, highlight hovered rows on the tablet, and retain physical-press feedback.
- Match full-area mapping to the artwork surface and respect tablet rotation.
- Use the USB connector artwork when connected; simplify the disconnected indicator.
- Move live tilt readings to Pen and remove dense tip-threshold slider tick marks.
- Add a guided, manually confirmed HID capture tool for investigating other tablets and their capabilities.
- Bundle tablet and connector artwork with the installer and add native SVG rendering checks.
