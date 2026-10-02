# VFR data for the app (aerocheck.app/data)

Two small scripts that turn other people's aeronautical data into the files AéroCheck downloads for its map: the traffic circuits, VFR arrival and departure routes, arrival sectors and reporting points from open flightmaps, and a registry of where each country keeps its official aerodrome charts. The output lives in `public/data/` and Astro copies it to the site as is; the app reads it from `https://aerocheck.app/data/…` and never talks to the sources itself.

A weekly job on `main` (`.github/workflows/vfr-data.yml`) runs both scripts on Thursdays at 05:00 UTC (AIRAC cycles start on Thursdays), commits what changed to this branch as "website: VFR data AIRAC <cycle> (<countries>)" and dispatches `deploy.yml`. When a script stops, the job opens (or updates) one issue, "VFR data job failed".

## Usage

Standard library only, Python 3.11 or newer. From the root of the `website` checkout:

```bash
python3 scripts/vfrdata/extract_ofm.py -v        # open flightmaps -> public/data/ofm/v1/
python3 scripts/vfrdata/charts_registry.py -v    # chart links    -> public/data/charts/v1/charts.json
cd scripts/vfrdata && python3 -m unittest        # the tests (no network)
```

```
extract_ofm.py [-h] [-v] [--out DIR] [--date YYYY-MM-DD] [--regions CC,CC] [--force] [--allow-drop]

  -v                 Verbose: say what was dropped and flagged, region by region.
  --out DIR          Where to write (default: public/data/ofm/v1 in this checkout).
  --date YYYY-MM-DD  Pretend today is that day (picks the AIRAC cycle).
  --regions CC,CC    Only these countries (default: CH, AT, DE, CZ).
  --force            Ignore the stored ETags and re-extract (after a change to the script).
  --allow-drop       Accept a region that lost more than 30% of its circuits or points, once a human
                     has checked that OFM really did that.

charts_registry.py [-h] [-v] [--out FILE] [--date YYYY-MM-DD]
```

Both exit 0 when everything is published (or rightly left alone), 1 when something stopped. A stopped region or country keeps its last good file (or, for a chart link, is left out): the site never serves half a file or a link that just failed.

## extract_ofm.py

### Source

OFM publishes no "current cycle" pointer, so the script computes the AIRAC cycle in force from the date (an anchor plus 28-day steps, as OFM's own site does) and fetches `https://snapshots.openflightmaps.org/live/<AIRAC>/ofmx/<region>/latest/isolated/ofmx_<xx>.xml` for LSAS (CH), LOVV (AT), ED (DE) and LKAA (CZ). That unlisted `isolated` file is the only one with procedures (the advertised OFMX zip has none). The requests say who we are (`AeroCheck-data/1.0 (+https://aerocheck.app)`, OFM's Cloudflare refuses `Python-urllib`), ask for gzip, and are conditional: `index.json` keeps each region's ETag, so an unchanged week costs four 304s. OFM's Cloudflare weakens the ETag (`W/"…"`) when it compresses and only answers 304 to the strong form, so the strong form is what gets stored.

When the new cycle isn't on OFM yet (a missing object is a 404 with a PNG body, hence the status check), the file of the previous cycle stays untouched; the app sees its AIRAC and shows it aging. Two cycles behind is a stop.

### What is kept

