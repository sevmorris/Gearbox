#!/usr/bin/env python3
"""make-appicon.py — generate the Gearbox app icon.

A gearshift's gate seen from above: the H of a manual gearbox, three slots and
the bar across them, with the knob in first. It is folded down its centre the
way the sibling apps' glyphs are: orange on blue, lit on the left and in shade
on the right. The ground, the two planes and the geometry are Dipstick's
tools/icon/make-appicon.py, itself PasswordGen's, whose colours were sampled
from FilmStrip's icon, so Gearbox sits on the same shelf as the other apps.
The middle slot stands on the fold, which puts the seam where the eye already
reads a centre line.

Not a cog. A cog is System Settings' icon, and the sidebar's symbol for the
macOS Defaults pane, so Gearbox would read as one more settings window beside
them. The knob joins the end of its slot with no gap, so the two read as the
lever. A first pass cut a ring between them, and the knob read as the dot of an
i: the icon said "iH".

Geometry follows Apple's macOS grid: on a 1024 canvas the body is 824x824 with
a ~185 corner radius, inset 100 a side, which is where every sibling sits.

Everything is drawn at 4x and downsampled with Lanczos — PIL's polygons and
rounded rectangles are aliased, and the fold seam shows every jaggy at 1024.

Usage:
  python3 tools/icon/make-appicon.py [--out FILE]

Writes assets/AppIcon.icns, which scripts/assemble-app.sh copies into the
bundle for build.sh and release.sh. Requires Pillow, and iconutil from the
Xcode command line tools.
"""

import argparse
import os
import subprocess
import sys
import tempfile

try:
    from PIL import Image, ImageChops, ImageDraw, ImageFilter
except ImportError:
    sys.exit("make-appicon: Pillow is required — pip install Pillow")

# ── Canvas ────────────────────────────────────────────────────────────────────
BASE = 1024          # the coordinate space every number below is written in
SS = 4               # supersampling factor
S = BASE * SS

BODY_INSET = 100     # Apple's grid: 824x824 body on a 1024 canvas
CORNER = 185

# The .iconset an .icns is built from: (point size, scale) -> file name.
ICONSET = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
           (256, 1), (256, 2), (512, 1), (512, 2)]

# ── Palette ───────────────────────────────────────────────────────────────────
# FilmStrip's ground, sampled down its left margin, as PasswordGen and Dipstick
# have it. It is not a straight ramp: it falls away quickly under the top edge
# and flattens toward the bottom, and a two-stop gradient between the same end
# colours reads visibly paler.
GROUND = [(100, (38, 104, 149)), (300, (18, 89, 137)), (500, (1, 77, 127)),
          (700, (0, 70, 116)), (924, (0, 64, 107))]
# The two planes either side of the fold, each a touch darker at the foot.
LIT = [(150, (252, 158, 72)), (874, (246, 145, 62))]
SHADE = [(150, (198, 95, 14)), (874, (190, 88, 10))]
GLYPH_SHADOW = (0, 18, 36)

# ── Glyph ─────────────────────────────────────────────────────────────────────
# Three upright slots and the bar across their middles, all one width with
# round ends, and the knob over the top of the left slot. The glyph runs from
# the top of the knob to the foot of the slots, centred on the canvas; the
# knob pulls its left side out, and the middle slot stays on the fold.
SLOT_WIDTH = 72
SLOT_GAP = 190       # centre to centre
SLOT_TOP = 282       # the top of each slot's rounded end
SLOT_FOOT = 806      # the foot of each slot's rounded end
BAR_Y = (SLOT_TOP + SLOT_FOOT) / 2
KNOB_RADIUS = 100    # its top is at 218, as far below the body's top edge as
                     # SLOT_FOOT is above its foot


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def px(v):
    """1024-space value -> supersampled pixels."""
    return int(round(v * SS))


