# Static app preview

- Open `index.html` directly, or serve this folder with `python3 -m http.server 8765`.
- All seven pages are included: Overview, Mapping, Pen, Touch, Tablet buttons, Settings, and Help. Use the sidebar to switch pages.
- Capture at **961 × 723 CSS pixels**, 100% browser zoom, light appearance, preferably on macOS for the system font.
- Direct links use hashes, for example `index.html#Touch` or `index.html#Tablet%20buttons`.
- Mapping opens at the supplied screenshot's scroll position. Other pages open at the top. Long forms scroll; the Tablet buttons diagram stays above its own scrolling form.
- Sidebar navigation, action pickers, and ExpressKey targeting are available for previewing. Hardware, system permissions, installation, file operations, and saving are visual only.
- HTML/CSS provides the layout and editable text. Embedded screenshot crops preserve native artwork, icons, switches, the pressure curve, and window controls.
- This is a fixed capture state: USB disconnected and driver paused. Pen settings reflect the captured app state.
- All image assets are embedded. No external libraries, fonts, network dependencies, or build tools are required.
- `native-reference/` contains the six additional app captures. `browser-render/` contains browser evidence for every tab.
- To run the browser check, serve this folder and open `check.html`. It verifies seven-page navigation, section coverage, diagram targeting, form scrolling, and capture position.
