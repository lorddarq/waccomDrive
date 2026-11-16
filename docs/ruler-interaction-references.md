
## Interaction acceptance targets

- [x] Manipulate guides directly over the painting application, without visiting
  driver settings for each adjustment. Retain numeric controls for precise entry.
- [x] Update guide geometry continuously during a drag, using a temporary preview;
  validate and commit at gesture end. Invalid geometry must not enter snapping.
- [x] Distinguish move, rotate, size/axis, corner and edge operations with handle
  appearance, cursor/hover feedback and concise accessible names.
- [ ] Use subtle colored guide families and a clear active direction. Keep handle
  clutter out of normal drawing while preserving predictable access to editing.
- [x] Show the relevant construction through the stroke's anchor/cursor, rather
  than relying only on static fans of lines from vanishing points.
- [ ] Keep repeated/concentric ellipse adjustments and plane-preserving movement
  available on screen. Preserve projective geometry, not just screen translation.
- [x] Provide guide hide/show so the artwork can be inspected without changing
  geometry or leaving the drawing app.
- [ ] Preserve immediate lift and stable direction/branch selection. Overlay
  previews remain on the UI thread; HID processing stays on its dedicated owner
  loop and must not wait for rendering.
- [ ] Repeat the established combined ruler/string/pressure timing comparison
  during editing and drawing. Frame sampling of references does not provide a
  quantitative latency target.

## Current implementation and remaining gaps

The floating selector/edit bar was removed at the owner's request. Control-held
editing remains the canvas entry point. Control–Option–R opens the semicircular
picker for the nine implemented families; numeric setup remains on Rulers. The menu bar remains a
secondary editing/visibility entry point. Toolbar-specific pen-filter bypass
state and its unused callbacks were removed with the bar.

`Sources/App/RulerOverlay.swift` now retains windows/layers during live previews
at up to 60 Hz. Valid geometry commits on release; invalid/cancelled gestures
leave saved settings unchanged. Move/rotate, individual points, ellipse edges and
uniform-size handles have distinct symbols, hover feedback and accessible names.
Isometric orientation is independent of its axis angle. Off-screen proxies are
spaced apart. The menu bar can show/hide guides without changing snapping.

Control-held on-canvas editing was accepted by the user as substantially better.
The 2026-11-16 increment adds a shared pinhole camera (1/2/3-point perspective,
FOV/radius/yaw/pitch/roll), homogeneous scene-line matching including directions
at infinity, selected-axis feedback, and cursor/stroke-anchored constructions.
Isometric/perspective measurement ticks include subdivisions and projective depth.
Perspective ellipses now support fixed/concentric/stepped radii with stroke-size
locking. A shared invertible unit-plane homography drives both circles and
plane-preserving center/edge edits; Option-drag retains screen-space edits.
Family-specific mode and tick handles avoid revisiting settings for routine adjustments.

Geometry, legacy JSON, projection/blend and native control/active-layer checks
cover these additions. Physical pen/app timing and the new family controls still
need acceptance. Fisheye and the remaining Bezier families and
broader multi-display/fullscreen acceptance remain open. No whole family is
claimed complete by this increment.

Next validate the editing experience over painting apps, then continue the
priority-family construction work. Keep reference footage external to the repo;
do not infer unshown shortcuts or copy product code/assets.

## Radial, isometric and box increment

Free/locked radial angles now share analytic quadratic geometry between rendering
and snapping. The nearest-point solver considers all stationary points plus the
center boundary, with a bounded continuity tie-breaker. Straight legacy lines
remain exact; curved rays stop at their center. Angle/bend/spacing/tick controls
are available under Control, with precise numeric settings retained.

Isometric axes can be edited independently, with 30-degree, 2:1 and dimetric
presets. Optional explicit-extent boxes share eight vertices/twelve edges between
isometric/camera rendering and snapping. Edge acquisition reuses the ordinary
direction selector; only incident edges are eligible at corners, preventing
intersection jumps. Near-plane-crossing boxes bypass snapping and render empty.
Control-triggered dimension learning and manual mid-stroke axis cycling are implemented. Automatic direction changes are optional and share the stable direction selector.

