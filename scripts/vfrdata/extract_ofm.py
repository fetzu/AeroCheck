#!/usr/bin/env python3
### [   extract_ofm.py || traffic circuits, VFR routes and reporting points from open flightmaps, for aerocheck.app   ] ###
"""
Fetches the open flightmaps (OFM) snapshot of each configured region for the AIRAC cycle in force, keeps the
traffic circuits, VFR arrivals and departures (with their sector polygons), the VFR reporting points and the
runway designators, cleans them up and publishes one small JSON file per country plus an index under
public/data/ofm/v1/. The app downloads those files; it never talks to OFM itself.

Usage: extract_ofm.py [-h] [-v] [--out DIR] [--date YYYY-MM-DD] [--regions CC,CC] [--force] [--allow-drop]

  -v                 Verbose: say what was dropped and flagged, region by region.
  --out DIR          Where to write (default: public/data/ofm/v1 in this checkout).
  --date YYYY-MM-DD  Pretend today is that day (picks the AIRAC cycle; for tests and catch-up runs).
  --regions CC,CC    Only these countries (default: all of REGIONS).
  --force            Ignore the stored ETags and re-extract (after a change to this script).
  --allow-drop       Accept a region that lost more than 30% of its circuits or points, or all of its
                     procedures, once a human has checked OFM really did that. Never skips the parse or
                     size checks.

Exit status: 0 when every region is published or rightly left alone, 1 when a region stopped (parse error,
validation gate, fetch failure: its last good file is kept), 2 on bad arguments.

The OFMX "Prc" (procedure) element is not part of the public OFMX schema, so the format can drift without
notice: that is what the validation gates are for. Data: © open flightmaps association (openflightmaps.org).
"""

## [ IMPORTS be imports ]
import argparse
import hashlib
import json
import math
import os
import re
import sys
import unicodedata
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from datetime import date

import vfrcommon
from vfrcommon import airac_for, http_get, strong_etag

## [ CONFIGURATION ]
# One entry per OFM region we publish: OFM region code, ISO country, bucket folder, file stem, OpenAIP export
# prefix. France and Italy are nearly empty in OFM (one circuit in FR); they can join later.
REGIONS = [
    {"region": "LSAS", "country": "CH", "folder": "lsas", "file": "ofmx_ls", "openaip": "ch"},
    {"region": "LOVV", "country": "AT", "folder": "lovv", "file": "ofmx_lo", "openaip": "at"},
    {"region": "ED", "country": "DE", "folder": "ed", "file": "ofmx_ed", "openaip": "de"},
    {"region": "LKAA", "country": "CZ", "folder": "lkaa", "file": "ofmx_lk", "openaip": "cz"},
]
# The per-country snapshot WITH procedures is the unlisted isolated .xml (the advertised zip has none)
SNAPSHOTURL = "https://snapshots.openflightmaps.org/live/{airac}/ofmx/{folder}/latest/isolated/{file}.xml"
# OpenAIP's keyless public export, the reporting points the app already shows
OPENAIPURL = "https://s3.openaip.net/openaip-system-exports/{cc}_rpp.geojson"
# Where the app finds the files
PUBLICBASE = "https://aerocheck.app/data/ofm/v1/"
OUTDIR = os.path.join(vfrcommon.REPOROOT, "public", "data", "ofm", "v1")

SCHEMA = 1
SOURCE = "open flightmaps"
ATTRIBUTION = "© open flightmaps association (openflightmaps.org)"
# OFM's "Open flightmaps error reporting" form (the "Report a mistake" button of their map) and the description
# field the app pre-fills; kept here so it can change without an app release
REPORTFORM = {
    "url": "https://docs.google.com/forms/d/e/1FAIpQLSeBiqRbqioUaAp6H-FUtYMFduLGQmzOm1G3Dxyh2XALl5r3Nw/viewform",
    "field": "entry.284686808",
}
REPORTMAIL = "info@openflightmaps.org"

# Display simplification of every line and polygon (Douglas-Peucker), and the published precision (~1 m)
SIMPLIFYMETERS = 10.0
DECIMALS = 5
# Hygiene thresholds (ofm-investigation.md §6)
TWINNM = 0.05                    # two procedures whose skeletons stay this close, vertex by vertex, are twins
CIRCUITHEIGHTFT = (400, 2500)    # a circuit altitude outside this band above the aerodrome is not believed
POINTSAMENM = 0.05               # an inline leg point this close to a published point is that point
# Reporting points vs OpenAIP (ofm-investigation.md §3)
OPENAIPANYNAMENM = 0.1           # this close, same point whatever the names
OPENAIPSAMENAMENM = 0.5          # this close, same point if the names agree
OPENAIPDISPUTEDNM = 3.0          # same name but this far: the same point, position disputed (flagged) ...
OPENAIPDISPUTEDSHORTNM = 1.0     # ... or this far for a one- or two-letter name ("S" of the next field over)
# Validation gates
MAXFILEBYTES = 2 * 1024 * 1024   # a country file over 2 MB means something went wrong
MAXDROP = 0.30                   # circuits or points down more than 30% vs the published file
GATEMINCOUNT = 10                # ... measured only from this many up (small numbers swing)

