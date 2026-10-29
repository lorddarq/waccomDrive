#!/usr/bin/env python3
"""Check that the assembly STEP retains individually named solid parts."""
from pathlib import Path
import re

path = Path(__file__).resolve().parent.parent / 'assets/wacom-intuos-pro-large-pth-851-assembly.step'
text = path.read_text()
expected = {
    'UpperHousing', 'LowerHousing', 'TouchRing', 'RingCenterButton',
    'WirelessModuleCover', 'BatteryCover', 'DrawingSurface',
    'ReceiverStorageDoor', 'WirelessPowerButton', 'USBConnectorTongue',
    *(f'ExpressKey_{i}' for i in range(1, 9)),
    *(f'RubberFoot_{i}' for i in range(1, 5)),
    *(f'IntermediateNub_{i}' for i in range(1, 5)),
}
assert text.startswith('ISO-10303-21;') and 'END-ISO-10303-21;' in text
solids = re.findall(r"MANIFOLD_SOLID_BREP\(\s*'([^']*)'", text)
products = re.findall(r"=PRODUCT\(\s*'([^']*)'", text)
assert len(solids) == len(expected) == 26 and set(solids) == expected, solids
assert expected <= set(products), 'Part product hierarchy missing'
assert text.count('=CLOSED_SHELL(') == 26
print('Assembly STEP: 26 named solids, closed shells, and part products verified.')
