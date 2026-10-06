### [   test_extract_ofm.py || the open flightmaps extractor on a snippet of the real AIRAC 2610 Swiss snapshot   ] ###
"""Run from scripts/vfrdata: python3 -m unittest (or from the repo root: python3 -m unittest discover -s scripts/vfrdata)."""

## [ IMPORTS be imports ]
import contextlib
import gzip
import io
import json
import os
import sys
import tempfile
import unittest
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import extract_ofm  # noqa: E402
import vfrcommon  # noqa: E402
from vfrcommon import Response, airac_by_ident, airac_for  # noqa: E402

## [ FIXTURES ]
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
# Real 2610 elements: LSZQ "TC" and its placeholder twin "NEW PROCEDURE" (2900 ft both), LSZQ "ARR SEKTOR WEST"
# and "ARR SECTOR EAST" (each with a "VFR Corridor" sector), LSGE's circuits "TC N" and "TRAFFIC CIRCUIT SOUTH"
# with their "ARR SECTOR NORTH" and "ARR SECTOR SOUTH" (no curve, only the alternate one and the skeleton),
# LSZE "ARR SECTOR EAST" (its one polygon is a "Leg Label" box), LSGG "TRANSIT_SOUTH" (a kind we don't publish),
# points SW, SIERRA, HW, INTERLAKEN SÜD and the town MARTIGNY, LSZQ's and LSGE's runway ends, and the LSZQ /
# LSGE aerodromes (for the elevations)
with open(os.path.join(FIXTURES, "ofmx_ls_2610_sample.xml"), "rb") as handle:
    SNAPSHOT = handle.read()
with open(os.path.join(FIXTURES, "openaip_ch_rpp_sample.geojson"), "rb") as handle:
    OPENAIP = handle.read()

TC = "f2fbd4ca-1edb-354d-414d-28863037c1ea"
NEWPROCEDURE = "cdac5ab1-3b95-99ee-c5a1-2d386a78dba4"
ARRWEST = "2a11d4aa-2772-c870-cc07-25ca6cf4d54f"
ARREAST = "b14a1c24-a583-8fc1-252c-8324d6d5b6f8"
LSGETCN = "498ef871-3068-3629-8cfb-937a03f2651a"
LSGETCSOUTH = "5da2f96f-6727-171d-c03f-fa949b6c4e8f"
LSGENORTH = "bcbf4062-2cd0-ff8f-5f0c-7cd38a4e2f86"
LSGESOUTH = "a0764343-e967-4732-8ce4-ff7957fe3a43"
LSZEEAST = "f497a06b-571f-d60a-b304-d86a77e9ea57"
SNAPSHOTETAG = '"0a7610c06f7aaac8f3585b1ef4e71769"'
CH = extract_ofm.REGIONS[0]


def edit(snapshot, old, new, after=None):
    """The snapshot with one textual change (the tests' way of making OFM err), the first one after `after`."""
    start = snapshot.index(after) if after else 0
    position = snapshot.index(old, start)
    return snapshot[:position] + new + snapshot[position + len(old):]


def extract(snapshot=SNAPSHOT, openaip=OPENAIP):
    raw = extract_ofm.parse_snapshot(io.BytesIO(snapshot))
    return extract_ofm.build_region(CH, airac_by_ident("2610"), raw, extract_ofm.parse_openaip(openaip))


def element_text(snapshot, mid, *tags):
    """(start, end) of the text of <tags[0]>…<tags[-1]> in the procedure with that id (first of each, in order)."""
    position = snapshot.index(b'<PrcUid mid="' + mid.encode())
    for tag in tags:
        position = snapshot.index(b"<" + tag + b">", position) + len(tag) + 2
    return position, snapshot.index(b"</" + tags[-1] + b">", position)


def blank(snapshot, mid, tag):
    """The snapshot with one of a procedure's curves emptied, as OFM leaves them (<_beztrajectory />)."""
    start, end = element_text(snapshot, mid, tag)
    return snapshot[:snapshot.rindex(b"<", 0, start)] + b"<" + tag + b" />" + snapshot[end + len(tag) + 3:]


def metres(a, b):
    return extract_ofm.nm_between(a, b) * 1852


class FakeOFM:
    """Answers like snapshots.openflightmaps.org and s3.openaip.net, and remembers what it was asked."""

    def __init__(self, snapshots=None, openaip=OPENAIP, etag=SNAPSHOTETAG):
        self.snapshots = snapshots if snapshots is not None else {"2610": SNAPSHOT}
        self.openaip = openaip
        self.etag = etag
        self.requests = []

    def __call__(self, url, etag=None):
        self.requests.append((url, etag))
        if "openaip" in url:
            if self.openaip is None:
                return Response(503, {})
            return Response(200, {}, io.BytesIO(self.openaip))
        cycle = url.split("/live/")[1].split("/")[0]
        if "/lsas/" not in url or cycle not in self.snapshots:
            # What OFM really answers for a missing object: a 404 with a PNG body
            return Response(404, {"content-type": "image/png"})
        if etag == self.etag:
            return Response(304, {"etag": self.etag})
        # Cloudflare gzips and weakens the ETag on the way out
        return Response(200, {"etag": "W/" + self.etag}, gzip.GzipFile(fileobj=io.BytesIO(gzip.compress(self.snapshots[cycle]))))


