
## Interaction acceptance targets

- [ ] Manipulate guides directly over the painting application, without visiting
  driver settings for each adjustment. Retain numeric controls for precise entry.
- [x] Update guide geometry continuously during a drag, using a temporary preview;
  validate and commit at gesture end. Invalid geometry must not enter snapping.
- [ ] Distinguish move, rotate, size/axis, corner and edge operations with handle
  appearance, cursor/hover feedback and concise accessible names.
- [ ] Use subtle colored guide families and a clear active direction. Keep handle
  clutter out of normal drawing while preserving predictable access to editing.
- [ ] Show the relevant construction through the stroke's anchor/cursor, rather
  than relying only on static fans of lines from vanishing points.
- [ ] Keep repeated/concentric ellipse adjustments and plane-preserving movement
  available on screen. Preserve projective geometry, not just screen translation.
- [ ] Provide guide hide/show so the artwork can be inspected without changing
  geometry or leaving the drawing app.
- [ ] Preserve immediate lift and stable direction/branch selection. Overlay
  previews remain on the UI thread; HID processing stays on its dedicated owner
  loop and must not wait for rendering.
- [ ] Repeat the established combined ruler/string/pressure timing comparison
  during editing and drawing. Frame sampling of references does not provide a
  quantitative latency target.

## Current implementation and remaining gaps

A small canvas bar now provides ruler selection and Edit ruler / Done directly
over the painting app. Pen taps on the bar and its popup menu bypass positional
filters; a drawing stroke that passes across it retains its original filtering.
The numeric driver page and menu bar remain secondary entry points.

`Sources/App/RulerOverlay.swift` now retains windows/layers during live previews
at up to 60 Hz. Valid geometry commits on release; invalid/cancelled gestures
leave saved settings unchanged. Move/rotate, individual points, ellipse edges and
uniform-size handles have distinct symbols, hover feedback and accessible names.
Isometric orientation is independent of its axis angle. Off-screen proxies are
spaced apart. The menu bar can show/hide guides without changing snapping.

These changes passed deterministic geometry and native preview/window checks;
physical pointer/pen editing still needs acceptance. Control now temporarily reveals
editing handles while lifted; releasing it restores drawing after any active drag
ends. Isometric and perspective use three (or configured VP-count) cursor-following
axes instead of dense static grids, anchored to the input stroke origin during
contact. Vanishing Lines retains its fixed fans. The canvas bar remains a fallback. Ordinary ellipse and fisheye families, richer projective plane movement,
measurement/grid controls, active-direction feedback, additional keyboard controls and
repeated/concentric workflows remain unfinished.

Next validate the editing experience over painting apps, then continue the
priority-family construction work. Keep reference footage external to the repo;
do not infer unshown shortcuts or copy product code/assets.
