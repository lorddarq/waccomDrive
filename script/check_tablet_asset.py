#!/usr/bin/env python3
"""Check the tablet STL's dimensions, closed edges, and CAD volume agreement."""
from collections import Counter
from pathlib import Path
import math
import struct

data = (Path(__file__).resolve().parent.parent / 'assets/wacom-intuos-pro-large-pth-851.stl').read_bytes()
count = struct.unpack_from('<I', data, 80)[0]
assert count > 0 and len(data) == 84 + 50 * count
edges, vertices, volume = Counter(), [], 0.0
for index in range(count):
    values = struct.unpack_from('<12fH', data, 84 + 50 * index)
    a, b, c = [tuple(round(v, 4) for v in values[j:j + 3]) for j in (3, 6, 9)]
    assert all(math.isfinite(v) for point in (a, b, c) for v in point)
    vertices.extend((a, b, c))
    for p, q in ((a, b), (b, c), (c, a)):
        edges[tuple(sorted((p, q)))] += 1
    volume += (a[0] * (b[1]*c[2] - b[2]*c[1]) + a[1] * (b[2]*c[0] - b[0]*c[2]) + a[2] * (b[0]*c[1] - b[1]*c[0])) / 6
size = [max(p[j] for p in vertices) - min(p[j] for p in vertices) for j in range(3)]
assert all(abs(a-b) < .01 for a, b in zip(size, [487, 317.7, 12])), size
for sign in (-1, 1):
    edge = [p for p in vertices if p[1] * sign > 157]
    assert edge and max(p[2] for p in edge) - min(p[2] for p in edge) < 7, "Hull edge taper missing"
assert all(value == 2 for value in edges.values()), Counter(edges.values())
assert abs(volume - 1627251.9296) / 1627251.9296 < .001, volume
print(f'{count} triangles; {size} mm; watertight edges; CAD volume agreement passed.')