## [ AIRAC maths ]
class AiracTests(unittest.TestCase):

    def test_known_cycles(self):
        self.assertEqual(airac_for(date(2026, 10, 1)).ident, "2610")
        self.assertEqual(airac_for(date(2026, 10, 28)).ident, "2610")
        self.assertEqual(airac_for(date(2026, 10, 29)).ident, "2611")
        self.assertEqual(airac_for(date(2026, 9, 30)).ident, "2609")
        self.assertEqual(airac_for(date(2026, 10, 2)).valid_from, date(2026, 10, 1))
        self.assertEqual(airac_for(date(2026, 10, 2)).valid_to, date(2026, 10, 29))

    def test_cycles_start_on_thursdays_every_28_days(self):
        cycle = airac_for(date(2026, 1, 1))
        for _ in range(40):
            self.assertEqual(cycle.valid_from.weekday(), 3, cycle)
            self.assertEqual((cycle.valid_to - cycle.valid_from).days, 28)
            self.assertEqual(cycle.next().valid_from, cycle.valid_to)
            cycle = cycle.next()

    def test_year_boundaries(self):
        self.assertEqual(airac_for(date(2026, 1, 21)).ident, "2513")
        self.assertEqual(airac_for(date(2026, 1, 22)).ident, "2601")
        self.assertEqual(airac_for(date(2026, 12, 24)).ident, "2613")
        self.assertEqual(airac_for(date(2027, 1, 21)).ident, "2701")
        # 2020 had fourteen cycles
        self.assertEqual(airac_for(date(2020, 12, 31)).ident, "2014")

    def test_ident_round_trip(self):
        self.assertEqual(airac_by_ident("2610").valid_from, date(2026, 10, 1))
        self.assertEqual(airac_by_ident("2611").valid_from, date(2026, 10, 29))
        self.assertEqual(airac_by_ident("2611").previous().ident, "2610")
        self.assertEqual(airac_by_ident("2701").previous().ident, "2613")
        for bad in ("2614", "2600", "26", "abcd"):
            with self.assertRaises(ValueError):
                airac_by_ident(bad)


## [ PARSING and the published document ]
class ExtractTests(unittest.TestCase):

    def setUp(self):
        self.document, self.flags = extract()
        self.procedures = {p["id"]: p for p in self.document["procedures"]}

    def test_document_header(self):
        d = self.document
        self.assertEqual((d["v"], d["region"], d["country"], d["airac"]), (1, "LSAS", "CH", "2610"))
        self.assertEqual((d["validFrom"], d["validTo"]), ("2026-10-01", "2026-10-29"))
        self.assertEqual(d["ofmCreated"], "2026-09-26T01:19:31Z")
        self.assertEqual(d["attribution"], "© open flightmaps association (openflightmaps.org)")

    def test_circuit(self):
        tc = self.procedures[TC]
        self.assertEqual((tc["ad"], tc["kind"], tc["name"], tc["use"], tc["cat"], tc["alt"]),
                         ("LSZQ", "circuit", "TC", "fw", None, 2900))
        self.assertNotIn("approx", tc)
        self.assertEqual(list(tc)[:7], ["id", "ad", "kind", "name", "use", "cat", "alt"])
        # [lon, lat] at five decimals, around Porrentruy, simplified but still a loop
        self.assertGreaterEqual(len(tc["line"]), 6)
        for lon, lat in tc["line"]:
            self.assertTrue(6.9 < lon < 7.1 and 47.3 < lat < 47.5)
            self.assertEqual(round(lon, 5), lon)

    def test_placeholder_twin_is_dropped(self):
        self.assertNotIn(NEWPROCEDURE, self.procedures)
        dropped = [f for f in self.flags if f["type"] == "duplicate-dropped"]
        self.assertEqual(len(dropped), 1)
        self.assertEqual((dropped[0]["id"], dropped[0]["with"], dropped[0]["ad"]), (NEWPROCEDURE, TC, "LSZQ"))

    def test_arrival_with_sector(self):
        arrival = self.procedures[ARRWEST]
        self.assertEqual((arrival["kind"], arrival["name"]), ("arr", "ARR SEKTOR WEST"))
        self.assertNotIn("alt", arrival)
        self.assertNotIn("approx", arrival)
        self.assertEqual([a["kind"] for a in arrival["areas"]], ["corridor"])
        self.assertGreaterEqual(len(arrival["areas"][0]["poly"]), 3)

    def test_alternate_curve_before_the_skeleton(self):
        # LSGE "ARR SECTOR SOUTH" has an empty curve: its alternate one goes from the entry to the 28 threshold
        arrival = self.procedures[LSGESOUTH]
        self.assertNotIn("approx", arrival)
        self.assertEqual((arrival["line"][0], arrival["line"][-1]), ([7.0659, 46.72259], [7.08091, 46.75495]))
        self.assertGreaterEqual(len(arrival["line"]), 5)
        self.assertNotIn("approx-geometry", [f["type"] for f in self.flags])

    def test_backwards_alternate_runs_the_way_the_skeleton_does(self):
        # OFM draws the departures' alternates exit point first: turned around, the line starts where the
        # skeleton does
        start, end = element_text(SNAPSHOT, LSGESOUTH, b"_beztrajectoryAlternate", b"gmlPosList")
        backwards = b" ".join(reversed(SNAPSHOT[start:end].split()))
        document, _ = extract(SNAPSHOT[:start] + backwards + SNAPSHOT[end:])
        arrival = next(p for p in document["procedures"] if p["id"] == LSGESOUTH)
        self.assertEqual((arrival["line"][0], arrival["line"][-1]), ([7.0659, 46.72259], [7.08091, 46.75495]))

    def test_skeleton_only_arrival_is_approximate(self):
        document, flags = extract(blank(SNAPSHOT, LSGESOUTH, b"_beztrajectoryAlternate"))
        arrival = next(p for p in document["procedures"] if p["id"] == LSGESOUTH)
        self.assertTrue(arrival["approx"])
        self.assertGreaterEqual(len(arrival["line"]), 2)
        self.assertIn(("approx-geometry", LSGESOUTH), [(f["type"], f["id"]) for f in flags])

    def test_only_circuits_arrivals_and_departures(self):
        self.assertEqual({p["kind"] for p in self.document["procedures"]}, {"circuit", "arr"})
        self.assertNotIn("TRANSIT_SOUTH", [p["name"] for p in self.document["procedures"]])

    def test_points(self):
        points = {p["name"]: p for p in self.document["points"]}
        self.assertEqual(set(points), {"SW", "SIERRA", "HW", "INTERLAKEN SÜD"})
        self.assertEqual((points["SIERRA"]["kind"], points["SIERRA"]["ad"]), ("mrp", "LSZB"))
        self.assertEqual((points["SIERRA"]["lat"], points["SIERRA"]["lon"]), (46.84306, 7.49861))
        self.assertEqual(points["SW"]["kind"], "rp")
        self.assertNotIn("ad", points["SW"])
        self.assertEqual(points["HW"]["kind"], "heli")
        self.assertEqual(points["INTERLAKEN SÜD"]["kind"], "enr")
        self.assertEqual(list(points["SIERRA"]), ["id", "name", "kind", "ad", "lat", "lon", "inOpenAIP"])

    def test_in_openaip(self):
        points = {p["name"]: p for p in self.document["points"]}
        # "S" 0.3 NM away, "INTERLAKEN SUED" 0.2 NM away, "SW" 0.8 NM away (disputed), nothing near HW
        self.assertTrue(points["SIERRA"]["inOpenAIP"])
        self.assertTrue(points["INTERLAKEN SÜD"]["inOpenAIP"])
        self.assertTrue(points["SW"]["inOpenAIP"])
        self.assertFalse(points["HW"]["inOpenAIP"])
        disputed = [f for f in self.flags if f["type"] == "point-position"]
        self.assertEqual([f["name"] for f in disputed], ["SW"])

    def test_runways(self):
        # OFM's LSGE is still 10/28 (its chart says 09/27): published as OFM has it
        self.assertEqual(self.document["runways"], {"LSGE": ["10/28"], "LSZQ": ["07/25"]})

    def test_deterministic(self):
        again, _ = extract()
        self.assertEqual(vfrcommon.dump_compact(again), vfrcommon.dump_compact(self.document))