KINDS = {"TRAFFIC_CIRCUIT": "circuit", "VFR_ARR": "arr", "VFR_DEP": "dep"}
KINDORDER = {"circuit": 0, "arr": 1, "dep": 2}
USES = {"FIXED_WING": "fw", "HELICOPTER": "heli"}
POINTKINDS = {"VFR-RP": "rp", "VFR-MRP": "mrp", "VFR-ENR": "enr", "VFR-HELI": "heli", "VFR-GLDR": "gld"}
# Leg sector polygons we keep; "Leg Label" sectors only place a label, even the few that carry a box
AREAKINDS = {"VFR Corridor": "corridor", "Noise Abatement Area": "noise", "": "area"}

# Category from the procedure name: usageType only knows FIXED_WING and HELICOPTER, so a glider circuit is
# "FIXED_WING" named "TFC GLIDER". First match wins, except glider and UL, which combine.
GLIDERNAME = re.compile(r"GLID|\bGLIER\b|\bGLD\b|SEGEL|SEGLER|PLANEUR|ALIANTE|\bWINCH|\bWINDE|\bTMG\b")
ULNAME = re.compile(r"\bULM?\b|ULTRA")
GYRONAME = re.compile(r"GYRO|TRAGSCHR")
HELINAME = re.compile(r"HELI|\bHEL\b|\(H\)|HUBSCHR")
# Heavy = the powered variants for bigger aircraft: multi-engine, retractable, turbine, "> 2000 KG", ">5.7 T"
# (but not "ACFT < 5.7T", which is the light one)
HEAVYNAME = re.compile(r"MULTI|RETRACT|TURBO|\bJETS?\b|TWIN|HEAVY|MEHRMOT|>\s*\d")
# A twin carrying one of these names is the leftover, whatever the order in the file
PLACEHOLDERNAME = re.compile(r"NEW PROCEDURE|^TEST\b|\bCOPY\b|\bDRAFT\b|^\s*$", re.IGNORECASE)

# Phonetic alphabet, for "SIERRA" = "S" and "ECHO1" = "E1" when comparing point names
PHONETIC = {
    "ALPHA": "A", "ALFA": "A", "BRAVO": "B", "CHARLIE": "C", "DELTA": "D", "ECHO": "E", "FOXTROT": "F",
    "FOXTROTT": "F", "GOLF": "G", "HOTEL": "H", "INDIA": "I", "JULIET": "J", "JULIETT": "J", "KILO": "K",
    "LIMA": "L", "MIKE": "M", "NOVEMBER": "N", "OSCAR": "O", "PAPA": "P", "QUEBEC": "Q", "ROMEO": "R",
    "SIERRA": "S", "TANGO": "T", "UNIFORM": "U", "VICTOR": "V", "WHISKEY": "W", "WHISKY": "W", "XRAY": "X",
    "YANKEE": "Y", "ZULU": "Z",
}

VERBOSE = False


class ExtractError(Exception):
    """A region could not be published this run; its last good file stays."""


## [ SMALL HELPERS ]
def say(message):
    print(message, flush=True)


def debug(message):
    if VERBOSE is True: print("    " + message, flush=True)


def text(el, path):
    """findtext, stripped, never None."""
    return (el.findtext(path) or "").strip()


def parse_coordinate(value, positive, negative):
    """'47.39250000N' -> 47.3925, '007.02888889E' -> 7.02888889 (S and W negative)."""
    value = value.strip()
    if not value or value[-1] not in (positive, negative):
        raise ValueError(f"bad coordinate {value!r}")
    number = float(value[:-1])
    return -number if value[-1] == negative else number


def pos_list(value):
    """A GML posList 'lon,lat lon,lat …' as [(lon, lat), …]."""
    out = []
    for pair in (value or "").split():
        lon, lat = pair.split(",")[:2]
        out.append((float(lon), float(lat)))
    return out


def dedupe(points):
    """Drops consecutive repeats (OFM doubles every Bézier joint)."""
    out = []
    for p in points:
        if not out or abs(out[-1][0] - p[0]) > 1e-9 or abs(out[-1][1] - p[1]) > 1e-9:
            out.append(p)
    return out


