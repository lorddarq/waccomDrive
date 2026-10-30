# Tablet image catalog

`models.json` is a UTF-8 JSON index for the Intuos Pro family. It can be read with Foundation (`JSONSerialization` / `JSONDecoder`) or other standard JSON readers; it does not depend on a macOS-specific archive format.

## Coverage

- 2013: PTH-451, PTH-651, PTH-651/S Special Edition, PTH-851.
- 2017 family, including the later Small: PTH-460, PTH-660, PTH-860, PTH-660P and PTH-860P Paper Editions.
- 2025: PTK470, PTK670, PTK870.
- Regional packaging/SKU suffixes do not create separate entries. Known label aliases are listed explicitly; avoid stripping arbitrary suffixes, because `P` and `/S` identify real editions.
- Older Intuos-branded devices and consumer Intuos models are outside this Intuos Pro index. Source links are stored in the catalog.

Catalog presence is not driver support. The current driver still targets the tested PTH-851 over USB. The app uses the PTH-851 artwork; the index does not extend hardware support.

## Three image slots per model

| Key | Role |
| --- | --- |
| `images.base` | Main tablet artwork. |
| `images.overlay` | Mapping/surface artwork containing the base plus overlay geometry. Treat it as a complete alternative view; do not automatically draw the base again underneath it. |
| `images.express_keys` | Artwork/geometry for ExpressKey overlays. |

Paths are relative to this catalog's folder. Only PTH-851 is assigned the three current SVGs. Other slots are `null`, meaning artwork has not been assigned; use a generic fallback rather than silently showing another model.

Example:

```json
"images": {
  "base": "tablet.svg",
  "overlay": "tablet-overlays.svg",
  "express_keys": "tablet-overlays-express.svg"
}
```

Add model-specific artwork in this directory or a subdirectory, then replace that model's null values with relative SVG paths. Read dimensions from each SVG's `viewBox` rather than duplicating them in JSON.

## App integration

- Overview uses the cropped `tablet.svg` (`238 × 254`).
- ExpressKey previews use the registered `479 × 264` close-ups: `express_keys` is the black default artwork; `overlay` supplies ten independent blue paths (eight keys, ring, center). The renderer isolates those paths in memory and preserves the exported geometry. Blue means customized, a neutral outline means selected, and green means physically pressed.
- Two optional image fields, `mapping_faces` and `mapping_strokes`, reference the full landscape artwork exported from the Figma Mapping frame. They retain their original dimensions and share the same physical center. Native overlays use the SVG `surface` layer bounds for crop and pen feedback; 100% fills that layer.
- The app loads SVGs with AppKit and bundles this directory alongside the catalog. No web view or conversion dependency is required.
- The base and close-ups are separate compositions; do not stack them over each other.

Run `./script/check_tablet_artwork.sh` to check native loading and isolated overlay registration on macOS. Run `python3 script/check_tablet_catalog.py` to validate the catalog and local SVG references.

## Compatibility contract

- `schema_version: 1` identifies this layout. Keep existing IDs and image-key meanings stable.
- Readers should ignore unknown object fields and accept additional models/aliases. Image values are optional: accept missing or null slots and show a fallback.
- Additive fields/entries remain version 1. An incompatible layout requires a new schema version; readers should handle unsupported versions with a fallback rather than guessing.
- Keep paths local and relative; no absolute machine paths or remote downloads are needed. Preserve the catalog/asset directory structure when bundling.
- SVG rendering is provided by AppKit on the app's supported macOS version.

Check the catalog and referenced SVGs with:

```sh
python3 script/check_tablet_catalog.py
```