## [ HYGIENE ]
class HygieneTests(unittest.TestCase):

    def test_twins_with_different_altitudes_are_both_kept_and_flagged(self):
        # NEW PROCEDURE comes first in the file: give it 3000 ft instead of TC's 2900
        snapshot = edit(SNAPSHOT, b"<valDistVerTfc>2900</valDistVerTfc>", b"<valDistVerTfc>3000</valDistVerTfc>")
        document, flags = extract(snapshot)
        ids = {p["id"] for p in document["procedures"]}
        self.assertTrue({TC, NEWPROCEDURE} <= ids)
        twins = [f for f in flags if f["type"] == "twin-altitudes"]
        self.assertEqual(len(twins), 1)
        self.assertIn("3000 ft vs 2900 ft", twins[0]["detail"])

    def test_twins_for_different_aircraft_are_both_kept(self):
        snapshot = edit(SNAPSHOT, b"<txtName>NEW PROCEDURE</txtName>", b"<txtName>TC GLIDER</txtName>")
        document, flags = extract(snapshot)
        self.assertIn(NEWPROCEDURE, {p["id"] for p in document["procedures"]})
        self.assertFalse([f for f in flags if f["type"] in ("duplicate-dropped", "twin-altitudes")])

    def test_implausible_altitude_is_not_shown(self):
        # LSZQ is at 1866 ft: 2000 ft is 134 ft above it, a height coded as an altitude
        snapshot = SNAPSHOT.replace(b"<valDistVerTfc>2900</valDistVerTfc>", b"<valDistVerTfc>2000</valDistVerTfc>")
        document, flags = extract(snapshot)
        tc = next(p for p in document["procedures"] if p["id"] == TC)
        self.assertNotIn("alt", tc)
        self.assertIn(("altitude-implausible", TC), [(f["type"], f["id"]) for f in flags])

    def test_altitude_band_edges(self):
        for value, shown in ((2265, False), (2266, True), (4366, True), (4367, False)):
            snapshot = SNAPSHOT.replace(b"<valDistVerTfc>2900</valDistVerTfc>", f"<valDistVerTfc>{value}</valDistVerTfc>".encode())
            document, _ = extract(snapshot)
            tc = next(p for p in document["procedures"] if p["id"] == TC)
            self.assertEqual("alt" in tc, shown, value)

    def test_only_alt_in_feet(self):
        snapshot = SNAPSHOT.replace(b"<codeDistVerTfc>ALT</codeDistVerTfc>", b"<codeDistVerTfc>HEI</codeDistVerTfc>")
        document, flags = extract(snapshot)
        tc = next(p for p in document["procedures"] if p["id"] == TC)
        self.assertNotIn("alt", tc)
        self.assertIn(("altitude-unusable", TC), [(f["type"], f["id"]) for f in flags])

    def test_procedure_without_geometry_is_dropped(self):
        snapshot = blank(blank(SNAPSHOT, LSGESOUTH, b"_beztrajectoryAlternate"), LSGESOUTH, b"_sceletonPath")
        document, flags = extract(snapshot)
        self.assertNotIn(LSGESOUTH, {p["id"] for p in document["procedures"]})
        self.assertIn(("no-geometry", LSGESOUTH), [(f["type"], f["id"]) for f in flags])

    def test_helicopter_usage(self):
        snapshot = edit(SNAPSHOT, b"<usageType>FIXED_WING</usageType>", b"<usageType>HELICOPTER</usageType>",
                        after=b"<txtName>ARR SEKTOR WEST</txtName>")
        document, _ = extract(snapshot)
        arrival = next(p for p in document["procedures"] if p["id"] == ARRWEST)
        self.assertEqual((arrival["use"], arrival["cat"]), ("heli", "heli"))

    def test_categories_from_names(self):
        cases = {
            "TFC": None, "TC NORTH 07": None, "TC FIXED LANDING GEAR": None, "ARR RW 24 ACFT < 5.7T FROM GISWIL": None,
            "TFC GLIDER": "glider", "GLD": "glider", "SEGELFLUG": "glider", "PLANEURS": "glider", "GLID": "glider",
            "UL": "ul", "UL-03X": "ul", "SOUTH-UL TFC": "ul", "ULM": "ul",
            "UL+GLIDER": "glider+ul", "UL/TMG": "glider+ul",
            "GYRO-NW": "gyro", "HELI TFC": "heli", "TFC-(H)": "heli",
            "TC MULTI": "heavy", "TFC RETRACTABLE GEAR": "heavy", "TC ACT >5.7 TO": "heavy",
            "TFC B (MULTI ENGINE OR > 2000KG)": "heavy", "JET+MULTI ENGINE APP 03": "heavy",
            "SOUTH": None, "CULM": None,
        }
        for name, expected in cases.items():
            self.assertEqual(extract_ofm.category(name, "FIXED_WING"), expected, name)
        self.assertEqual(extract_ofm.category("ECHO (REGA)", "HELICOPTER"), "heli")

    def test_simplify(self):
        straight = [(7.0 + i * 0.001, 47.0) for i in range(50)]
        self.assertEqual(extract_ofm.simplify(straight), [straight[0], straight[-1]])
        # A 50 m kink survives a 10 m tolerance, a 5 m one doesn't
        kink = [(7.0, 47.0), (7.005, 47.0 + 50 / 110540), (7.01, 47.0)]
        self.assertEqual(len(extract_ofm.simplify(kink)), 3)
        wobble = [(7.0, 47.0), (7.005, 47.0 + 5 / 110540), (7.01, 47.0)]
        self.assertEqual(len(extract_ofm.simplify(wobble)), 2)
        # A closed loop keeps its shape
        square = [(7.0, 47.0), (7.01, 47.0), (7.01, 47.01), (7.0, 47.01), (7.0, 47.0)]
        self.assertEqual(extract_ofm.simplify(square), square)

    def test_malformed_feature_is_skipped_and_flagged(self):
        snapshot = edit(SNAPSHOT, b"<geoLat>46.84305558N</geoLat>", b"<geoLat>46.84305558Q</geoLat>")
        document, flags = extract(snapshot)
        self.assertNotIn("SIERRA", [p["name"] for p in document["points"]])
        self.assertEqual([f["type"] for f in flags if f["type"] == "malformed"], ["malformed"])


