#!/usr/bin/env python3
# Builds src/data/europe-map.json, the map of Europe on the Countries page (the author's q6, 22 Oct 2026: the real
# outlines, as a locator), from Natural Earth's 1:50m admin_0 countries (public domain):
#   curl -sLO https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_admin_0_countries.geojson
#   python3 -I scripts/make-europe-map.py ne_50m_admin_0_countries.geojson
# Run it again only to change the frame or the detail; the outlines don't move.
# Lambert azimuthal equal-area centred on 15°E 52°N, simplified to under a pixel, rings outside the frame left out.
# Each country: its path, a label point (the centroid of its largest ring), whether it needs a dot to be tappable,
# the box of its largest ring (to frame it), and its neighbours (outlines within about 25 km, so the Channel counts and the Atlantic doesn't).
import json, math, os, sys

out_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src", "data", "europe-map.json")
src = sys.argv[1]
LON0, LAT0 = math.radians(15), math.radians(52)
W = 1000
# The frame, in degrees: Iceland and Portugal on the left, Cyprus and Armenia on the right, the North Cape at the top.
FRAME = [(-24.5, 63.5), (-10, 36), (35, 34.5), (46.5, 41), (31, 71.5), (-24.5, 66.8), (5, 71.2)]

def project(lon, lat):
    l, p = math.radians(lon) - LON0, math.radians(lat)
    k = math.sqrt(2 / (1 + math.sin(LAT0) * math.sin(p) + math.cos(LAT0) * math.cos(p) * math.cos(l)))
    return k * math.cos(p) * math.sin(l), -k * (math.cos(LAT0) * math.sin(p) - math.sin(LAT0) * math.cos(p) * math.cos(l))

fx = [project(*pt) for pt in FRAME]
x0, x1 = min(p[0] for p in fx), max(p[0] for p in fx)
y0, y1 = min(p[1] for p in fx), max(p[1] for p in fx)
pad = (x1 - x0) * 0.02
x0, x1, y0, y1 = x0 - pad, x1 + pad, y0 - pad, y1 + pad
S = W / (x1 - x0)
H = round((y1 - y0) * S)

def px(lon, lat):
    x, y = project(lon, lat)
    return ((x - x0) * S, (y - y0) * S)

def dp(points, eps):
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        a, b = stack.pop()
        ax, ay = points[a]; bx, by = points[b]
        dx, dy = bx - ax, by - ay
        norm = math.hypot(dx, dy) or 1e-9
        best, idx = 0, None
        for i in range(a + 1, b):
            d = abs(dy * (points[i][0] - ax) - dx * (points[i][1] - ay)) / norm
            if d > best:
                best, idx = d, i
        if idx is not None and best > eps:
            keep[idx] = True
            stack += [(a, idx), (idx, b)]
    return [p for p, k in zip(points, keep) if k]

def clip(ring, x0, y0, x1, y1):
    """Sutherland-Hodgman against the frame (with a margin): Russia's ring keeps its European part only."""
    def cut(points, inside, cross):
        out = []
        for i, current in enumerate(points):
            previous = points[i - 1]
            if inside(current):
                if not inside(previous):
                    out.append(cross(previous, current))
                out.append(current)
            elif inside(previous):
                out.append(cross(previous, current))
        return out

    def at_x(x):
        return lambda p, q: (x, p[1] + (q[1] - p[1]) * (x - p[0]) / ((q[0] - p[0]) or 1e-9))

    def at_y(y):
        return lambda p, q: (p[0] + (q[0] - p[0]) * (y - p[1]) / ((q[1] - p[1]) or 1e-9), y)

    points = ring
    for inside, cross in ((lambda p: p[0] >= x0, at_x(x0)), (lambda p: p[0] <= x1, at_x(x1)),
                          (lambda p: p[1] >= y0, at_y(y0)), (lambda p: p[1] <= y1, at_y(y1))):
        if not points:
            break
        points = cut(points, inside, cross)
    return points


def area(ring):
    return 0.5 * sum(ring[i][0] * ring[i - 1][1] - ring[i - 1][0] * ring[i][1] for i in range(len(ring)))

def centroid(ring):
    a = area(ring) or 1e-9
    cx = sum((ring[i][0] + ring[i - 1][0]) * (ring[i][0] * ring[i - 1][1] - ring[i - 1][0] * ring[i][1]) for i in range(len(ring)))
    cy = sum((ring[i][1] + ring[i - 1][1]) * (ring[i][0] * ring[i - 1][1] - ring[i - 1][0] * ring[i][1]) for i in range(len(ring)))
    return cx / (6 * a), cy / (6 * a)

with open(src, encoding="utf-8") as f:
    features = json.load(f)["features"]

out, dense = {}, {}
for feat in features:
    props = feat["properties"]
    cc = props.get("ISO_A2_EH") if props.get("ISO_A2_EH") not in (None, "-99") else props.get("ISO_A2")
    # Canada reaches the frame only with a few Arctic islands in the corner: noise, and the heaviest outline
    if not cc or cc == "-99" or cc == "CA":
        continue
    geom = feat["geometry"]
    polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
    rings = []
    for poly in polys:
        ring = [px(lon, lat) for lon, lat in poly[0]]
        xs, ys = [p[0] for p in ring], [p[1] for p in ring]
        if max(xs) < -20 or min(xs) > W + 20 or max(ys) < -20 or min(ys) > H + 20:
            continue
        rings.append(ring)
    if not rings:
        continue
    dense[cc] = rings
    clipped = [c for c in (clip(r, -40, -40, W + 40, H + 40) for r in rings) if len(c) >= 3]
    simple = [r for r in (dp(r, 0.8) for r in clipped) if len(r) >= 4 and abs(area(r)) > 2]
    if not simple:
        simple = [max(clipped or rings, key=lambda r: abs(area(r)))]
    d = "".join("M" + "L".join(f"{x:.1f},{y:.1f}" for x, y in r) + "Z" for r in simple)
    big = max(rings, key=lambda r: abs(area(r)))
    cx, cy = centroid(big)
    total = sum(abs(area(r)) for r in rings)
    bx, by = [p[0] for p in big], [p[1] for p in big]
    out[cc] = {"d": d, "c": [round(cx, 1), round(cy, 1)], "b": [round(min(bx)), round(min(by)), round(max(bx)), round(max(by))],
               "dot": total < 220}

# Neighbours: any two vertices within 25 km (in pixels at the centre's scale), on a grid so it stays quick.
km = S * 1 / 6371.0
reach = 25 * km
cell = {}
for cc, rings in dense.items():
    for r in rings:
        for x, y in r[::2]:
            cell.setdefault((int(x // reach), int(y // reach)), set()).add(cc)
near = {cc: set() for cc in dense}
for (gx, gy), ccs in cell.items():
    around = set()
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            around |= cell.get((gx + dx, gy + dy), set())
    for a in ccs:
        near[a] |= around - {a}
for cc in out:
    out[cc]["n"] = sorted(near.get(cc, ()))

with open(out_path, "w", encoding="utf-8") as f:
    json.dump({"w": W, "h": H, "countries": out}, f, ensure_ascii=False, separators=(",", ":"))
    f.write("\n")
print(len(out), "countries,", W, "x", H, ",", os.path.getsize(out_path) // 1024, "KB")
