#!/usr/bin/env python3
# Builds src/data/tz-countries.json: each IANA time zone (as a browser reports it, "Europe/Zurich") and its country, from
# the time zone database's own zone.tab, plus the old names some systems still report. The Countries page guesses the
# visitor's country from it, in the browser, before asking (the author's decision of 22 Oct 2026: no tracking, no
# lookup of the address):
#   python3 -I scripts/make-tz-countries.py [/usr/share/zoneinfo/zone.tab]
import json, os, sys

source = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/zoneinfo/zone.tab"
out_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src", "data", "tz-countries.json")
zones = {}
with open(source, encoding="utf-8") as handle:
    for line in handle:
        if line.startswith("#") or not line.strip():
            continue
        country, _, zone = line.split("\t")[:3]
        zones[zone.strip()] = country
OLD = {"Europe/Kiev": "UA", "Europe/Uzhgorod": "UA", "Europe/Zaporozhye": "UA", "Europe/Belfast": "GB",
       "America/Godthab": "GL", "Atlantic/Faeroe": "FO", "Asia/Calcutta": "IN", "Asia/Saigon": "VN",
       "Asia/Katmandu": "NP", "Asia/Rangoon": "MM", "Asia/Istanbul": "TR"}
for zone, country in OLD.items():
    zones.setdefault(zone, country)
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(dict(sorted(zones.items())), handle, separators=(",", ":"))
    handle.write("\n")
print(len(zones), "zones")
