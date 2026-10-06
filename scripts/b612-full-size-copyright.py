#!/usr/bin/env python3
#
# Draw B612's copyright and registered signs at full size.
#
# B612 1.008 (https://github.com/polarsys/b612, still the latest release) draws © and ® as superscripts
# in all four faces: a circle 940 units across (47 % of the em) hung from the cap height, its foot 577
# units above the baseline, so "© swisstopo" reads like a footnote mark. This scales each sign
# uniformly until it is as tall as the capital O (baseline to cap height, with the O's overshoot) and
# gives it the O's side bearings, evened out since the sign is round. In B612 the advance grows to
# fit. In B612 Mono the cell stays 1300 units (that is what keeps a column straight), so the sign is
# only as large as the cell allows with those bearings, and sits centred in the cell and on the cap
# height.
#
# Nothing else moves: every other glyph, advance and hint, and the PostScript names the app asks for
# ("B612-Regular", "B612-Bold", "B612Mono-Regular", "B612Mono-Bold") are untouched; no kerning pair
# involves the two signs. They carry no hinting in 1.008; any they had would be dropped, as it would
# no longer fit the outline. The name table records the change (version string, unique id,
# description), as the SIL OFL 1.1 expects of a modified version; the licence declares no Reserved
# Font Name, so the family keeps its name.
#
# Run it on the bundled files; on files it has already patched it changes nothing and says so. To
# rebuild them from the upstream 1.008 files, centre the Mono punctuation FIRST, then run this on all
# four (it refuses an upstream B612 Mono, which the punctuation script would otherwise patch without
# recording it in the name table):
#
#   python3 -m venv /tmp/fonttools && /tmp/fonttools/bin/pip install fonttools
#   /tmp/fonttools/bin/python scripts/center-b612-mono-punctuation.py AeroCheck/Resources/B612Mono-*.ttf
#   /tmp/fonttools/bin/python scripts/b612-full-size-copyright.py AeroCheck/Resources/B612*.ttf
#
# The upstream files: https://github.com/polarsys/b612/tree/48ac6ba/fonts/ttf (tag 1.008).
# `TypographyTests` checks the result in the app, with CoreText's own glyph bounds.

import hashlib
import sys

from fontTools.misc.roundTools import otRound
from fontTools.misc.timeTools import timestampFromString
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._g_l_y_f import GlyphCoordinates
from fontTools.ttLib.tables.ttProgram import Program

# The signs to redraw, by code point (the glyph names come from the font's cmap)
TARGETS = {
    0x00A9: "copyright sign",
    0x00AE: "registered sign",
}

# The letter whose height and side bearings they take
MODEL = 0x004F  # O

# The upstream 1.008 files this takes as they are
UPSTREAM_SHA256 = {
    "139dce659100a83bf95b48474696e448bee95631ef84fd3d0437ced2bf33cf73": "B612-Regular.ttf",
    "91749541ac7b2c328b58832b7e2c4df809d7e2ba38d62a3a5aa3f8e38b271814": "B612-Bold.ttf",
}

# The upstream B612 Mono files, which want center-b612-mono-punctuation.py first
UPSTREAM_MONO_SHA256 = {
    "b98cb96cc8a6206dae08c063d60902df7e6d40f86139ebdb97256704253c9c69": "B612Mono-Regular.ttf",
    "b467b1d19fdabed42be51d87e38c86645ceeff2f828f294775188d00d1fd68ca": "B612Mono-Bold.ttf",
}

# What center-b612-mono-punctuation.py writes in the version string. That script only takes the
# upstream files, so a B612 Mono carrying it is 1.008 with its punctuation centred.
PUNCTUATION_MARK = "AeroCheck: punctuation centred"

# Where 1.008 draws both signs, in every face (font units, of 2000): the superscript's foot and top
SUPERSCRIPT = (577, 1517)

# What the name table says once patched (MARK is how a patched file is recognised)
MARK = "full-size copyright and registered signs"
DESCRIPTION = ("{family} 1.008, modified for AeroCheck (https://github.com/fetzu/AeroCheck): the "
               "copyright and registered signs are drawn at full size instead of as superscripts, "
               "everything else unchanged. Made by scripts/b612-full-size-copyright.py.")
# Added to a description the punctuation script already wrote
ADDENDUM = ("The copyright and registered signs are drawn at full size instead of as superscripts "
            "(scripts/b612-full-size-copyright.py).")

# A fixed modification date, so the same input always gives the same bytes
MODIFIED = timestampFromString("Tue Oct  6 00:00:00 2026")


def bounds(font, name):
    """The glyph's outline bounds as (xMin, yMin, xMax, yMax), recomputed from its points."""
    glyph = font["glyf"][name]
    glyph.recalcBounds(font["glyf"])
    return glyph.xMin, glyph.yMin, glyph.xMax, glyph.yMax


def set_name(font, name_id, text):
    """Write one name record on every platform/encoding/language the font already carries it on."""
    table = font["name"]
    records = [r for r in table.names if r.nameID == name_id]
    # A record the font lacks (the description) goes where the family name lives
    if not records:
        records = [r for r in table.names if r.nameID == 1]
    for record in records:
        table.setName(text, name_id, record.platformID, record.platEncID, record.langID)