def nm_between(a, b):
    """Great-circle distance in nautical miles between two (lon, lat)."""
    lat1, lat2 = math.radians(a[1]), math.radians(b[1])
    dlat, dlon = lat2 - lat1, math.radians(b[0] - a[0])
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * 3440.065 * math.asin(min(1.0, math.sqrt(h)))


def simplify(points, tolerance_m=SIMPLIFYMETERS):
    """
    Douglas-Peucker on a local equirectangular projection (plenty at aerodrome scale). Keeps both ends; drops
    every vertex closer than the tolerance to the simplified line. Display only: never measure on the result.
    """
    if len(points) < 3:
        return list(points)
    kx = 111320.0 * math.cos(math.radians(points[0][1]))
    ky = 110540.0
    xy = [(lon * kx, lat * ky) for lon, lat in points]
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        ax, ay = xy[first]
        bx, by = xy[last]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy)
        farthest, distance = -1, 0.0
        for i in range(first + 1, last):
            px, py = xy[i]
            # Distance to the segment's line, or to its start when the segment has no length (a closed loop)
            d = abs(dy * (px - ax) - dx * (py - ay)) / length if length > 0 else math.hypot(px - ax, py - ay)
            if d > distance:
                farthest, distance = i, d
        if distance > tolerance_m:
            keep[farthest] = True
            stack += [(first, farthest), (farthest, last)]
    return [p for p, k in zip(points, keep) if k]


def publish_line(points):
    """Simplified, rounded to DECIMALS, repeats dropped again after rounding, as [[lon, lat], …]."""
    rounded = dedupe([(round(lon, DECIMALS), round(lat, DECIMALS)) for lon, lat in simplify(points)])
    return [[lon, lat] for lon, lat in rounded]


def category(name, usage):
    """glider | ul | glider+ul | gyro | heli | heavy | None (= a plain powered circuit or route)."""
    upper = name.upper()
    glider = bool(GLIDERNAME.search(upper))
    ul = bool(ULNAME.search(upper))
    if glider and ul:
        return "glider+ul"
    if glider:
        return "glider"
    if ul:
        return "ul"
    if GYRONAME.search(upper):
        return "gyro"
    if usage == "HELICOPTER" or HELINAME.search(upper):
        return "heli"
    if HEAVYNAME.search(upper):
        return "heavy"
    return None


def canon_name(name):
    """
    A reporting point's name reduced for comparison: upper case, umlauts and accents folded, punctuation gone,
    a leading "ABM" (abeam) dropped and a leading phonetic word folded to its letter (SIERRA = S, ECHO1 = E1).
    """
    upper = (name or "").upper().replace("Ä", "AE").replace("Ö", "OE").replace("Ü", "UE")
    upper = "".join(ch for ch in unicodedata.normalize("NFD", upper) if unicodedata.category(ch) != "Mn")
    upper = re.sub(r"[^A-Z0-9]", "", upper)
    upper = re.sub(r"^ABM", "", upper)
    for word in sorted(PHONETIC, key=len, reverse=True):
        rest = upper[len(word):]
        if upper.startswith(word) and (rest == "" or rest.isdigit()):
            return PHONETIC[word] + rest
    return upper


def same_point_name(ofm_name, openaip_name):
    """Names that designate the same point: equal once reduced, one a 4+ letter prefix of the other (PALEX vs
    PALEXPO), or OpenAIP's 5-letter code built on OFM's short name (GE vs GEGEN, S vs SLUGA)."""
    a, b = canon_name(ofm_name), canon_name(openaip_name)
    if not a or not b:
        return False
    if a == b:
        return True
    if min(len(a), len(b)) >= 4 and (a.startswith(b) or b.startswith(a)):
        return True
    return len(b) == 5 and b.isalpha() and b.startswith(a)


def flag(flags, kind, ad, ident, name, detail, other=None):
    """One line in index.json's flags: what looked wrong, where, and the OFM id to quote in an error report."""
    entry = {"type": kind, "ad": ad, "id": ident, "name": name, "detail": detail}
    if other:
        entry["with"] = other
    flags.append(entry)


