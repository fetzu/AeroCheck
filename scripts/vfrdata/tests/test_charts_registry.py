### [   test_charts_registry.py || the official-chart registry, with every server faked   ] ###
"""Run from scripts/vfrdata: python3 -m unittest (or from the repo root: python3 -m unittest discover -s scripts/vfrdata)."""

## [ IMPORTS be imports ]
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import charts_registry  # noqa: E402
from vfrcommon import Response, airac_by_ident  # noqa: E402

## [ FIXTURES ]
# The shape of DFS's config.js (a made-up excerpt: three aerodromes, a hospital helipad, a military field)
CONFIGJS = '''\t\tconst rootUrl = "https://aip.dfs.de/BasicVFR/";
\tconst permalinks=[{label:"Aachen Universitaetsklinikum",value:"C01B07"},{label:"Aachen-Merzbrueck EDKA",value:"C0194C"},
{label:"Freiburg i. Br. EDTF",value:"C019C9"},{label:"Laupheim ETHL",value:"C01A0A"},{label:"Zell am See",value:"C01B99"},
{label:"Zweibruecken EDRZ",value:"C01A99"}];'''


class FakeWeb:
    """config.js plus a HEAD answer per URL (200 unless told otherwise)."""

    def __init__(self, config=CONFIGJS, config_status=200, failing=()):
        self.config = config
        self.config_status = config_status
        self.failing = set(failing)
        self.checked = []

    def fetch(self, url, etag=None):
        if self.config_status != 200:
            return Response(self.config_status, {})
        return Response(200, {}, io.BytesIO(self.config.encode()))

    def check(self, url):
        self.checked.append(url)
        return 404 if any(part in url for part in self.failing) else 200


