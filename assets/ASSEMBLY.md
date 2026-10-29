# Separate-parts tablet draft

- Exterior assembly draft derived from the PTH-851 preview model, with estimated part boundaries and small clearances.
- Parts: upper/lower housing, eight ExpressKeys, touch ring and center button, drawing surface, wireless-module and battery covers, receiver storage door, wireless power button, USB connector tongue, four rubber feet, and four intermediate nubs.
- Parts remain in their assembled positions. The STEP keeps them separate for selection and explosion in a compatible viewer.
- This is a visual breakdown, not a measured teardown or production assembly. Shell internals, fasteners, mounting posts, PCB, battery internals, connector contacts, and mechanisms are omitted.
- The original single-solid files remain unchanged.
- Files: `wacom-intuos-pro-large-pth-851-assembly.step` and the matching editable `.solidcraft` source.
- Validation: STEP round-trip in SolidCraft retained 26 solids / 26 part subcomponents, with all bodies closed and 487 × 317.7 × 12 mm overall dimensions. Draftler's explode operation has not been tested.
- Run `python3 script/check_tablet_assembly.py` to verify the exported names, closed shells, and product hierarchy.
- Preview colors identify separate components; they are not the tablet's material colors.