## [ PARSING the OFMX snapshot ]
def parse_snapshot(stream):
    """
    Streams an isolated OFMX snapshot (iterparse, every top-level element cleared once read, so DE's 59 MB
    never sits in memory) and returns what we use of it, still raw: aerodrome elevations, procedures,
    published points, the reporting points that only exist inline in procedure legs, runway ends.
    Raises ExtractError when the stream isn't an OFMX snapshot or isn't well-formed XML.
    """
    raw = {"created": None, "elevations": {}, "procedures": [], "points": [], "legpoints": [],
           "runways": defaultdict(dict), "malformed": [], "skipped": Counter()}
    root = None
    depth = 0
    try:
        for event, el in ET.iterparse(stream, events=("start", "end")):
            if event == "start":
                if root is None:
                    root = el
                    if root.tag != "OFMX-Snapshot":
                        raise ExtractError(f"not an OFMX snapshot (root element <{root.tag}>)")
                    raw["created"] = root.get("created") or root.get("effective")
                depth += 1
                continue
            depth -= 1
            if depth != 1:
                continue
            # A top-level feature is complete: read it, then let it go
            try:
                if el.tag == "Prc":
                    read_procedure(el, raw)
                elif el.tag == "Dpn":
                    read_point(el, raw)
                elif el.tag == "Ahp":
                    read_aerodrome(el, raw)
                elif el.tag == "Rdn":
                    read_runway_end(el, raw)
            except (ValueError, IndexError) as error:
                # One broken feature is reported and skipped; many of them trip the validation gates
                raw["malformed"].append((el.tag, element_mid(el), str(error)))
            root.clear()
    except ET.ParseError as error:
        raise ExtractError(f"OFMX parse error: {error}") from error
    if root is None:
        raise ExtractError("empty OFMX stream")
    return raw


def element_mid(el):
    uid = el.find(f"{el.tag}Uid")
    return uid.get("mid") if uid is not None else None


def read_aerodrome(el, raw):
    ident = text(el, "AhpUid/codeId")
    value = text(el, "valElev")
    if ident and value:
        raw["elevations"][ident] = float(value) * (3.28084 if text(el, "uomDistVer") == "M" else 1.0)


def read_runway_end(el, raw):
    ad = text(el, "RdnUid/RwyUid/AhpUid/codeId")
    runway = el.find("RdnUid/RwyUid")
    designator = text(el, "RdnUid/txtDesig").upper().replace(" ", "")
    if ad and runway is not None and designator:
        raw["runways"][(ad, runway.get("mid"))][designator] = True


def read_point(el, raw):
    kind = POINTKINDS.get(text(el, "codeType"))
    if kind is None:
        raw["skipped"]["point " + (text(el, "codeType") or "untyped")] += 1
        return
    uid = el.find("DpnUid")
    raw["points"].append({
        "id": uid.get("mid"),
        "name": text(el, "txtName") or text(el, "DpnUid/codeId"),
        "kind": kind,
        "ad": text(el, "AhpUidAssoc/codeId") or None,
        "lat": parse_coordinate(text(el, "DpnUid/geoLat"), "N", "S"),
        "lon": parse_coordinate(text(el, "DpnUid/geoLong"), "E", "W"),
    })


def read_procedure(el, raw):
    ad = text(el, "PrcUid/AhpUid/codeId")
    code_type = text(el, "codeType")
    # Every procedure's legs may name reporting points, even the kinds we don't publish (transits, holds)
    for leg_point in el.findall("Leg/entry/DpnUid") + el.findall("Leg/exit/DpnUid"):
        kind = POINTKINDS.get(text(leg_point, "codeType"))
        if kind is not None:
            raw["legpoints"].append({
                "name": text(leg_point, "txtName") or text(leg_point, "codeId"), "kind": kind, "ad": ad or None,
                "lat": parse_coordinate(text(leg_point, "geoLat"), "N", "S"),
                "lon": parse_coordinate(text(leg_point, "geoLong"), "E", "W"),
            })
    if code_type not in KINDS:
        raw["skipped"]["procedure " + (code_type or "untyped")] += 1
        return
    uid = el.find("PrcUid")
    if uid is None or not uid.get("mid") or not ad:
        raise ValueError("procedure without an id or an aerodrome")
    name = " ".join(text(el, "txtName").split())
    usage = text(el, "usageType")
    procedure = {
        "id": uid.get("mid"), "ad": ad, "kind": KINDS[code_type], "name": name,
        "use": USES.get(usage), "cat": category(name, usage),
        "curve": dedupe(pos_list(text(el, "_beztrajectory/gmlPosList"))),
        "skeleton": dedupe(pos_list(text(el, "_sceletonPath/gmlPosList"))),
        "areas": [], "altitude": None,
    }
    for sector in el.findall("Leg/sector"):
        kind = AREAKINDS.get(text(sector, "codeType"))
        ring = dedupe(pos_list(text(sector, "geoBounds/gmlPosList")))
        # Open the ring if the source closed it: the app closes polygons itself
        if len(ring) > 3 and ring[0] == ring[-1]:
            ring = ring[:-1]
        if kind is not None and len(ring) >= 3:
            procedure["areas"].append((kind, ring))
    if code_type == "TRAFFIC_CIRCUIT" and text(el, "valDistVerTfc"):
        procedure["altitude"] = (float(text(el, "valDistVerTfc")), text(el, "codeDistVerTfc"),
                                 text(el, "uomDistVerTfc"))
    raw["procedures"].append(procedure)


