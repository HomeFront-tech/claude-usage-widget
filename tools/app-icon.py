#!/usr/bin/env python3
"""Draws Claude Buddy.app's icon: Buddy on a dark rounded square, every size macOS wants.

usage: tools/app-icon.py OUT.iconset   (then: iconutil -c icns OUT.iconset)

Buddy is the same 14 x 12 grid buddy.lua draws (body, sides, legs, eyes with their shine),
smiling, in the default skin's colours. Plain Python: no imaging library needed, so
tools/build-app can run it on any Mac.
"""
import os
import struct
import sys
import zlib

BODY, SHADE, SHINE = (217, 120, 87), (179, 92, 66), (240, 158, 128)
EYE, WHITE = (26, 20, 20), (247, 247, 247)
TOP, BOTTOM = (48, 47, 45), (28, 27, 26)   # the square's gradient: theme raised to bg
EDGE = (83, 81, 74)                         # theme edge, a hairline round the square

# (col, row, w, h, colour) on Buddy's grid, drawn in order
BUDDY = [
    (2, 10, 1, 2, SHADE), (4, 10, 1, 2, SHADE), (9, 10, 1, 2, SHADE), (11, 10, 1, 2, SHADE),  # legs
    (1, 0, 12, 10, BODY), (0, 1, 1, 8, BODY), (13, 1, 1, 8, BODY),                           # body, sides
    (1, 9, 12, 1, SHADE), (2, 1, 2, 1, SHINE),                                               # shade, shine
    (3, 3, 2, 3, EYE), (9, 3, 2, 3, EYE), (3, 3, 1, 1, WHITE), (9, 3, 1, 1, WHITE),          # eyes
    (5, 7, 1, 1, EYE), (6, 8, 2, 1, EYE), (8, 7, 1, 1, EYE),                                 # smile
]

# icon_<name>.png: pixel size
SIZES = {"16x16": 16, "16x16@2x": 32, "32x32": 32, "32x32@2x": 64, "128x128": 128,
         "128x128@2x": 256, "256x256": 256, "256x256@2x": 512, "512x512": 512, "512x512@2x": 1024}


class Canvas:
    def __init__(self, n):
        self.n = n
        self.px = bytearray(n * n * 4)

    def blend(self, x, y, rgb, a):
        if a <= 0 or not (0 <= x < self.n and 0 <= y < self.n):
            return
        i = (y * self.n + x) * 4
        da = self.px[i + 3] / 255
        oa = a + da * (1 - a)
        for k in range(3):
            self.px[i + k] = round((rgb[k] * a + self.px[i + k] * da * (1 - a)) / oa) if oa else 0
        self.px[i + 3] = round(oa * 255)

    def rect(self, x0, y0, x1, y1, rgb, alpha=1.0):
        """Fills [x0, x1) x [y0, y1) in pixels, edges partly covered where they fall mid-pixel."""
        for y in range(int(y0), min(self.n, int(-(-y1 // 1)))):
            cy = min(y1, y + 1) - max(y0, y)
            for x in range(int(x0), min(self.n, int(-(-x1 // 1)))):
                cx = min(x1, x + 1) - max(x0, x)
                self.blend(x, y, rgb, alpha * cx * cy)

    def rounded(self, x0, y0, size, r, colour_at, ss=4):
        """A rounded square, colour_at(t) top to bottom. Each row's solid middle is filled in
        one go; only the pixels the curved or straight edge crosses are supersampled."""
        import math

        def half_width(v):  # the shape's half-width at height v inside the square
            d = max(r - v, 0, v - (size - r))
            return (size / 2 - r) + math.sqrt(max(0.0, r * r - d * d)) if d <= r else -1

        cx = x0 + size / 2
        for y in range(max(0, int(y0)), min(self.n, int(y0 + size) + 1)):
            rgb = colour_at(max(0.0, min(1.0, (y - y0) / size)))
            v0, v1 = y - y0, y + 1 - y0
            inner = min(half_width(v0), half_width(v1)) if v0 >= 0 and v1 <= size else -1
            outer = max(half_width(max(v0, 0)), half_width(min(v1, size)))
            if outer < 0:
                continue
            xa, xb = (math.ceil(cx - inner), math.floor(cx + inner)) if inner > 0 else (0, -1)
            if xb > xa:
                xa, xb = max(xa, 0), min(xb, self.n)
                i = (y * self.n + xa) * 4
                self.px[i:i + (xb - xa) * 4] = bytes(rgb + (255,)) * (xb - xa)
            for x in range(max(0, int(cx - outer)), min(self.n, int(cx + outer) + 1)):
                if xa <= x < xb:
                    continue
                inside = sum(self._in(x + (sx + 0.5) / ss - x0, y + (sy + 0.5) / ss - y0, size, r)
                             for sy in range(ss) for sx in range(ss))
                self.blend(x, y, rgb, inside / (ss * ss))

    @staticmethod
    def _in(px, py, size, r):
        if px < 0 or py < 0 or px > size or py > size:
            return False
        dx = max(r - px, 0, px - (size - r))
        dy = max(r - py, 0, py - (size - r))
        return dx * dx + dy * dy <= r * r

    def oval(self, cx, cy, rx, ry, rgb, alpha):
        for y in range(int(cy - ry), int(cy + ry) + 1):
            for x in range(int(cx - rx), int(cx + rx) + 1):
                d = ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2
                if d <= 1:
                    self.blend(x, y, rgb, alpha * min(1.0, (1 - d) * 4))

    def png(self):
        rows = b"".join(b"\0" + bytes(self.px[y * self.n * 4:(y + 1) * self.n * 4]) for y in range(self.n))

        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", self.n, self.n, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def draw(n):
    """The icon at n x n pixels, laid out on Apple's 1024 grid (an 824 square, 100 in)."""
    c, k = Canvas(n), n / 1024
    c.rounded(100 * k, 100 * k, 824 * k, 185 * k, lambda t: EDGE)

    def fill(t):
        return tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
    inset = max(1.0, 3 * k)
    c.rounded(100 * k + inset, 100 * k + inset, 824 * k - 2 * inset, 185 * k - inset, fill)
    s = 40 * k                              # one Buddy pixel: 560 x 480 on the 1024 grid
    ox, oy = (1024 - 14 * 40) / 2 * k, 262 * k
    c.oval(512 * k, oy + 12 * s + 6 * k, 6 * s, 0.9 * s, (0, 0, 0), 0.35)
    for col, row, w, h, rgb in BUDDY:
        c.rect(ox + col * s, oy + row * s, ox + (col + w) * s, oy + (row + h) * s, rgb)
    return c.png()


def main(argv):
    if len(argv) != 2 or not argv[1].endswith(".iconset"):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    os.makedirs(argv[1], exist_ok=True)
    made = {}
    for name, n in SIZES.items():
        if n not in made:
            made[n] = draw(n)
        with open(os.path.join(argv[1], "icon_%s.png" % name), "wb") as f:
            f.write(made[n])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