## [ MAP HELPERS: sector badges, routes off the circuit, thresholds ]
class DirectionTests(unittest.TestCase):

    def test_real_names(self):
        # Arrival and departure names from the 2610 CH, AT, DE and CZ files
        cases = {
            "ARR SECTOR EAST": "E", "ARR SEKTOR WEST": "W", "ARE SECTOR NORTH": "N", "ARR SECKTOR SOUTH": "S",
            "ARR SECTOR NE": "NE", "ARR SECTOR NW": "NW", "ARR SECTOR SW": "SW", "ARR SECTOR E": "E",
            "ARR SECTOR SOUTH04": "S", "ARR SECTOR NORTH STRAIGHT IN APP ONLY": "N", "APP SECTOR EAST MIN 4000": "E",
            "ARR SECTOR WEST OUTSIDE DÜBENDORF OP HR": "W", "ARR FROM DIREKTION SW 21 SINGLE ENGINE": "SW",
            "ARR RW 24 FROM NW": "NW", "DEP RW 17 TO THE SOUTH": "S", "DEP 06 TO NW": "NW", "SECTOR S RWY 08": "S",
            "AMSTETTEN-OST - OSCAR": "E", "AMSTETTEN WEST - WHISKEY": "W", "TFC- NORTHWEST": "NW",
            "NORDOST27": "NE", "SÜD-OST09": "SE", "SÜDOST10": "SE", "SÜD13": "S", "OST06": "E", "NORD04": "N",
            "WEST28": "W", "36-NORTH EAST": "NE", "36-SOUTH EAST": "SE", "04- SOUTHWEST": "SW",
            "GLIDER TOWING 07-SOUTHEAST": "SE", "DEP-07-NORTHEAST": "NE", "19-SECTOR-E": "E", "SEC-N-TFC": "N",
            "S-ARR": "S", "27-W": "W", "NORTH-N-12": "N",
        }
        for name, expected in cases.items():
            self.assertEqual(extract_ofm.direction(name), expected, name)

    def test_no_direction(self):
        for name in (
            # Misspelt: not guessed
            "ARR 29 FROM NOTHEAST", "01-N0RTH", "08-SOUTEAST", "DEP 23 TO SUOTH", "ARR SECTOR EAS RW 12",
            # Reporting points, not directions: phonetic names and letter-digit names
            "ECHO 1 ARR", "SIERRA ARRIVAL 09", "WHISKEY 1", "SEKTOR ECHO", "E1-E2-04", "N2-N1", "07-O2-O1",
            # Letters inside words, and nothing at all
            "NATTENHEIM", "GLEISDORF", "OEFFINGEN-28", "ARR 08C FIXED GEAR DOWNWIND 270°", "SPECIAL TC DEP07 ARR25",
            # Two directions: which one is a guess
            "08-EAST-NORTH", "27-WEST-NORTH", "DEP 11TO THE N W", "SOUTH-N-12",
        ):
            self.assertIsNone(extract_ofm.direction(name), name)

    def test_french_and_italian(self):
        # Made up: no French or Italian name in the four regions yet
        cases = {"SECTEUR NORD-EST": "NE", "SECTEUR SUD-OUEST": "SW", "SECTEUR OUEST": "W", "SECTEUR EST": "E",
                 "SETTORE NORD OVEST": "NW", "SETTORE SUD EST": "SE", "SETTORE OVEST": "W", "SECTEUR SUD": "S",
                 "SÜDWEST": "SW", "SUEDOST": "SE", "NORD-WEST": "NW"}
        for name, expected in cases.items():
            self.assertEqual(extract_ofm.direction(name), expected, name)

    def test_only_routes_carry_it(self):
        document, _ = extract()
        procedures = {p["id"]: p for p in document["procedures"]}
        self.assertEqual([procedures[i]["dir"] for i in (ARREAST, ARRWEST, LSGENORTH, LSGESOUTH, LSZEEAST)],
                         ["E", "W", "N", "S", "E"])
        self.assertEqual(list(procedures[ARRWEST])[:7], ["id", "ad", "kind", "name", "use", "cat", "dir"])
        # "TC N" is a circuit: no badge
        self.assertNotIn("dir", procedures[LSGETCN])


