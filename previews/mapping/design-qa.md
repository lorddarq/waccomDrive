# Mapping screenshot recreation QA

- Source: `/Users/sorin.jurcut/Library/Application Support/CleanShot/media/media_Ft7JBWLQDl/CleanShot 2026-10-29 at 16.52.25.png`
- Implementation: `index.html`, served at `http://127.0.0.1:8765/`.
- Browser screenshot: `render.jpg` (961 × 723 pixels).
- Viewport: 961 × 723 CSS pixels; screenshots compared at 1:1 size. Source: 961 × 723 pixels. No density rescaling.
- State: Mapping selected, driver paused, USB disconnected, switches off, full active area, settings scroller at 71px.
- Full comparison: `comparison.png`, reference left, implementation right.
- Focused comparison: `detail-comparison.png`, tablet, row positions, slider tracks, thumb placement, and percentages.

## Comparison history

- Initial P2: sidebar/group colors differed and form rows began one pixel too far left. Updated sidebar and selected-state colors and adjusted form padding.
- Initial P2: active-area section was one pixel too low. Reduced the final Display row height by one pixel.
- Initial P2: slider tracks and percentage labels extended one pixel too far right. Increased group right padding by one pixel.
- Post-fix comparisons: persistent header/footer, sidebar, card sizes, native artwork, preview placement, and clipping match the intended composition. No actionable P0/P1/P2 differences remain.

## Required fidelity surfaces

- Fonts/typography: native macOS system stack with measured 10/11/13/15/17px hierarchy. Text is editable HTML. Browser font rasterization differs slightly from SwiftUI.
- Spacing/layout: fixed 961 × 723 window, 195px sidebar boundary, 54px title bar, 87px page header, 57px footer, matching initial scroll state.
- Colors/tokens: light neutral sidebar/cards, blue controls, separators, and rounded corners matched to the source. Browser evidence is JPEG, so small color/compression differences remain P3.
- Images: native details reuse embedded source crops; no generated substitutes. Artwork remains raster, not editable vectors.
- Copy/content: visible labels and values match. Additional offscreen rows follow MappingView.swift.

## Verification

- Browser-loaded all embedded images successfully.
- No warning/error console messages.
- Window bounds verified as x=0, y=0, width=961, height=723.
- Static mock requested: driver actions have no app behavior. Sidebar navigation was subsequently added; see the all-tab extension below.
- Wider windows center the fixed-size app. Smaller viewports may require scrolling; fidelity target is the supplied desktop size.

## Implementation checklist

- [x] Self-contained static HTML with no external dependencies.
- [x] Screenshot-size browser render and focused visual comparison.
- [x] Copy, spacing, control state, and clipping checked.

final result: passed

## All-tab extension

- Scope now includes Overview, Mapping, Pen, Touch, Tablet buttons, Settings, and Help.
- New source visuals: `native-reference/{overview,pen,touch,tablet-buttons,settings,help}.png`, captured from the running app. Native captures are 960 × 720 pixels. The supplied Mapping reference remains the 961 × 723 shell target; the two-pixel native title/header offset is expected when comparing these sources.
- Browser evidence: `browser-render/`, all seven views captured at 961 × 723 CSS/pixel dimensions.
- Full comparison: `all-tabs-comparison.jpg`, native left / HTML right for each added page.
- Focused comparisons: `compare-pen.jpg`, `compare-touch.jpg`, `compare-tablet-buttons.jpg`, `compare-overview.jpg`, `compare-settings.jpg`, and `compare-help.jpg` show the native and HTML content regions together.
- Typography: labels, headings, explanatory paragraphs, values, disabled states, and action names follow SwiftUI source. System font rasterization remains a P3 difference.
- Spacing: shared shell retained; grouped forms, fixed ExpressKey diagram, nested scrolling form, section gaps, and card row heights match the native structure.
- Colors: shared light palette retained; disabled switches, targeted keys, and pickers use captured native visual details.
- Images: pressure curve, overview tablet, ExpressKey base diagram, native picker arrows, and enabled switches come from native screenshots. Embedded assets are raster; text and layout remain HTML/CSS.
- Content: every SwiftUI section is included, including those below the initial viewport.
- Iteration P2: paragraph/note padding initially accumulated vertical drift in Help and Touch. Reduced paragraph/note padding and recaptured; section rhythm now follows the native views.
- Iteration P2: Touch pointer-speed track/value alignment differed. Matched track width, value width, and gap, then recaptured.
- Browser harness `check.html`: PASS for seven tabs, complete section coverage, selected-tab state, persistent footer, ExpressKey and center targeting, nested form scrolling, embedded assets, and Mapping capture position.
- All embedded images loaded. Console warnings/errors: none.
- Sidebar click/keyboard navigation and diagram targeting are functional. Driver, permission, installation, file, and save operations are visual only.

final result: passed