def vertical_gradient(stops):
    """A full-canvas gradient through (y, colour) stops, flat beyond the ends."""
    column = Image.new("RGB", (1, BASE))
    for y in range(BASE):
        if y <= stops[0][0]:
            colour = stops[0][1]
        elif y >= stops[-1][0]:
            colour = stops[-1][1]
        else:
            for (y0, c0), (y1, c1) in zip(stops, stops[1:]):
                if y0 <= y <= y1:
                    colour = lerp(c0, c1, (y - y0) / (y1 - y0))
                    break
        column.putpixel((0, y), colour)
    return column.resize((S, S), Image.BILINEAR)


def disc(d, cx, cy, r, fill):
    d.ellipse([px(cx - r), px(cy - r), px(cx + r), px(cy + r)], fill=fill)


def gate():
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    cx = BASE / 2
    half = SLOT_WIDTH / 2

    for x in (cx - SLOT_GAP, cx, cx + SLOT_GAP):
        d.rounded_rectangle([px(x - half), px(SLOT_TOP),
                             px(x + half), px(SLOT_FOOT)],
                            radius=px(half), fill=255)
    d.rounded_rectangle([px(cx - SLOT_GAP - half), px(BAR_Y - half),
                         px(cx + SLOT_GAP + half), px(BAR_Y + half)],
                        radius=px(half), fill=255)

    # The knob, in first: over the top of the left slot, centred on its round
    # end.
    disc(d, cx - SLOT_GAP, SLOT_TOP + half, KNOB_RADIUS, 255)
    return m


def build_master():
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    body = Image.new("L", (S, S), 0)
    ImageDraw.Draw(body).rounded_rectangle(
        [px(BODY_INSET), px(BODY_INSET),
         px(BASE - BODY_INSET), px(BASE - BODY_INSET)],
        radius=px(CORNER), fill=255)

    # ── Shadow ────────────────────────────────────────────────────────────────
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(ImageChops.offset(body, 0, px(10))
                    .point(lambda v: v * 78 // 255))
    canvas = Image.alpha_composite(
        canvas, shadow.filter(ImageFilter.GaussianBlur(px(10))))

    # ── Ground ────────────────────────────────────────────────────────────────
    ground = vertical_gradient(GROUND).convert("RGBA")
    ground.putalpha(body)
    canvas = Image.alpha_composite(canvas, ground)

    # ── Glyph ─────────────────────────────────────────────────────────────────
    glyph = gate()

    # Its shadow falls down and to the right, and stays on the ground.
    cast = Image.new("RGBA", (S, S), GLYPH_SHADOW + (0,))
    cast.putalpha(ImageChops.offset(glyph, px(12), px(22))
                  .point(lambda v: v * 175 // 255))
    cast = cast.filter(ImageFilter.GaussianBlur(px(18)))
    cast.putalpha(ImageChops.multiply(cast.getchannel("A"), body))
    canvas = Image.alpha_composite(canvas, cast)

    # The fold: lit left of the vertical centre line, shade right of it.
    right = Image.new("L", (S, S), 0)
    ImageDraw.Draw(right).rectangle([px(BASE / 2), 0, S, S], fill=255)
    planes = Image.composite(vertical_gradient(SHADE), vertical_gradient(LIT),
                             right).convert("RGBA")
    planes.putalpha(glyph)
    return Image.alpha_composite(canvas, planes)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_out = os.path.normpath(
        os.path.join(here, "..", "..", "assets", "AppIcon.icns"))

    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=default_out,
                    help="the .icns file to write")
    args = ap.parse_args()

    if not os.path.isdir(os.path.dirname(os.path.abspath(args.out))):
        sys.exit(f"make-appicon: no such directory: {os.path.dirname(args.out)}")

    master = build_master()
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        for points, scale in ICONSET:
            suffix = "@2x" if scale == 2 else ""
            size = points * scale
            name = f"icon_{points}x{points}{suffix}.png"
            master.resize((size, size), Image.LANCZOS).save(
                os.path.join(iconset, name), "PNG")
        subprocess.run(["iconutil", "-c", "icns", "-o", args.out, iconset],
                       check=True)
    print(f"  wrote {os.path.relpath(args.out)}")


if __name__ == "__main__":
    main()
