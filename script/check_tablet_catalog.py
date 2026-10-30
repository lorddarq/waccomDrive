#!/usr/bin/env python3
"""Validate stable model identities and three local, optional SVG slots."""
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent / 'assets/tablet'
catalog = json.loads((root / 'models.json').read_text(encoding='utf-8'))
assert catalog['schema_version'] == 1
ids, labels = set(), {}
images = 0
for model in catalog['models']:
    identifier = model['id']
    assert re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', identifier), identifier
    assert identifier not in ids, 'Duplicate model ID: ' + identifier
    ids.add(identifier)
    assert model['size'] in ('small', 'medium', 'large')
    assert model['edition'] in ('standard', 'special', 'paper')
    assert model['source'] in catalog['sources']
    assert model['name'] and model['model'] and model['generation']
    for label in [model['model'], *model['aliases']]:
        key = label.casefold().replace('-', '').replace(' ', '')
        assert key not in labels or labels[key] == identifier, 'Ambiguous model alias: ' + label
        labels[key] = identifier
    assert {'base', 'overlay', 'express_keys'} <= set(model['images'])
    for location in model['images'].values():
        if location is None:
            continue
        assert isinstance(location, str) and location and not Path(location).is_absolute()
        path = (root / location).resolve()
        assert path.is_relative_to(root.resolve()), 'Image path escapes the asset folder'
        assert path.suffix.lower() == '.svg' and path.is_file(), location
        svg = ET.parse(path).getroot()
        assert svg.tag == '{http://www.w3.org/2000/svg}svg', location
        view_box = [float(v) for v in svg.attrib['viewBox'].replace(',', ' ').split()]
        assert len(view_box) == 4 and view_box[2] > 0 and view_box[3] > 0, location
        images += 1
assert catalog['models'], 'No models indexed'
print(f'Tablet catalog: {len(ids)} unique model/edition entries, three required image slots plus optional mapping layers, {images} valid SVG references.')