## [ HYGIENE ]
def are_twins(a, b):
    """Same aerodrome and kind, and the same skeleton (or curve, when either lacks one) within TWINNM."""
    if a["ad"] != b["ad"] or a["kind"] != b["kind"]:
        return False
    line_a, line_b = (a["skeleton"], b["skeleton"]) if a["skeleton"] and b["skeleton"] else (a["curve"], b["curve"])
    if not line_a or len(line_a) != len(line_b):
        return False
    return max(nm_between(p, q) for p, q in zip(line_a, line_b)) < TWINNM


def clean_procedures(raw, flags):
    """
    Applies ofm-investigation.md §6 and returns the publishable procedures:
    geometry from the Bézier curve, else the straight skeleton marked approx, else dropped; circuit altitude
    kept only when it is an ALT in FT and 400-2500 ft above the OFM aerodrome elevation; twins with the same
    altitude and category reduced to one (a placeholder name always loses), twins with different altitudes
    both kept and flagged. Everything dropped or doubted goes into `flags` for an error report to OFM.
    """
    elevations = raw["elevations"]
    candidates = []
    for p in raw["procedures"]:
        # Geometry
        if len(p["curve"]) >= 2:
            p["line"], p["approx"] = p["curve"], False
        elif len(p["skeleton"]) >= 2:
            p["line"], p["approx"] = p["skeleton"], True
        else:
            flag(flags, "no-geometry", p["ad"], p["id"], p["name"], "neither curve nor skeleton; dropped")
            continue
        # Circuit altitude
        p["alt"] = None
        if p["altitude"] is not None:
            value, reference, unit = p["altitude"]
            elevation = elevations.get(p["ad"])
            if reference != "ALT" or unit != "FT":
                flag(flags, "altitude-unusable", p["ad"], p["id"], p["name"],
                     f"{value:g} {reference or '?'} {unit or '?'} (only ALT in FT is used)")
            elif elevation is None:
                flag(flags, "altitude-unchecked", p["ad"], p["id"], p["name"],
                     f"{value:g} ft, but the aerodrome has no elevation in OFM; not shown")
            elif CIRCUITHEIGHTFT[0] <= value - elevation <= CIRCUITHEIGHTFT[1]:
                p["alt"] = int(round(value))
            else:
                flag(flags, "altitude-implausible", p["ad"], p["id"], p["name"],
                     f"{value:g} ft is {value - elevation:+.0f} ft above the aerodrome ({elevation:.0f} ft); not shown")
        candidates.append(p)

    # Twins: placeholders go last so the real one is the one kept. Same path and same altitude for the same
    # aircraft is a duplicate; for different aircraft (a helicopter circuit on the aeroplanes' path) it is not.
    # Same path at another altitude is kept, and flagged: either the categories explain it or OFM has an error.
    kept = []
    for p in sorted(candidates, key=lambda c: bool(PLACEHOLDERNAME.search(c["name"]))):
        altitude_p = p["altitude"][0] if p["altitude"] else None
        duplicate_of = None
        for twin in (q for q in kept if are_twins(p, q)):
            altitude_q = twin["altitude"][0] if twin["altitude"] else None
            if altitude_p != altitude_q:
                shown = [f"{a:g} ft" if a is not None else "no altitude" for a in (altitude_p, altitude_q)]
                flag(flags, "twin-altitudes", p["ad"], p["id"], p["name"],
                     f"same path as \"{twin['name']}\" but {shown[0]} vs {shown[1]}; both kept", other=twin["id"])
            elif (p["use"], p["cat"]) == (twin["use"], twin["cat"]):
                duplicate_of = twin
                break
        if duplicate_of is None:
            kept.append(p)
        else:
            flag(flags, "duplicate-dropped", p["ad"], p["id"], p["name"],
                 f"same path and altitude as \"{duplicate_of['name']}\"; dropped", other=duplicate_of["id"])
    for p in kept:
        if p["approx"] is True:
            flag(flags, "approx-geometry", p["ad"], p["id"], p["name"],
                 "no curve published; drawn from the straight skeleton")
    return kept


def collect_points(raw):
    """
    The published reporting points, plus the ones OFM only has inline in a procedure leg (no id of their own:
    they get a stable one from kind, name and position). Points without an aerodrome take the one of the
    procedures that use them, when those all agree.
    """
    points = [dict(p) for p in raw["points"]]
    # Inline-only points
    for leg_point in raw["legpoints"]:
        here = (leg_point["lon"], leg_point["lat"])
        if any(nm_between(here, (p["lon"], p["lat"])) < POINTSAMENM for p in points):
            continue
        digest = hashlib.sha1(
            f"{leg_point['kind']}|{leg_point['name']}|{leg_point['lat']:.5f}|{leg_point['lon']:.5f}".encode()).hexdigest()
        points.append({"id": "leg-" + digest[:16], **leg_point})
    # Aerodrome by usage
    for p in points:
        if p.get("ad"):
            continue
        users = {lp["ad"] for lp in raw["legpoints"]
                 if lp["ad"] and nm_between((lp["lon"], lp["lat"]), (p["lon"], p["lat"])) < POINTSAMENM}
        p["ad"] = users.pop() if len(users) == 1 else None
    return points