Checks cover an independent dense-sampling oracle for radial nearest points,
0/50/100-percent blend, center/reset and legacy behavior, axis editing/presets,
box clamping/incident-edge transitions/near-plane behavior, JSON validation,
combined-feature replay parity and native controls. New modes still require
physical drawing/timing acceptance; no whole-family completion is implied.

## Axis, reference and learned-box increment

Control pressed during contact cycles the next valid axis on the input owner;
while lifted it still enters overlay editing. A per-segment input offset and
reanchoring preserve stationary output at both partial and full accuracy.
Degenerate/parallel duplicate families are skipped; press-and-hold advances once.
Native modifier-state sampling is gated to active axis-capable snapping and is
included in input processing timing. It does not depend on the UI timer.

The pin handle stores a fixed measurement reference at the Control-entry cursor
position; it can be dragged, unpinned or edited numerically. It adds fixed axes
and ticks without replacing the cursor/stroke construction or color overrides.

Optional dimension learning captures each first axis extent on a Control-triggered
axis change, then uses the learned eight-vertex/twelve-edge box. The shared
world/screen projection and inverse axis-distance helpers serve explicit handles,
learning and guide geometry. Partial-accuracy captures reanchor continuously;
learned values are per-stroke and clear on lift/reset. Automatic direction-change
inference now freezes the original turn corner while acquiring sustained evidence;
ambiguous/noisy motion retains the selected axis. It is opt-in and keeps manual cycling.

Independent camera inclines use three world-space directions with shared view
rotation. XY/XZ/YZ circle helpers reuse the projected-circle plane, orthogonalizing
the second direction for a true circle even with non-orthogonal custom axes.
The pinned reference or view center anchors numeric generation; canvas generation
uses the editing-entry cursor when no reference is pinned. Degenerate, edge-on and
near-plane-crossing helpers are rejected. Geometry/oracle and native handle checks
pass; physical acceptance remains open.

## Perspective-ellipse depth increment

An optional third homogeneous direction comes from a direct point or two scene
lines, including parallel directions. Camera circle generation seeds the normal.
The saved reference quad stays fixed; a depth offset and top-radius scale derive
parallel sections from its homography. Snapping and overlay use the same derived
quad. Common cylinder/cone tangent generators are computed from the projective
apex; nested sections without visible real tangents omit those generators.
Depth-plane degeneracy, mirrored/near-plane sections and malformed values are
rejected. Units are local screen-point calibration, not recovered scene units.

Control-held layers/depth/scale/line/VP handles edit these controls directly.
Depth click advances one configured step; Shift-click goes back. Shift-drag
quantizes depth/radius and plane movement, resizes corners about the plane center,
or moves opposite edges symmetrically. Option constrains corners to an adjacent
edge; center/edge Option movement stays in screen space. The optional editing
grid uses plane steps. Editing the plane bakes the current section as reference.
The third retained color path owns reference circles, depth setup and tangents.

Checks use independent 3D projection and tangency oracles, 0/50/100-percent
blending, JSON/invalid settings, native handles/preview and input-owner replay
for fixed/concentric/stepped depth sections. Physical drawing/timing acceptance
remains separate.

## Vanishing-line measurement and alignment increment

Optional per-family first-unit distances and subdivision counts calibrate equal
scene steps through a one-dimensional projective map. Finite families converge
to their vanishing point; parallel directions stay affine. Ticks beyond the
projective depth pole are skipped. A first unit at/past the VP yields no ticks,
and calibration is relative to the shared pinned reference. Absent calibration
retains the legacy screen-spacing behavior. Canvas ruler handles edit each first
unit; settings expose distance/subdivisions.

