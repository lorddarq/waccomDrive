# Changelog

## 0.1.2 — 2026-11-03

- Display the bundled driver version on Overview.
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