def redraw(font, name, model, monospaced):
    """Scale one sign up to the model letter's height, or to its cell in B612 Mono, and place it."""
    glyph = font["glyf"][name]
    advance, _ = font["hmtx"][name]
    x_min, y_min, x_max, y_max = bounds(font, name)
    o_x_min, o_y_min, o_x_max, o_y_max = bounds(font, model)
    o_advance, _ = font["hmtx"][model]

    # The O's two side bearings, evened out: the sign is a circle
    bearing = (o_x_min + (o_advance - o_x_max)) // 2
    scale = (o_y_max - o_y_min) / (y_max - y_min)
    if monospaced:
        # The cell is fixed: no larger than fits between two bearings
        scale = min(scale, (advance - 2 * bearing) / (x_max - x_min))
    width = (x_max - x_min) * scale
    height = (y_max - y_min) * scale
    if not monospaced:
        advance = otRound(width) + 2 * bearing
    # Centred in the advance, and between the O's foot and top (on them, unless the cell kept it smaller)
    left = (advance - width) / 2
    bottom = (o_y_min + o_y_max - height) / 2

    # The same factor on both axes, so the shape stays the one 1.008 drew
    glyph.coordinates = GlyphCoordinates(
        [(otRound(left + (x - x_min) * scale), otRound(bottom + (y - y_min) * scale))
         for x, y in glyph.coordinates])
    # Instructions written for the small outline would no longer fit the large one
    if hasattr(glyph, "program") and glyph.program.getBytecode():
        glyph.program = Program()
        glyph.program.fromBytecode(b"")
        print("    dropped its hinting instructions")
    x_min, y_min, x_max, y_max = bounds(font, name)
    font["hmtx"][name] = (advance, x_min)
    return scale, (x_min, y_min, x_max, y_max), advance


def device_metrics(font, name):
    """Keep the per-size tables right for a glyph that now runs unhinted with a new advance."""
    advance, _ = font["hmtx"][name]
    units_per_em = font["head"].unitsPerEm
    # hdmx: the advance in whole pixels at each size it lists, rounded half up as the font's own are
    if "hdmx" in font:
        table = font["hdmx"].hdmx
        for ppem, widths in table.items():
            widths = dict(widths)
            widths[name] = int(advance * ppem / units_per_em + 0.5)
            table[ppem] = widths
    # LTSH: an unhinted glyph scales linearly from the first pixel
    if "LTSH" in font:
        font["LTSH"].yPels[name] = 1


def patch(path):
    """Redraw © and ® at full size in one B612 file, in place. Returns True if the file changed."""
    with open(path, "rb") as file:
        digest = hashlib.sha256(file.read()).hexdigest()
    font = TTFont(path, recalcBBoxes=True, recalcTimestamp=False)
    version = font["name"].getDebugName(5) or ""
    monospaced = bool(font["post"].isFixedPitch)

    # Our own output: leave its bytes alone
    if MARK in version:
        print(f"{path}: already patched, nothing to do")
        return False
    # B612 Mono comes after the punctuation script, never before
    if digest in UPSTREAM_MONO_SHA256:
        sys.exit(f"{path}: upstream B612 Mono, run scripts/center-b612-mono-punctuation.py on it first")
    # Refuse anything that is neither upstream 1.008 nor B612 Mono with its punctuation centred
    if digest not in UPSTREAM_SHA256 and not (monospaced and PUNCTUATION_MARK in version):
        sys.exit(f"{path}: not B612 1.008 as published upstream, nor B612 Mono with its punctuation "
                 f"centred (sha256 {digest}), refusing to guess")

    cmap = font.getBestCmap()
    model = cmap[MODEL]
    names = []
    for codepoint, label in TARGETS.items():
        name = cmap[codepoint]
        glyph = font["glyf"][name]
        # A composite would scale its offsets, not its components, and neither sign is one in 1.008
        if glyph.isComposite():
            sys.exit(f"{path}: {name} is a composite glyph, this script only scales simple ones")
        _, y_min, _, y_max = bounds(font, name)
        if (y_min, y_max) != SUPERSCRIPT:
            sys.exit(f"{path}: {name} spans {y_min}..{y_max}, not the 1.008 superscript, refusing to guess")
        scale, (x_min, y_min, x_max, y_max), advance = redraw(font, name, model, monospaced)
        device_metrics(font, name)
        print(f"  {name:15} ({label}) scaled x{scale:.3f}, ink now {x_min}..{x_max} of {advance}, "
              f"{y_min}..{y_max} high")
        names.append(name)

    # Say what was done where a font says who made it and which version it is
    unique_id = font["name"].getDebugName(3)
    if "AeroCheck" not in unique_id:
        set_name(font, 3, f"{unique_id}; AeroCheck")
    if "AeroCheck" in version:
        set_name(font, 5, f"{version}; {MARK}")
    else:
        set_name(font, 5, f"{version}; AeroCheck: {MARK}")
    description = font["name"].getDebugName(10)
    if description:
        set_name(font, 10, f"{description} {ADDENDUM}")
    else:
        set_name(font, 10, DESCRIPTION.format(family=font["name"].getDebugName(1)))
    font["head"].modified = MODIFIED
    font.save(path)
    print(f"{path}: patched")
    return True


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: b612-full-size-copyright.py B612-Regular.ttf [B612-Bold.ttf B612Mono-Bold.ttf ...]")
    for path in sys.argv[1:]:
        print(path)
        patch(path)


if __name__ == "__main__":
    main()
