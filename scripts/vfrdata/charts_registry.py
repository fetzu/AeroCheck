#!/usr/bin/env python3
### [   charts_registry.py || where the official VFR chart of an aerodrome lives, country by country   ] ###
"""
Builds public/data/charts/v1/charts.json: for each country, how the app turns an ICAO code into a link to the
official aerodrome chart. Links only: no chart is ever downloaded, copied or republished.

  DE  DFS BasicVFR permalinks (free, no login). The ICAO -> page id table is DFS's own public config.js, read
      once; the page URL is base + id + ".html", and it follows amendments by itself.
  FR  SIA eAIP Atlas-VAC PDFs (free, no login). The folder is named after the AIRAC date, so the template is
      rebuilt every cycle; the app replaces {icao}.
  CH  skyguide's eVFR Manual on SkyBriefing (login and a subscription): one URL for every aerodrome.
  AT  Austro Control's eAIP start page (its own folders change with every amendment and have no alias).
  IT  none: ENAV's terms forbid deep links.

Usage: charts_registry.py [-h] [-v] [--out FILE] [--date YYYY-MM-DD]

  -v                 Verbose: show every link checked.
  --out FILE         Where to write (default: public/data/charts/v1/charts.json in this checkout).
  --date YYYY-MM-DD  Pretend today is that day (picks the AIRAC cycle for France).

Every country's links are checked with a small sample (a HEAD per link, DFS gets three, the others one) before
they are published; a country whose sample fails is left out of the file and listed under "flags", and the run
exits 1 so the weekly job opens its issue. A broken link is never published.
"""

## [ IMPORTS be imports ]
import argparse
import os
import re
import sys
from datetime import date

import vfrcommon
from vfrcommon import airac_for, http_get, http_status

## [ CONFIGURATION ]
SCHEMA = 1
OUTFILE = os.path.join(vfrcommon.REPOROOT, "public", "data", "charts", "v1", "charts.json")

DFSCONFIG = "https://aip.dfs.de/BasicVFR/js/config.js"
DFSBASE = "https://aip.dfs.de/BasicVFR/pages/"
DFSMINPAGES = 300                # fewer aerodromes than this in config.js means its format changed
DFSSAMPLE = 3                    # pages HEAD-checked each run, spread over the alphabet

SIATEMPLATE = ("https://www.sia.aviation-civile.gouv.fr/media/dvd/eAIP_{folder}/Atlas-VAC/PDF_AIPparSSection/"
               "VAC/AD/AD-2.{{icao}}.pdf")
SIASAMPLE = "LFGA"               # Colmar-Houssen: one aerodrome to prove the cycle's folder is online
MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

SKYBRIEFINGVFRMANUAL = "https://www.skybriefing.com/en/evfr-manual"
AUSTROCONTROLEAIP = "https://eaip.austrocontrol.at/"

VERBOSE = False


## [ SMALL HELPERS ]
def say(message):
    print(message, flush=True)


def debug(message):
    if VERBOSE is True: print("    " + message, flush=True)


def link_ok(url, check):
    """True when the link answers 2xx (after redirects)."""
    status = check(url)
    debug(f"{status} {url}")
    return 200 <= status < 300, status


## [ GERMANY: DFS BasicVFR ]
def parse_dfs_config(source):
    """
    Reads DFS's config.js, which holds the permalink list of the BasicVFR search box as
    {label:"Freiburg i. Br. EDTF",value:"C019C9"}. Aerodromes are the labels ending in an ED/ET ICAO code;
    the rest are hospital helipads without one.
    """
    pages = {}
    for label, value in re.findall(r'\{\s*label\s*:\s*"([^"]*)"\s*,\s*value\s*:\s*"([^"]*)"\s*\}', source):
        match = re.search(r"\b(E[DT][A-Z]{2})\s*$", label)
        if match and re.fullmatch(r"[0-9A-F]{6}", value):
            pages.setdefault(match.group(1), value)
    return dict(sorted(pages.items()))


def sample_of(keys, count):
    """A deterministic spread of `count` keys: first, last and evenly in between."""
    keys = list(keys)
    if len(keys) <= count:
        return keys
    return [keys[round(i * (len(keys) - 1) / (count - 1))] for i in range(count)]