The first two families define an optional horizon, including homogeneous points
at infinity. Shift slides direct VP1/2 along it. Shift-drag translates one whole
scene line; Option constrains endpoints to cardinal/partner directions and, for
family 3, perpendicular to the horizon. Option on direct VPs snaps nearby cardinal
alignment. The shared scene-line edit helper also serves depth-ellipse pairs.
Construction previews provide alignment feedback; invalid/coincident pairs reject
the preview. Deterministic checks cover independent projective-depth values,
subdivisions, infinity/legacy/visibility, horizon and pair edits, calibration
isolation and JSON. Physical scene matching and timing still need acceptance.

## Keyboard construction editing

During lifted Control-held editing over another app, arrows move the active
construction by 1 screen point; Option uses 0.1 and Shift uses 10. Home moves its
center to the pointer; Backspace restores the editing-entry state. A main-loop
session event tap captures only these keys during that mode, under existing
Accessibility permission. Key-ups and repeats remain paired after modifier/focus
changes; driver text fields, other shortcuts, contact and active drags pass through.
Candidate settings coalesce before commits outside the event callback. Exit cancels
pending edits; the tap and run-loop source are removed after captured keys release
or on shutdown. No keyboard handling runs on the HID owner.

Native checks cover increments, reset/recenter, coalescing, contact/focus/modifier
gates, captured key-up and exit cancellation without posting events. Real painting
app shortcut conflicts and Accessibility/event-tap delivery remain acceptance items.
Rulers now exposes keyboard-hook readiness while editing. A live check confirmed
hook creation; targeted automation key presses in a temporary TextEdit document
did not move the ruler, so actual keyboard delivery remains unverified. Test
settings and the blank document were cleaned up. Do not infer physical-key success
or failure from that automation result alone.

Owner follow-up accepted drawing/performance and actual keyboard behavior. The
reported remaining ellipse issue was handle occlusion at small sizes. Compact or
thin ellipse guides now reserve a clear region in the existing handle allocator;
32-point targets/16-point symbols move outside it, retaining collision separation,
display bounds and original geometry-based drag deltas. The region follows the
actual projected circle radius, not just its construction quad. Native cases cover
small/thin guides, screen edges, small circles inside large quads and depth controls.

The priority pipeline matrix additionally covers 15 representative configurations
with curve/EMA/string/speed enabled: event types, raw speed, pressure, tilt, raw
tablet coordinates and button fields stay equal to the ruler-disabled reference
through tool changes. Immediate no-tail lift and master bypass pass. Session
checks exercise deferred configuration plus reset/pause/stop with held Shift and
right mouse, then compare fresh-stroke geometry/pressure after cleanup.

## Semicircular ruler picker

The owner chose Control–Option–R as the default. Reuse the native shortcut recorder
on Rulers, with explicit disable/custom payloads preserving older JSON. The picker
uses a small non-key/non-activating panel and retained Core Animation/native SF
Symbol controls. Its semicircle flips above/below the pointer and clamps to the
nearest usable display. Hover/focus names, current marker, arrows/Tab, Enter,
1–9 selection and Escape/repeated-shortcut/outside-click cancellation are provided.
The center power button or G toggles ruler enablement (guide and snapping).
Enabling also restores guide visibility; the Advanced master remains independent.

Opening requires lift/no held pen-button action. Install modal pointer capture
before presenting; only while the picker/captured release is active does the
shared keyboard tap include mouse movement/buttons/drags. Normal drawing retains
the keyboard-only tap. Capture complete click/release sequences, including multiple
buttons and cancellation, to prevent menu ink in the painting app. Position filters
are suspended through the shared interaction configuration and restored on close.
Choice persists through the existing validated ruler-save path and safe session
configuration. Preserve master, geometry and dirty draft edits; only a draft type
that still followed the saved type follows the new selection.

Settings checks cover default/custom/disabled/invalid bindings. Native checks
cover semicircle/hit geometry, edge/negative-origin placement, symbols, non-key
panels, navigation, pointer cleanup, shortcut repeats and recorder focus. Actual
painting-app invocation, pen targeting and cancellation remain owner acceptance.
