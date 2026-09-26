"""2D polygons, as lists of (x, y) points: plain Python, so tools without Blender (icon_sheet.py) use them too."""

import math


def signed_area(polygon):
    """The polygon's area, positive when it runs counter-clockwise."""
    n = len(polygon)
    return 0.5 * sum(polygon[i][0] * polygon[(i + 1) % n][1] - polygon[(i + 1) % n][0] * polygon[i][1] for i in range(n))


def ccw(polygon):
    """The polygon, running counter-clockwise."""
    return list(polygon) if signed_area(polygon) > 0 else list(reversed(polygon))


def offset(polygon, distance, max_miter=2.5):
    """A polygon grown outward by `distance` (shrunk if negative), mitred, each miter capped at max_miter times the
    distance so a sharp tip does not shoot off."""
    polygon = ccw(polygon)
    n = len(polygon)
    out = []
    for i in range(n):
        px, py = polygon[i - 1]
        cx, cy = polygon[i]
        nx, ny = polygon[(i + 1) % n]
        e1 = (cx - px, cy - py)
        e2 = (nx - cx, ny - cy)
        l1 = math.hypot(*e1) or 1e-9
        l2 = math.hypot(*e2) or 1e-9
        # outward normals of the two edges meeting here: right of the direction of travel, for CCW
        n1 = (e1[1] / l1, -e1[0] / l1)
        n2 = (e2[1] / l2, -e2[0] / l2)
        bx, by = n1[0] + n2[0], n1[1] + n2[1]
        bl = math.hypot(bx, by)
        if bl < 1e-9:
            out.append((cx + n1[0] * distance, cy + n1[1] * distance))
            continue
        bx, by = bx / bl, by / bl
        cos_half = max(bx * n1[0] + by * n1[1], 1e-6)
        miter = min(abs(distance) / cos_half, abs(distance) * max_miter)
        miter = math.copysign(miter, distance)
        out.append((cx + bx * miter, cy + by * miter))
    return out
