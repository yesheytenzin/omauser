import json

SRC = "/tmp/opencode/ne_land.geojson"
OUT = "/home/tenzin/plugins/omauser/assets/world.svg"
W, H = 2000, 1000

def project(lon, lat):
    return (lon + 180.0) / 360.0 * W, (90.0 - lat) / 180.0 * H

def rings_to_paths(rings):
    paths = []
    for ring in rings:
        if len(ring) < 3:
            continue
        pts = [project(p[0], p[1]) for p in ring]
        d = f"M {pts[0][0]:.1f} {pts[0][1]:.1f} "
        d += " ".join(f"L {x:.1f} {y:.1f}" for x, y in pts[1:])
        d += " Z"
        paths.append(d)
    return paths

paths = []
with open(SRC) as f:
    gj = json.load(f)
for feat in gj["features"]:
    g = feat["geometry"]
    if not g:
        continue
    if g["type"] == "Polygon":
        paths += rings_to_paths(g["coordinates"])
    elif g["type"] == "MultiPolygon":
        for poly in g["coordinates"]:
            paths += rings_to_paths(poly)

body = "\n".join(f'<path d="{d}"/>' for d in paths)
# Transparent ocean (panel background shows through), light land with a
# soft border so the shapes read on both dark and light themes.
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
<g fill="#7a8aa0" fill-opacity="0.55" stroke="#4a5a70" stroke-opacity="0.8" stroke-width="1">{body}</g>
</svg>'''
open(OUT, "w").write(svg)
print(f"wrote {OUT}: {len(paths)} paths")