class LabelTests(unittest.TestCase):
    FLAT = extract_ofm.Flat(7.0, 47.0)

    def ring(self, metres_xy):
        return [self.FLAT.lonlat(q) for q in metres_xy]

    def clearance(self, point, ring):
        return extract_ofm.signed_ring_distance(self.FLAT.xy(point), [self.FLAT.xy(q) for q in ring])

    def test_convex(self):
        # A 2 km square: the middle, 1 km from every side
        square = self.ring([(0, 0), (2000, 0), (2000, 2000), (0, 2000)])
        label = extract_ofm.pole_of_inaccessibility(square)
        self.assertGreater(self.clearance(label, square), 1000 - extract_ofm.LABELPRECISIONM)

    def test_concave(self):
        # A U, 3 km wide, its notch 1 km wide and 2 km deep: the centroid (1500, 1357) falls in the notch; the
        # best point sits in a bottom corner, 586 m from the outer sides and the notch's corner
        u = self.ring([(0, 0), (3000, 0), (3000, 3000), (2000, 3000), (2000, 1000), (1000, 1000), (1000, 3000), (0, 3000)])
        self.assertLess(self.clearance(self.FLAT.lonlat((1500, 1357)), u), 0)
        label = extract_ofm.pole_of_inaccessibility(u)
        self.assertGreater(self.clearance(label, u), 586 - extract_ofm.LABELPRECISIONM)

    def test_degenerate_ring(self):
        flat = self.ring([(0, 0), (1000, 0), (2000, 0)])
        self.assertEqual(extract_ofm.pole_of_inaccessibility(flat), flat[0])

    def test_every_published_area_has_its_label_inside(self):
        document, _ = extract()
        areas = [a for p in document["procedures"] for a in p.get("areas", [])]
        self.assertEqual(len(areas), 4)
        for area in areas:
            self.assertEqual(list(area), ["kind", "poly", "label"])
            self.assertEqual([round(v, 5) for v in area["label"]], area["label"])
            self.assertGreater(self.clearance(area["label"], area["poly"]), 0, area)


class OffCircuitTests(unittest.TestCase):

    def setUp(self):
        self.document, _ = extract()
        self.procedures = {p["id"]: p for p in self.document["procedures"]}

    def on_circuit(self, point, ad):
        circuits = [p["line"] for p in self.document["procedures"] if p["ad"] == ad and p["kind"] == "circuit"]
        return min(extract_ofm.polyline_distance(point, c) for c in circuits) <= extract_ofm.CIRCUITREACHM

    def test_lszq_arrivals(self):
        # East: joins the circuit's NE corner at its third vertex, then flies the circuit to the 07 threshold
        east = self.procedures[ARREAST]
        self.assertEqual(east["offCircuit"], [0, 2])
        self.assertTrue(self.on_circuit(east["line"][2], "LSZQ"))
        self.assertFalse(self.on_circuit(east["line"][1], "LSZQ"))
        self.assertLess(metres(east["line"][2], (7.05466, 47.39851)), 200)
        # West: joins near the corner of base and final
        west = self.procedures[ARRWEST]
        self.assertEqual(west["offCircuit"], [0, 3])
        self.assertLess(metres(west["line"][3], (6.99602, 47.38434)), 200)
        self.assertEqual(list(west)[7:9], ["line", "offCircuit"])

    def test_lsge_arrivals(self):
        # Both come straight in and join their own circuit's downwind at the second vertex
        for arrival in (LSGENORTH, LSGESOUTH):
            route = self.procedures[arrival]
            self.assertEqual(route["offCircuit"], [0, 1], route["name"])
            self.assertTrue(all(self.on_circuit(p, "LSGE") for p in route["line"][1:]), route["name"])
            self.assertFalse(self.on_circuit(route["line"][0], "LSGE"), route["name"])

    def test_no_circuit_no_key(self):
        # LSZE's circuit isn't in the fixture
        self.assertNotIn("offCircuit", self.procedures[LSZEEAST])
        self.assertNotIn("offCircuit", self.procedures[LSGETCN])

    def test_rules(self):
        circuit = [[7.0, 47.0], [7.02, 47.0], [7.02, 47.01], [7.0, 47.01]]
        off = [7.05, 47.03]
        on = [[7.01, 47.0005], [7.02, 47.005], [7.019, 47.0099]]
        departure = on + [[7.03, 47.02], off]
        self.assertEqual(extract_ofm.off_circuit(departure, [circuit]), [2, 4])
        self.assertEqual(extract_ofm.off_circuit([off] + on, [circuit]), [0, 1])
        self.assertEqual(extract_ofm.off_circuit([off] + on + [off], [circuit]), None)    # nothing at either end
        self.assertEqual(extract_ofm.off_circuit([off, on[0]], [circuit]), None)          # meets it, never runs along
        self.assertEqual(extract_ofm.off_circuit(on, [circuit]), None)                    # all of it on the circuit
        self.assertEqual(extract_ofm.off_circuit(departure, []), None)                    # no circuit
        # 200 m is the reach
        just_off = [7.01, 47.0 - 210 / 110540]
        self.assertEqual(extract_ofm.off_circuit([off, just_off] + on, [circuit]), [0, 2])


