#!/usr/bin/env python3
#
# Centre B612 Mono's punctuation in its cell.
#
# B612 Mono 1.008 (https://github.com/polarsys/b612, still the latest release) kept the outlines of
# : ; . , ' and · from the proportional B612 and widened their advance to the monospaced 1300 units
# without moving them, so each one sits at the left of its cell and every number reads "00: 44",
# "122. 050", "1' 860" (upstream issue #31, open since 2024; iOS writes Swiss grouping with the plain
# apostrophe). This shifts those glyphs sideways until their ink is centred in their advance, and does
# the same for the typographic ’, which was only a few units off.
#
# Nothing else moves: every advance stays 1300 units (that is what keeps a changing number from
# jittering), the shapes, the hinting and the PostScript names the app asks for ("B612Mono-Regular",
# "B612Mono-Bold") are untouched, and the proportional B612 is not this script's business. The name
# table records the change (version string, unique id, description), as the SIL OFL 1.1 expects of a
# modified version; the licence declares no Reserved Font Name, so the family keeps its name.
#
# The website's copy of the app's script (main: scripts/center-b612-mono-punctuation.py, PR #246), for
# the site's own B612 Mono: 217-glyph woff2 subsets of 1.008, which carry the same bug. Run it on those
# subsets as the site shipped them (checked by SHA-256) to rebuild the patched ones; on files it has
# already patched it changes nothing and says so. The files stay woff2:
#
#   python3 -m venv /tmp/fonttools && /tmp/fonttools/bin/pip install fonttools brotli
#   /tmp/fonttools/bin/python scripts/center-b612-mono-punctuation.py public/fonts/b612-mono-*.woff2
#
# public/fonts/FONTLOG-B612.txt records the hashes before and after.

import hashlib
import sys

from fontTools.misc.timeTools import timestampFromString
from fontTools.ttLib import TTFont

# The characters to centre, by code point (the glyph names come from the font's cmap)
TARGETS = {
    0x003A: "colon",
    0x003B: "semicolon",
    0x002E: "period",
    0x002C: "comma",
    0x0027: "apostrophe",
    0x00B7: "middle dot",
    0x2019: "right single quote",
}

# The 1.008 subsets the site shipped before this script
UPSTREAM_SHA256 = {
    "36625fd3471c28b27ecbff1e3c1ed80e6b4bb62df800542df521e9cd7825ea3b": "b612-mono-regular.woff2",
    "76dc8f1668f8ccfd2d3a4360133ec65c51644914b56f8e1b20527b4a24b75a38": "b612-mono-bold.woff2",
}

# What the name table says once patched (MARK is how a patched file is recognised)
MARK = "AeroCheck"
VERSION_SUFFIX = "; AeroCheck: punctuation centred"
DESCRIPTION = ("B612 Mono 1.008 (subset), modified for AeroCheck (https://github.com/fetzu/AeroCheck): the colon, "
               "semicolon, period, comma, apostrophe, middle dot and right single quote are centred in "
               "their cell, advances and everything else unchanged. "
               "Made by scripts/center-b612-mono-punctuation.py.")

# A fixed modification date, so the same input always gives the same bytes
MODIFIED = timestampFromString("Thu Oct  1 00:00:00 2026")

# Ink this close to the centre (font units, of 1300) counts as centred
TOLERANCE = 1


def ink_bounds(font, name):
    """The glyph's outline bounds as (xMin, xMax), recomputed from its points."""
    glyph = font["glyf"][name]
    glyph.recalcBounds(font["glyf"])
    return glyph.xMin, glyph.xMax


def set_name(font, name_id, text):
    """Write one name record on every platform/encoding/language the font already carries it on."""
    table = font["name"]
    records = [r for r in table.names if r.nameID == name_id]
    # A record the font lacks (the description) goes where the family name lives
    if not records:
        records = [r for r in table.names if r.nameID == 1]
    for record in records:
        table.setName(text, name_id, record.platformID, record.platEncID, record.langID)


def patch(path):
    """Centre the punctuation of one B612 Mono file, in place. Returns True if the file changed."""
    with open(path, "rb") as file:
        digest = hashlib.sha256(file.read()).hexdigest()
    font = TTFont(path, recalcBBoxes=True, recalcTimestamp=False)
    version = font["name"].getDebugName(5) or ""
    already_patched = MARK in version

    # Refuse anything that is neither upstream 1.008 nor our own output
    if digest not in UPSTREAM_SHA256 and not already_patched:
        sys.exit(f"{path}: not the site's B612 Mono 1.008 subset (sha256 {digest}), refusing to guess")

    cmap = font.getBestCmap()
    hmtx = font["hmtx"]
    glyf = font["glyf"]
    changed = False

    for codepoint, label in TARGETS.items():
        name = cmap[codepoint]
        glyph = glyf[name]
        # A composite would drag its components along, and none of these is one in 1.008
        if glyph.isComposite():
            sys.exit(f"{path}: {name} is a composite glyph, this script only moves simple ones")
        advance, _ = hmtx[name]
        x_min, x_max = ink_bounds(font, name)
        shift = round(advance / 2 - (x_min + x_max) / 2)
        if abs(shift) <= TOLERANCE:
            print(f"  {name:15} ({label}) already centred")
            continue
        # Move every point by the same amount: same shape, same hinting, same advance
        glyph.coordinates.translate((shift, 0))
        x_min, x_max = ink_bounds(font, name)
        hmtx[name] = (advance, x_min)
        print(f"  {name:15} ({label}) moved {shift:+d} units, ink now {x_min}..{x_max} of {advance}")
        changed = True

    # Nothing moved on a file we already patched: leave its bytes alone
    if not changed and already_patched:
        print(f"{path}: already patched, nothing to do")
        return False

    # Say what was done where a font says who made it and which version it is
    if not already_patched:
        unique_id = font["name"].getDebugName(3)
        set_name(font, 3, f"{unique_id}; {MARK}")
        set_name(font, 5, f"{version}{VERSION_SUFFIX}")
        set_name(font, 10, DESCRIPTION)
    font["head"].modified = MODIFIED
    font.save(path)
    print(f"{path}: patched")
    return True


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: center-b612-mono-punctuation.py b612-mono-regular.woff2 [b612-mono-bold.woff2 ...]")
    for path in sys.argv[1:]:
        print(path)
        patch(path)


if __name__ == "__main__":
    main()