def build_germany(previous, fetch, check, flags):
    pages = None
    response = fetch(DFSCONFIG)
    if response.status == 200:
        try:
            pages = parse_dfs_config(response.stream.read().decode("utf-8", errors="replace"))
        finally:
            response.close()
        if len(pages) < DFSMINPAGES:
            flags.append({"country": "DE", "url": DFSCONFIG, "status": 200,
                          "detail": f"config.js lists only {len(pages)} aerodromes (format change?)"})
            pages = None
    else:
        response.close()
        flags.append({"country": "DE", "url": DFSCONFIG, "status": response.status,
                      "detail": "config.js unavailable"})
    if pages is None:
        # Last week's table is still worth publishing if its links still work
        pages = dict((previous or {}).get("pages") or {})
        if not pages:
            return None
        say("DE: config.js unusable, re-checking last week's table")
    # A failed page is left out; if the whole sample fails, the table itself is wrong and DE is left out
    sample = sample_of(pages, DFSSAMPLE)
    failed = 0
    for icao in sample:
        url = DFSBASE + pages[icao] + ".html"
        ok, status = link_ok(url, check)
        if not ok:
            failed += 1
            flags.append({"country": "DE", "url": url, "status": status, "detail": f"{icao} page failed; left out"})
            del pages[icao]
    if failed == len(sample):
        return None
    return {"kind": "dfs-basicvfr", "base": DFSBASE, "pages": pages}


## [ FRANCE: SIA Atlas-VAC ]
def sia_folder(airac):
    """eAIP_01_OCT_2026 for the cycle that starts on 1 October 2026."""
    start = airac.valid_from
    return f"{start.day:02d}_{MONTHS[start.month - 1]}_{start.year}"


def build_france(airac, check, flags):
    for cycle in (airac, airac.previous()):
        template = SIATEMPLATE.format(folder=sia_folder(cycle))
        url = template.replace("{icao}", SIASAMPLE)
        ok, status = link_ok(url, check)
        if ok:
            if cycle != airac:
                say(f"FR: the AIRAC {airac.ident} folder isn't online yet, publishing {cycle.ident}'s")
            return {"kind": "sia-vac", "template": template, "airac": cycle.ident}
        debug(f"FR: AIRAC {cycle.ident} sample answered {status}")
    flags.append({"country": "FR", "url": url, "status": status,
                  "detail": f"neither the AIRAC {airac.ident} nor the {airac.previous().ident} VAC folder answers"})
    return None


## [ SWITZERLAND and AUSTRIA: one page each ]
def build_single(country, entry, check, flags):
    ok, status = link_ok(entry["url"], check)
    if ok:
        return entry
    flags.append({"country": country, "url": entry["url"], "status": status, "detail": "start page failed"})
    return None


## [ MAIN ]
def build_registry(airac, previous, fetch=http_get, check=http_status):
    """Returns (countries, flags). `previous` is the published charts.json (or None)."""
    flags = []
    countries = {}
    previous_countries = (previous or {}).get("countries") or {}
    germany = build_germany(previous_countries.get("DE"), fetch, check, flags)
    if germany:
        countries["DE"] = germany
    france = build_france(airac, check, flags)
    if france:
        countries["FR"] = france
    switzerland = build_single("CH", {"kind": "skybriefing-vfr-manual", "url": SKYBRIEFINGVFRMANUAL, "login": True},
                               check, flags)
    if switzerland:
        countries["CH"] = switzerland
    austria = build_single("AT", {"kind": "eaip", "url": AUSTROCONTROLEAIP}, check, flags)
    if austria:
        countries["AT"] = austria
    return countries, flags


def main(argv=None, fetch=http_get, check=http_status):
    global VERBOSE
    parser = argparse.ArgumentParser(description="Publish the official-chart link registry for aerocheck.app.")
    parser.add_argument("-v", action="store_true", dest="verbose")
    parser.add_argument("--out", default=OUTFILE)
    parser.add_argument("--date", type=date.fromisoformat, default=None)
    arguments = parser.parse_args(argv)
    VERBOSE = arguments.verbose

    airac = airac_for(arguments.date or vfrcommon.today_utc())
    previous = vfrcommon.read_json(arguments.out)
    countries, flags = build_registry(airac, previous, fetch=fetch, check=check)
    for country, entry in countries.items():
        detail = f"{len(entry['pages'])} aerodromes" if "pages" in entry else entry.get("template") or entry.get("url")
        say(f"{country} {entry['kind']}: {detail}")

    registry = {"v": SCHEMA, "generated": None, "countries": countries, "flags": flags}
    # `generated` only moves when something else did, so an unchanged week makes no commit
    if previous and {**previous, "generated": None} == registry:
        registry["generated"] = previous.get("generated")
    else:
        registry["generated"] = vfrcommon.now_iso()
    written = vfrcommon.write_if_changed(arguments.out, vfrcommon.dump_pretty(registry))
    say(f"charts.json {'written' if written else 'unchanged'} ({', '.join(countries) or 'no country'})")
    if flags:
        print("Chart registry: " + str(len(flags)) + " check(s) failed:\n  "
              + "\n  ".join(f"{f['country']}: {f['detail']} ({f['status']} {f['url']})" for f in flags),
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