class LegLabelTests(unittest.TestCase):

    def test_a_leg_label_box_alone_is_the_sector(self):
        document, _ = extract()
        east = next(p for p in document["procedures"] if p["id"] == LSZEEAST)
        self.assertEqual([a["kind"] for a in east["areas"]], ["corridor"])
        self.assertGreaterEqual(len(east["areas"][0]["poly"]), 4)

    def test_a_leg_label_box_beside_a_corridor_is_dropped(self):
        # Give ARR SEKTOR WEST's label a box: the corridor stays its only area
        box = b"<geoBounds><gmlPosList>006.95,47.38 006.96,47.38 006.96,47.39 006.95,47.39 006.95,47.38</gmlPosList></geoBounds>"
        snapshot = edit(SNAPSHOT, b"<visThr>200</visThr>", b"<visThr>200</visThr>" + box, after=b"<txtName>ARR SEKTOR WEST</txtName>")
        document, _ = extract(snapshot)
        west = next(p for p in document["procedures"] if p["id"] == ARRWEST)
        self.assertEqual([a["kind"] for a in west["areas"]], ["corridor"])


class ThresholdTests(unittest.TestCase):

    def test_published(self):
        document, _ = extract()
        self.assertEqual(list(document)[-2:], ["runways", "thresholds"])
        self.assertEqual(document["thresholds"], {
            "LSGE": [{"rwy": "10", "pos": [7.07063, 46.75559], "trueBrg": 95.0},
                     {"rwy": "28", "pos": [7.08091, 46.75495], "trueBrg": 275.0}],
            "LSZQ": [{"rwy": "07", "pos": [7.02427, 47.39125], "trueBrg": 70.0},
                     {"rwy": "25", "pos": [7.03373, 47.39356], "trueBrg": 250.0}],
        })

    def test_only_aerodromes_with_a_procedure(self):
        raw = extract_ofm.parse_snapshot(io.BytesIO(SNAPSHOT))
        self.assertEqual(list(extract_ofm.thresholds(raw, {"LSZQ", "LSZE"})), ["LSZQ"])

    def test_missing_position_or_bearing(self):
        snapshot = edit(SNAPSHOT, b"<geoLat>46.75558700N</geoLat>", b"<geoLat />")
        snapshot = edit(snapshot, b"<valTrueBrg>275</valTrueBrg>", b"<valTrueBrg />")
        document, flags = extract(snapshot)
        self.assertEqual(document["thresholds"]["LSGE"], [{"rwy": "28", "pos": [7.08091, 46.75495]}])
        # The runway itself is still there, and nothing is malformed
        self.assertEqual(document["runways"]["LSGE"], ["10/28"])
        self.assertNotIn("malformed", [f["type"] for f in flags])


## [ REPORTING POINTS vs OpenAIP ]
class PointMatchTests(unittest.TestCase):

    def test_canonical_names(self):
        for name, canon in (("SIERRA", "S"), ("ECHO1", "E1"), ("Echo 2", "E2"), ("ABM ALTREU", "ALTREU"),
                            ("INTERLAKEN SÜD", "INTERLAKENSUED"), ("Lucens", "LUCENS"), ("WHISKEY", "W"),
                            ("SIERRALEONE", "SIERRALEONE")):
            self.assertEqual(extract_ofm.canon_name(name), canon, name)

    def test_same_point_names(self):
        same = extract_ofm.same_point_name
        self.assertTrue(same("SIERRA", "S"))
        self.assertTrue(same("PALEX", "PALEXPO"))
        self.assertTrue(same("GE", "GEGEN"))      # OpenAIP's five-letter code
        self.assertFalse(same("N", "S"))
        self.assertFalse(same("GE", "GENEVA"))    # not a five-letter code
        self.assertFalse(same("ABC", "ABCD"))     # too short for a prefix match

    def test_matching_rules(self):
        lat = 46.8
        nm_lon = 1 / (60 * 0.68412)  # one nautical mile of longitude at 46.8°N

        def point(name):
            return {"id": "x", "name": name, "lon": 7.0, "lat": lat, "ad": None}

        cases = [
            ("ANYTHING", "OTHER", 0.05, True, False),     # 0.1 NM: same point, whatever the name
            ("SIERRA", "S", 0.4, True, False),            # 0.5 NM with names that agree
            ("SIERRA", "N", 0.4, False, False),           # ... and not with names that don't
            ("YVONAND", "YVONAND", 0.64, True, True),     # same name 0.5-3 NM: disputed position
            ("YVONAND", "YVONAND", 2.9, True, True),
            ("YVONAND", "YVONAND", 3.2, False, False),
            ("V", "V", 0.75, True, True),                 # a short name reaches 1 NM only
            ("W", "W", 2.9, False, False),
        ]
        for ofm, openaip, distance, inside, flagged in cases:
            p, flags = point(ofm), []
            extract_ofm.mark_openaip([p], [(openaip, 7.0 + distance * nm_lon, lat)], flags)
            self.assertEqual(p["inOpenAIP"], inside, (ofm, openaip, distance))
            self.assertEqual(bool(flags), flagged, (ofm, openaip, distance))

    def test_inline_leg_point_joins_the_list(self):
        # A VFR-MRP named only inside a leg of the LSZQ arrival becomes a point with a stable id
        snapshot = edit(SNAPSHOT, b"<codeType>FIXED-POS</codeType>", b"<codeType>VFR-MRP</codeType>",
                        after=b"<txtName>ARR SEKTOR WEST</txtName>")
        document, _ = extract(snapshot)
        inline = [p for p in document["points"] if p["id"].startswith("leg-")]
        self.assertEqual(len(inline), 1)
        self.assertEqual((inline[0]["name"], inline[0]["kind"], inline[0]["ad"]), ("SET POS", "mrp", "LSZQ"))
        again, _ = extract(snapshot)
        self.assertEqual(inline[0]["id"], [p for p in again["points"] if p["id"].startswith("leg-")][0]["id"])