def mark_openaip(points, openaip, flags):
    """
    Sets inOpenAIP on every point (ofm-investigation.md §3): the same point is within 0.1 NM whatever the
    names, or within 0.5 NM with matching names. Same name 0.5-3 NM away (1 NM for a one- or two-letter
    name) is still the same point with a disputed position (investigation rule 2): flagged, and OpenAIP's
    record is the one the app keeps.
    """
    for p in points:
        here = (p["lon"], p["lat"])
        p["inOpenAIP"] = False
        disputed = None
        for name, lon, lat in openaip:
            distance = nm_between(here, (lon, lat))
            if distance <= OPENAIPANYNAMENM or (distance <= OPENAIPSAMENAMENM and same_point_name(p["name"], name)):
                p["inOpenAIP"] = True
                break
            reach = OPENAIPDISPUTEDNM if len(canon_name(name)) >= 3 else OPENAIPDISPUTEDSHORTNM
            if distance <= reach and canon_name(p["name"]) == canon_name(name):
                if disputed is None or distance < disputed[0]:
                    disputed = (distance, name)
        if p["inOpenAIP"] is False and disputed is not None:
            p["inOpenAIP"] = True
            flag(flags, "point-position", p.get("ad"), p["id"], p["name"],
                 f"OpenAIP has \"{disputed[1]}\" {disputed[0]:.2f} NM away")


def runway_pairs(raw):
    """Per aerodrome, the runway designators as OFM has them per physical runway ("07/25"), from the Rdn ends."""
    out = defaultdict(set)
    for (ad, _), ends in raw["runways"].items():
        designators = []
        for designator in ends:
            match = re.match(r"^0*(\d{1,2})([A-Z]*)$", designator)
            designators.append((int(match.group(1)), f"{int(match.group(1)):02d}{match.group(2)}") if match
                               else (99, designator))
        out[ad].add("/".join(d for _, d in sorted(designators)))
    return {ad: sorted(pairs) for ad, pairs in sorted(out.items())}


def parse_openaip(data):
    """OpenAIP's rpp GeoJSON as [(name, lon, lat), …]."""
    features = json.loads(data.decode("utf-8")).get("features")
    if not isinstance(features, list):
        raise ExtractError("OpenAIP export has no features")
    out = []
    for feature in features:
        try:
            lon, lat = feature["geometry"]["coordinates"][:2]
            out.append((feature["properties"].get("name") or "", float(lon), float(lat)))
        except (KeyError, TypeError, ValueError):
            continue
    return out


## [ BUILDING the published file ]
def build_region(config, airac, raw, openaip):
    """Turns a parsed snapshot into the published country document (schema v1) and its flags."""
    flags = []
    for tag, mid, error in raw["malformed"]:
        flag(flags, "malformed", None, mid, tag, error)
    procedures = clean_procedures(raw, flags)
    points = collect_points(raw)
    mark_openaip(points, openaip, flags)

    published = []
    for p in sorted(procedures, key=lambda q: (q["ad"], KINDORDER[q["kind"]], q["name"], q["id"])):
        item = {"id": p["id"], "ad": p["ad"], "kind": p["kind"], "name": p["name"], "use": p["use"], "cat": p["cat"]}
        if p["alt"] is not None:
            item["alt"] = p["alt"]
        item["line"] = publish_line(p["line"])
        if p["approx"] is True:
            item["approx"] = True
        areas = [{"kind": kind, "poly": publish_line(ring)} for kind, ring in p["areas"]]
        areas = [a for a in areas if len(a["poly"]) >= 3]
        if areas:
            item["areas"] = areas
        published.append(item)

    published_points = []
    for p in sorted(points, key=lambda q: (q.get("ad") or "", q["name"], q["id"])):
        item = {"id": p["id"], "name": p["name"], "kind": p["kind"]}
        if p.get("ad"):
            item["ad"] = p["ad"]
        item.update({"lat": round(p["lat"], DECIMALS), "lon": round(p["lon"], DECIMALS), "inOpenAIP": p["inOpenAIP"]})
        published_points.append(item)

    document = {
        "v": SCHEMA, "source": SOURCE, "attribution": ATTRIBUTION,
        "region": config["region"], "country": config["country"],
        "airac": airac.ident, "validFrom": airac.valid_from.isoformat(), "validTo": airac.valid_to.isoformat(),
        "ofmCreated": raw["created"],
        "procedures": published, "points": published_points, "runways": runway_pairs(raw),
    }
    return document, flags


