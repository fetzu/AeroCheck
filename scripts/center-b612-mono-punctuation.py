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
# Run it on the upstream 1.008 files (checked by SHA-256) to rebuild the patched ones; on files it
# has already patched it changes nothing and says so:
#
#   python3 -m venv /tmp/fonttools && /tmp/fonttools/bin/pip install fonttools
#   /tmp/fonttools/bin/python scripts/center-b612-mono-punctuation.py AeroCheck/Resources/B612Mono-*.ttf
#
# The upstream files: https://github.com/polarsys/b612/tree/48ac6ba/fonts/ttf (tag 1.008).
# `TypographyTests` checks the result in the app, with CoreText's own glyph bounds.

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

# The upstream 1.008 files this was written against
UPSTREAM_SHA256 = {
    "b98cb96cc8a6206dae08c063d60902df7e6d40f86139ebdb97256704253c9c69": "B612Mono-Regular.ttf",
    "b467b1d19fdabed42be51d87e38c86645ceeff2f828f294775188d00d1fd68ca": "B612Mono-Bold.ttf",
}

# What the name table says once patched (MARK is how a patched file is recognised)
MARK = "AeroCheck"
VERSION_SUFFIX = "; AeroCheck: punctuation centred"
DESCRIPTION = ("B612 Mono 1.008, modified for AeroCheck (https://github.com/fetzu/AeroCheck): the colon, "
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
        sys.exit(f"{path}: not B612 Mono 1.008 as published upstream (sha256 {digest}), refusing to guess")

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
        sys.exit("usage: center-b612-mono-punctuation.py B612Mono-Regular.ttf [B612Mono-Bold.ttf ...]")
    for path in sys.argv[1:]:
        print(path)
        patch(path)


if __name__ == "__main__":
    main()