class RegistryTests(unittest.TestCase):

    def setUp(self):
        self.minimum = charts_registry.DFSMINPAGES
        charts_registry.DFSMINPAGES = 3

    def tearDown(self):
        charts_registry.DFSMINPAGES = self.minimum

    def build(self, web, day=date(2026, 10, 2), previous=None):
        with contextlib.redirect_stdout(io.StringIO()):
            return charts_registry.build_registry(charts_registry.airac_for(day), previous, fetch=web.fetch,
                                                  check=web.check)

    def test_dfs_config(self):
        pages = charts_registry.parse_dfs_config(CONFIGJS)
        self.assertEqual(pages, {"EDKA": "C0194C", "EDRZ": "C01A99", "EDTF": "C019C9", "ETHL": "C01A0A"})

    def test_sample_spread(self):
        self.assertEqual(charts_registry.sample_of(["A", "B", "C", "D", "E"], 3), ["A", "C", "E"])
        self.assertEqual(charts_registry.sample_of(["A", "B"], 3), ["A", "B"])

    def test_sia_folder(self):
        self.assertEqual(charts_registry.sia_folder(airac_by_ident("2610")), "01_OCT_2026")
        self.assertEqual(charts_registry.sia_folder(airac_by_ident("2701")), "21_JAN_2027")

    def test_everything_up(self):
        web = FakeWeb()
        countries, flags = self.build(web)
        self.assertEqual(flags, [])
        self.assertEqual(set(countries), {"DE", "FR", "CH", "AT"})
        self.assertEqual(countries["DE"]["base"], "https://aip.dfs.de/BasicVFR/pages/")
        self.assertEqual(countries["DE"]["pages"]["EDTF"], "C019C9")
        self.assertEqual(countries["FR"], {
            "kind": "sia-vac", "airac": "2610",
            "template": "https://www.sia.aviation-civile.gouv.fr/media/dvd/eAIP_01_OCT_2026/Atlas-VAC/"
                        "PDF_AIPparSSection/VAC/AD/AD-2.{icao}.pdf"})
        self.assertEqual(countries["CH"]["login"], True)
        self.assertEqual(countries["AT"]["url"], "https://eaip.austrocontrol.at/")
        self.assertNotIn("IT", countries)
        # Three DFS pages, one French VAC, the two start pages
        self.assertEqual(len(web.checked), 6)
        self.assertIn("https://aip.dfs.de/BasicVFR/pages/C019C9.html", web.checked)

    def test_france_falls_back_to_the_previous_cycle(self):
        countries, flags = self.build(FakeWeb(failing={"eAIP_29_OCT_2026"}), day=date(2026, 10, 29))
        self.assertEqual(countries["FR"]["airac"], "2610")
        self.assertIn("eAIP_01_OCT_2026", countries["FR"]["template"])
        self.assertEqual(flags, [])

    def test_france_left_out_when_no_folder_answers(self):
        countries, flags = self.build(FakeWeb(failing={"sia.aviation-civile"}))
        self.assertNotIn("FR", countries)
        self.assertEqual([f["country"] for f in flags], ["FR"])

    def test_a_failed_dfs_page_is_left_out(self):
        countries, flags = self.build(FakeWeb(failing={"C019C9"}))
        self.assertNotIn("EDTF", countries["DE"]["pages"])
        self.assertIn("EDKA", countries["DE"]["pages"])
        self.assertEqual([(f["country"], f["status"]) for f in flags], [("DE", 404)])

    def test_dfs_left_out_when_every_sampled_page_fails(self):
        countries, flags = self.build(FakeWeb(failing={"aip.dfs.de"}))
        self.assertNotIn("DE", countries)
        self.assertEqual(len(flags), 3)

    def test_last_weeks_dfs_table_when_config_js_is_down(self):
        previous = {"countries": {"DE": {"kind": "dfs-basicvfr", "base": charts_registry.DFSBASE,
                                         "pages": {"EDKA": "C0194C", "EDTF": "C019C9", "EDRZ": "C01A99"}}}}
        countries, flags = self.build(FakeWeb(config_status=503), previous=previous)
        self.assertEqual(countries["DE"]["pages"], {"EDKA": "C0194C", "EDTF": "C019C9", "EDRZ": "C01A99"})
        self.assertEqual([f["detail"] for f in flags], ["config.js unavailable"])

    def test_config_js_format_change(self):
        countries, flags = self.build(FakeWeb(config="const permalinks = {};"))
        self.assertNotIn("DE", countries)
        self.assertIn("format change", flags[0]["detail"])

    def test_start_page_down(self):
        countries, flags = self.build(FakeWeb(failing={"skybriefing"}))
        self.assertNotIn("CH", countries)
        self.assertEqual([f["country"] for f in flags], ["CH"])


class MainTests(unittest.TestCase):

    def setUp(self):
        self.minimum = charts_registry.DFSMINPAGES
        charts_registry.DFSMINPAGES = 3
        self.directory = tempfile.TemporaryDirectory()
        self.out = os.path.join(self.directory.name, "charts.json")

    def tearDown(self):
        charts_registry.DFSMINPAGES = self.minimum
        self.directory.cleanup()

    def run_registry(self, web):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return charts_registry.main(["--out", self.out, "--date", "2026-10-02"], fetch=web.fetch, check=web.check)

    def test_file_and_stable_timestamp(self):
        self.assertEqual(self.run_registry(FakeWeb()), 0)
        with open(self.out, "rb") as handle:
            first = handle.read()
        registry = json.loads(first)
        self.assertEqual((registry["v"], registry["flags"]), (1, []))
        self.assertEqual(self.run_registry(FakeWeb()), 0)
        with open(self.out, "rb") as handle:
            self.assertEqual(handle.read(), first)

    def test_failures_exit_1_and_are_listed(self):
        self.assertEqual(self.run_registry(FakeWeb(failing={"austrocontrol"})), 1)
        with open(self.out) as handle:
            registry = json.load(handle)
        self.assertNotIn("AT", registry["countries"])
        self.assertEqual(registry["flags"][0]["country"], "AT")


if __name__ == "__main__":
    unittest.main()