## [ VALIDATION GATES ]
def count_circuits(document):
    return sum(1 for p in (document or {}).get("procedures") or [] if isinstance(p, dict) and p.get("kind") == "circuit")


def check_gates(document, data, previous, allow_drop=False):
    """
    Returns the reasons not to publish (an empty list means go): the file is over 2 MB, or, against the file
    published now, the region lost all its procedures or more than 30% of its circuits or points.
    """
    problems = []
    if len(data) > MAXFILEBYTES:
        problems.append(f"file is {len(data) / 1048576:.1f} MB, over the {MAXFILEBYTES // 1048576} MB limit")
    if previous is None or allow_drop is True:
        return problems
    before = len(previous.get("procedures") or [])
    if before > 0 and not document["procedures"]:
        problems.append(f"no procedures at all (the published file has {before})")
    for label, old, new in (("circuits", count_circuits(previous), count_circuits(document)),
                            ("points", len(previous.get("points") or []), len(document["points"]))):
        if old >= GATEMINCOUNT and new < old * (1 - MAXDROP):
            problems.append(f"{label} down from {old} to {new} ({(new - old) / old:+.0%}, the limit is -{MAXDROP:.0%})")
    return problems


## [ FETCH AND PUBLISH ]
def fetch_snapshot(config, airac, etag, fetch):
    """GETs one region's snapshot for one cycle. Returns the Response (status 200, 304 or 404)."""
    url = SNAPSHOTURL.format(airac=airac.ident, folder=config["folder"], file=config["file"])
    debug(f"GET {url}" + (f" (If-None-Match {etag})" if etag else ""))
    response = fetch(url, etag=etag)
    if response.status not in (200, 304, 404):
        response.close()
        raise ExtractError(f"{url} answered HTTP {response.status}")
    return response


def fetch_openaip(config, fetch):
    url = OPENAIPURL.format(cc=config["openaip"])
    response = fetch(url, etag=None)
    if response.status != 200:
        response.close()
        raise ExtractError(f"{url} answered HTTP {response.status}")
    try:
        return parse_openaip(response.stream.read())
    finally:
        response.close()


def process_region(config, airac, entry, previous, outdir, fetch, force=False, allow_drop=False):
    """
    Brings one country up to date. Returns (status, entry, message) where status is "updated", "unchanged"
    (304 on the published cycle), "waiting" (the cycle in force isn't on OFM yet: the previous one stays) or
    raises ExtractError (nothing written).
    """
    country = config["country"]
    published_airac = entry.get("airac") if entry else None
    # The cycle in force (N) when OFM has it. The published N is revalidated with its ETag; a published N-1
    # simply waits for OFM (that happens: N can come out weeks late); anything older falls back to N-1.
    if published_airac == airac.ident:
        tries = [(airac, None if force else entry.get("sourceEtag"))]
    else:
        tries = [(airac, None), (airac.previous(), None)]
    for cycle, etag in tries:
        response = fetch_snapshot(config, cycle, etag, fetch)
        if response.status == 304:
            return "unchanged", entry, f"AIRAC {cycle.ident} unchanged (ETag {etag})"
        if response.status == 404:
            debug(f"AIRAC {cycle.ident} is not on OFM (404)")
            if published_airac == cycle.ident:
                raise ExtractError(f"the published AIRAC {cycle.ident} snapshot disappeared from OFM (404)")
            if cycle == airac and published_airac == airac.previous().ident:
                return "waiting", entry, (f"AIRAC {cycle.ident} not published by OFM yet; "
                                          f"keeping AIRAC {published_airac}")
            continue
        # 200: parse it all before writing anything
        try:
            source_etag = strong_etag(response.headers.get("etag"))
            raw = parse_snapshot(response.stream)
        finally:
            response.close()
        openaip = fetch_openaip(config, fetch)
        document, flags = build_region(config, cycle, raw, openaip)
        data = vfrcommon.dump_compact(document)
        problems = check_gates(document, data, previous, allow_drop=allow_drop)
        if problems:
            raise ExtractError("validation stop: " + "; ".join(problems))
        filename = f"{country.lower()}.json"
        vfrcommon.write_if_changed(os.path.join(outdir, filename), data)
        for f in flags:
            debug(f"flag {f['type']}: {f['ad']} {f['name']} ({f['detail']})")
        for what, count in sorted(raw["skipped"].items()):
            debug(f"skipped {count} × {what}")
        new_entry = {
            "airac": cycle.ident, "validFrom": cycle.valid_from.isoformat(), "validTo": cycle.valid_to.isoformat(),
            "url": PUBLICBASE + filename, "sha256": vfrcommon.sha256_hex(data), "bytes": len(data),
            "sourceEtag": source_etag, "procedures": len(document["procedures"]), "points": len(document["points"]),
            "flags": flags,
        }
        kinds = Counter(p["kind"] for p in document["procedures"])
        message = (f"AIRAC {cycle.ident}: {kinds['circuit']} circuits, {kinds['arr']} arrivals, {kinds['dep']} "
                   f"departures, {sum(len(p.get('areas', [])) for p in document['procedures'])} areas, "
                   f"{len(document['points'])} points ({sum(1 for p in document['points'] if not p['inOpenAIP'])} "
                   f"not in OpenAIP), {len(document['runways'])} aerodromes with runways, "
                   f"{len(flags)} flags, {len(data):,} bytes")
        return "updated", new_entry, message
    raise ExtractError(f"neither AIRAC {airac.ident} nor {airac.previous().ident} is on OFM"
                       + (f" (the published file is AIRAC {published_airac})" if published_airac else ""))