## [ VALIDATION GATES ]
class GateTests(unittest.TestCase):

    def documents(self, circuits, points, procedures=None):
        procs = [{"kind": "circuit"}] * circuits + [{"kind": "arr"}] * ((procedures or circuits) - circuits)
        return {"procedures": procs, "points": [{}] * points}

    def test_size(self):
        problems = extract_ofm.check_gates(self.documents(10, 10), b"x" * (2 * 1024 * 1024 + 1), None)
        self.assertTrue(problems and "2 MB" in problems[0])
        self.assertEqual(extract_ofm.check_gates(self.documents(10, 10), b"x" * 1000, None), [])

    def test_drop_of_more_than_30_percent(self):
        before = self.documents(100, 100)
        self.assertEqual(extract_ofm.check_gates(self.documents(70, 100), b"{}", before), [])
        self.assertTrue(extract_ofm.check_gates(self.documents(69, 100), b"{}", before))
        self.assertTrue(extract_ofm.check_gates(self.documents(100, 69), b"{}", before))
        self.assertEqual(extract_ofm.check_gates(self.documents(69, 69), b"{}", before, allow_drop=True), [])

    def test_small_counts_swing_freely(self):
        self.assertEqual(extract_ofm.check_gates(self.documents(5, 5, 20), b"{}", self.documents(9, 9, 20)), [])

    def test_no_procedures_left(self):
        problems = extract_ofm.check_gates({"procedures": [], "points": [{}] * 50}, b"{}", self.documents(5, 50))
        self.assertTrue(any("no procedures" in p for p in problems))

    def test_odd_openaip_features_are_skipped(self):
        data = b'{"features": [{"geometry": {"coordinates": [7, 46]}, "properties": null}, {"geometry": null}, {}]}'
        self.assertEqual(extract_ofm.parse_openaip(data), [("", 7.0, 46.0)])

    def test_parse_errors(self):
        with self.assertRaises(extract_ofm.ExtractError):
            extract_ofm.parse_snapshot(io.BytesIO(SNAPSHOT[: len(SNAPSHOT) // 2]))
        with self.assertRaises(extract_ofm.ExtractError):
            extract_ofm.parse_snapshot(io.BytesIO(b"\x89PNG\r\n\x1a\n not xml"))
        with self.assertRaises(extract_ofm.ExtractError):
            extract_ofm.parse_snapshot(io.BytesIO(b"<html><body>Bad gateway</body></html>"))


## [ THE WHOLE RUN ]
class RunTests(unittest.TestCase):

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.out = self.directory.name

    def tearDown(self):
        self.directory.cleanup()

    def run_extractor(self, fake, day="2026-10-02", *extra):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return extract_ofm.main(["--out", self.out, "--date", day, "--regions", "CH", *extra], fetch=fake)

    def read(self, name):
        with open(os.path.join(self.out, name), "rb") as handle:
            return handle.read()

    def test_first_run_publishes_and_indexes(self):
        fake = FakeOFM()
        self.assertEqual(self.run_extractor(fake), 0)
        data = self.read("ch.json")
        index = json.loads(self.read("index.json"))
        entry = index["regions"]["CH"]
        self.assertEqual(entry["airac"], "2610")
        self.assertEqual((entry["validFrom"], entry["validTo"]), ("2026-10-01", "2026-10-29"))
        self.assertEqual(entry["url"], "https://aerocheck.app/data/ofm/v1/ch.json")
        self.assertEqual(entry["sha256"], vfrcommon.sha256_hex(data))
        self.assertEqual(entry["bytes"], len(data))
        self.assertEqual(entry["sourceEtag"], SNAPSHOTETAG)  # the strong form: the weak one never gets a 304
        self.assertEqual((entry["procedures"], entry["points"]), (8, 4))
        self.assertIn("duplicate-dropped", [f["type"] for f in entry["flags"]])
        self.assertEqual(index["attribution"], "© open flightmaps association (openflightmaps.org)")
        self.assertEqual(index["reportForm"]["field"], "entry.284686808")
        self.assertTrue(index["reportForm"]["url"].startswith("https://docs.google.com/forms/"))
        self.assertEqual(index["reportMail"], "info@openflightmaps.org")
        self.assertEqual(fake.requests[0], ("https://snapshots.openflightmaps.org/live/2610/ofmx/lsas/latest/isolated/ofmx_ls.xml", None))

    def test_unchanged_source_is_not_downloaded_again(self):
        self.run_extractor(FakeOFM())
        before = (self.read("ch.json"), self.read("index.json"))
        fake = FakeOFM()
        self.assertEqual(self.run_extractor(fake, "2026-10-08"), 0)
        self.assertEqual(fake.requests, [(fake.requests[0][0], SNAPSHOTETAG)])
        self.assertEqual((self.read("ch.json"), self.read("index.json")), before)

    def test_force_ignores_the_etag(self):
        self.run_extractor(FakeOFM())
        fake = FakeOFM()
        self.assertEqual(self.run_extractor(fake, "2026-10-08", "--force"), 0)
        self.assertIsNone(fake.requests[0][1])

    def test_next_cycle_not_published_keeps_the_current_file(self):
        self.run_extractor(FakeOFM())
        before = (self.read("ch.json"), self.read("index.json"))
        fake = FakeOFM()
        self.assertEqual(self.run_extractor(fake, "2026-10-29"), 0)
        self.assertIn("/live/2611/", fake.requests[0][0])
        self.assertEqual((self.read("ch.json"), self.read("index.json")), before)

    def test_next_cycle_published(self):
        self.run_extractor(FakeOFM())
        snapshot_2611 = edit(SNAPSHOT, b'created="2026-09-26T01:19:31Z"', b'created="2026-10-24T01:00:00Z"')
        self.assertEqual(self.run_extractor(FakeOFM({"2610": SNAPSHOT, "2611": snapshot_2611}, etag='"2611"'), "2026-10-29"), 0)
        document = json.loads(self.read("ch.json"))
        self.assertEqual((document["airac"], document["validTo"], document["ofmCreated"]), ("2611", "2026-11-26", "2026-10-24T01:00:00Z"))
        self.assertEqual(json.loads(self.read("index.json"))["regions"]["CH"]["sourceEtag"], '"2611"')

    def test_first_run_falls_back_to_the_previous_cycle(self):
        fake = FakeOFM()
        self.assertEqual(self.run_extractor(fake, "2026-10-29"), 0)
        self.assertEqual(json.loads(self.read("ch.json"))["airac"], "2610")
        self.assertEqual([url.split("/live/")[1][:4] for url, _ in fake.requests if "openflightmaps" in url], ["2611", "2610"])

    def test_nothing_on_ofm_is_a_stop(self):
        self.assertEqual(self.run_extractor(FakeOFM({})), 1)
        self.assertFalse(os.path.exists(os.path.join(self.out, "ch.json")))

    def test_two_cycles_behind_is_a_stop(self):
        self.run_extractor(FakeOFM())
        before = self.read("ch.json")
        self.assertEqual(self.run_extractor(FakeOFM(), "2026-11-30"), 1)
        self.assertEqual(self.read("ch.json"), before)

    def test_parse_error_keeps_the_last_good_file(self):
        self.run_extractor(FakeOFM())
        before = (self.read("ch.json"), self.read("index.json"))
        broken = FakeOFM({"2610": SNAPSHOT[:5000]}, etag='"changed"')
        self.assertEqual(self.run_extractor(broken, "2026-10-08"), 1)
        self.assertEqual((self.read("ch.json"), self.read("index.json")), before)

    def test_validation_stop_keeps_the_last_good_file(self):
        self.run_extractor(FakeOFM())
        # Pretend the published file had 20 circuits: one is a 95% drop
        path = os.path.join(self.out, "ch.json")
        document = json.loads(self.read("ch.json"))
        circuit = next(p for p in document["procedures"] if p["kind"] == "circuit")
        document["procedures"] = document["procedures"] + [dict(circuit, id=str(i)) for i in range(19)]
        data = vfrcommon.dump_compact(document)
        vfrcommon.write_atomic(path, data)
        index = json.loads(self.read("index.json"))
        index["regions"]["CH"]["sha256"] = vfrcommon.sha256_hex(data)
        vfrcommon.write_atomic(os.path.join(self.out, "index.json"), vfrcommon.dump_pretty(index))

        self.assertEqual(self.run_extractor(FakeOFM(etag='"changed"'), "2026-10-08"), 1)
        self.assertEqual(self.read("ch.json"), data)
        self.assertEqual(self.run_extractor(FakeOFM(etag='"changed"'), "2026-10-08", "--allow-drop"), 0)
        self.assertNotEqual(self.read("ch.json"), data)

    def test_a_bug_in_one_region_is_a_stop_too(self):
        fake = FakeOFM()

        def broken(url, etag=None):
            if "openaip" in url:
                raise RuntimeError("a bug")
            return fake(url, etag)

        self.assertEqual(self.run_extractor(broken), 1)
        self.assertFalse(os.path.exists(os.path.join(self.out, "ch.json")))

    def test_openaip_failure_is_a_stop(self):
        self.assertEqual(self.run_extractor(FakeOFM(openaip=None)), 1)
        self.assertFalse(os.path.exists(os.path.join(self.out, "ch.json")))

    def test_a_missing_file_is_fetched_again(self):
        self.run_extractor(FakeOFM())
        os.remove(os.path.join(self.out, "ch.json"))
        fake = FakeOFM()
        self.assertEqual(self.run_extractor(fake, "2026-10-08"), 0)
        self.assertIsNone(fake.requests[0][1])
        self.assertTrue(os.path.exists(os.path.join(self.out, "ch.json")))

    def test_other_regions_are_left_alone(self):
        self.run_extractor(FakeOFM())
        index = json.loads(self.read("index.json"))
        index["regions"]["AT"] = dict(index["regions"]["CH"], url="https://aerocheck.app/data/ofm/v1/at.json")
        vfrcommon.write_atomic(os.path.join(self.out, "index.json"), vfrcommon.dump_pretty(index))
        self.run_extractor(FakeOFM(), "2026-10-08")
        self.assertIn("AT", json.loads(self.read("index.json"))["regions"])


if __name__ == "__main__":
    unittest.main()