Traffic circuits, VFR arrivals and departures (transits, holds and IFR transitions are dropped), the sector polygons of their legs ("VFR Corridor" → `corridor`, AT's "Noise Abatement Area" → `noise`, untyped → `area`; "Leg Label" boxes are not areas), the VFR reporting points (published ones, plus the few OFM only has inline in a procedure leg), and the runway designators per aerodrome as OFM has them. Lines are Douglas-Peucker simplified at 10 m and rounded to 5 decimals (display only, about 1 m).

### Hygiene

From the 6.2.0 investigation (`ofm-investigation.md` §6):

- geometry from the Bézier curve (`_beztrajectory`); without one, from the straight skeleton (`_sceletonPath`) and marked `approx`; without either, dropped;
- a circuit altitude is published only when it is an ALT in FT between 400 and 2,500 ft above OFM's aerodrome elevation (LOAA "2900 ft" on a 2,870 ft field is a height coded as an altitude);
- two procedures of an aerodrome on the same path (skeletons within 0.05 NM, vertex by vertex) at the same altitude and for the same aircraft are one: the second is dropped, and a placeholder name ("NEW PROCEDURE", "TEST", "COPY", "DRAFT", empty) always loses. Same path at different altitudes: both kept and flagged;
- the category comes from the name, since OFM's `usageType` only knows fixed wing and helicopter: `glider`, `ul`, `glider+ul`, `gyro`, `heli` (also from the helicopter usage), `heavy` (multi-engine, retractable, turbine, "> 2000 KG"…), or `null` for the plain powered one.

Everything dropped or doubted goes into the region's `flags` in `index.json`, with the OFM id to quote in an error report.

### Reporting points vs OpenAIP

OpenAIP stays the app's primary source; `inOpenAIP` tells the app which OFM points it already has, against OpenAIP's keyless `https://s3.openaip.net/openaip-system-exports/<cc>_rpp.geojson`. Same point when within 0.1 NM whatever the names, or within 0.5 NM with names that agree once normalised (SIERRA = S, ECHO1 = E1, "ABM" dropped, umlauts folded, a 4-letter prefix, OpenAIP's 5-letter codes such as GEGEN for GE). Same name 0.5 to 3 NM apart (1 NM for one- or two-letter names) is still the same point with a disputed position: `inOpenAIP` is true and the pair is flagged (`point-position`). The app re-checks against its own OpenAIP data anyway.

### Validation gates

A region is not published (its last good file stays, the run exits 1) on a parse error, a file over 2 MB, all procedures gone when it had some, or circuits or points down more than 30% against the published file (counted from 10 up). `--allow-drop` lifts the last two once a human has looked.

### Files (schema v1)

`index.json` is what the app reads first; `generated` only moves when something else in it did.

```
public/data/ofm/v1/index.json   { v, generated, regions: { CH: { airac, validFrom, validTo, url, sha256, bytes,
                                  sourceEtag, procedures, points, flags[] }, … }, attribution,
                                  reportForm: { url, field }, reportMail }
public/data/ofm/v1/<cc>.json    { v, source, attribution, region, country, airac, validFrom, validTo, ofmCreated,
                                  procedures: [{ id, ad, kind, name, use, cat, alt?, line, approx?,
                                  areas?: [{ kind, poly }] }],
                                  points: [{ id, name, kind, ad?, lat, lon, inOpenAIP }],
                                  runways: { <ICAO>: ["07/25", …] } }
```

`kind` is `circuit`, `arr` or `dep`; `use` is `fw` or `heli`; `alt` is in ft MSL; `line` and `poly` are `[lon, lat]` pairs (polygons are open rings: the app closes them); `validTo` is the next cycle's first day. Point kinds: `rp` (on request), `mrp` (compulsory), `enr` (en route), `heli`, `gld`. A point's `id` is OFM's `mid`, or `leg-<hash>` for one OFM only has inline. `reportForm` is OFM's "Open flightmaps error reporting" Google Form and its description field, for a pre-filled report; `reportMail` is the fallback. Both live here so they can change without an app release.

## charts_registry.py

Where the official chart of an aerodrome lives, by country. Links only: nothing is downloaded or republished.

```
public/data/charts/v1/charts.json  { v, generated, countries: {
                                       DE: { kind: "dfs-basicvfr", base, pages: { <ICAO>: <id> } },
                                       FR: { kind: "sia-vac", template, airac, codes? },
                                       CH: { kind: "skybriefing-vfr-manual", url, login: true },
                                       AT: { kind: "eaip", url } },
                                     flags[] }
```

- DE: DFS BasicVFR permalinks, `base + id + ".html"` (free, no login, amendment-proof). The ICAO → id table is DFS's own public `config.js` (the BasicVFR search box), read once a run; the pages themselves are never crawled.
- FR: SIA eAIP Atlas-VAC PDF, `template` with `{icao}` replaced. The folder is named after the AIRAC date (`eAIP_01_OCT_2026`), checked on LFGA; while the new cycle's folder isn't online, the previous one is used. `codes` lists the aerodromes that have a VAC in that folder (419 in 2610), read from `Atlas-VAC/Javascript/AeroArraysVac.js`, the list behind the atlas's own search box: a code that isn't in it answers 404 (most of the French air bases, for one). It is optional: when the list is unavailable or looks wrong (fewer than 300 codes, or LFGA missing), FR is published without it and flagged, and the app falls back to its own rule (an LF code of an aerodrome type); last week's list is kept while the folder is the same.
- CH: skyguide's eVFR Manual on SkyBriefing, one URL for every aerodrome, behind a login and a subscription.
- AT: Austro Control's eAIP start page (the amendment folders have no stable alias).
- IT: none. ENAV's terms forbid deep links.

Every run HEAD-checks a sample (three DFS pages spread over the alphabet, the French sample, both start pages) and reads SIA's code list once. A failed DFS page is left out; a country whose sample fails entirely is left out of `countries` and listed in `flags`, and the run exits 1. If `config.js` itself is unavailable, last week's table is re-checked and kept if its sample still answers.

## Notes

- OFM's procedure element (`Prc`) is not in the public OFMX schema, and the underscore elements (`_beztrajectory`, `_sceletonPath`) are OFM internals: the format can change without notice. The gates catch the loud failures; a quiet change (a renamed field) shows up as missing circuits or areas in the counts the job prints.
- The tests use elements cut from the real AIRAC 2610 Swiss snapshot (`tests/fixtures/ofmx_ls_2610_sample.xml`), a made-up OpenAIP stand-in and a made-up excerpt in the shape of SIA's code list (`tests/fixtures/sia_aeroarraysvac_sample.js`); they never touch the network.
- Licence of the data: the open flightmaps General Users' License asks that open flightmaps always be credited as the source and that errors found be reported back. Every file carries the attribution, `index.json` carries the report form, and the app shows both. Ask OFMA (info@openflightmaps.org) before 6.2.0 ships.

## Credits

Data © open flightmaps association ([openflightmaps.org](https://openflightmaps.org)). Reporting-point comparison against [OpenAIP](https://www.openaip.net). Chart links to DFS (BasicVFR), SIA France, skyguide (SkyBriefing) and Austro Control. The scripts are MIT, like the rest of the repository.
