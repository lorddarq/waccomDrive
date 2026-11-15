# Changelog

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