def build_index(regions, previous_index):
    """The index the app reads first. `generated` only moves when something else in it did."""
    index = {"v": SCHEMA, "generated": None, "regions": regions, "attribution": ATTRIBUTION,
             "reportForm": REPORTFORM, "reportMail": REPORTMAIL}
    if previous_index and {**previous_index, "generated": None} == index:
        index["generated"] = previous_index.get("generated")
    else:
        index["generated"] = vfrcommon.now_iso()
    return index


## [ MAIN ]
def main(argv=None, fetch=http_get):
    global VERBOSE
    parser = argparse.ArgumentParser(description="Publish open flightmaps VFR data for aerocheck.app.")
    parser.add_argument("-v", action="store_true", dest="verbose")
    parser.add_argument("--out", default=OUTDIR)
    parser.add_argument("--date", type=date.fromisoformat, default=None)
    parser.add_argument("--regions", default=None)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--allow-drop", action="store_true")
    arguments = parser.parse_args(argv)
    VERBOSE = arguments.verbose

    airac = airac_for(arguments.date or vfrcommon.today_utc())
    configs = REGIONS
    if arguments.regions:
        wanted = {c.strip().upper() for c in arguments.regions.split(",")}
        configs = [c for c in REGIONS if c["country"] in wanted]
        if len(configs) != len(wanted):
            parser.error(f"unknown region in {arguments.regions} (known: {', '.join(c['country'] for c in REGIONS)})")
    say(f"open flightmaps → {arguments.out}, AIRAC in force {airac.ident} "
        f"({airac.valid_from.isoformat()} to {airac.valid_to.isoformat()})")

    index_path = os.path.join(arguments.out, "index.json")
    previous_index = vfrcommon.read_json(index_path) or {}
    previous_regions = previous_index.get("regions") or {}
    regions = {}
    stops = []
    for config in REGIONS:
        country = config["country"]
        entry = previous_regions.get(country)
        if config not in configs:
            # Not asked for this run: left exactly as it is
            if entry:
                regions[country] = entry
            continue
        previous = None
        if entry:
            # The index entry only counts if its file is there and is the one it describes
            path = os.path.join(arguments.out, f"{country.lower()}.json")
            try:
                with open(path, "rb") as handle:
                    data = handle.read()
                if vfrcommon.sha256_hex(data) == entry.get("sha256"):
                    previous = json.loads(data.decode("utf-8"))
            except (OSError, ValueError):
                pass
            if previous is None:
                say(f"{country}: published file missing or not matching index.json; fetching afresh")
                entry = None
        try:
            status, new_entry, message = process_region(config, airac, entry, previous, arguments.out, fetch,
                                                        force=arguments.force, allow_drop=arguments.allow_drop)
            say(f"{country} {status}: {message}")
            if new_entry:
                regions[country] = new_entry
        except (ExtractError, OSError) as error:
            stops.append(f"{country}: {error}")
            print(f"{country} STOPPED: {error}" + (f" (keeping the published AIRAC {entry['airac']} file)"
                                                   if entry else " (nothing published for it yet)"),
                  file=sys.stderr, flush=True)
            if entry:
                regions[country] = entry

    index = build_index(regions, previous_index)
    if not regions and not previous_index:
        say("nothing to index yet")
    elif vfrcommon.write_if_changed(index_path, vfrcommon.dump_pretty(index)) is True:
        cycles = ", ".join(country + " " + entry["airac"] for country, entry in regions.items())
        say(f"index.json written ({cycles})")
    else:
        say("index.json unchanged")
    if stops:
        print("VFR data: " + str(len(stops)) + " region(s) stopped:\n  " + "\n  ".join(stops), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
