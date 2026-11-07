**Last updated**
November 2026


Starting with version 6.8.0, AéroCheck provides its own map for flying: the Atlas. This page explains where its data comes from, what we keep of it (and what we leave out), how it is cut and updated, and who is credited (in compliance with section 4.6 of the Open Database Licence).


## 1.0 What the map is

The Atlas is drawn on your device by MapLibre Native, from vector tiles we build every month from OpenStreetMap, and from the Mapterhorn relief. It shows what you would look for out of the window: towns and villages (by size), main roads, railways, rivers and lakes, forests, built-up areas, glaciers, borders, cable cars, and peaks with their height in feet. The aeronautical layers (airspace, aerodromes, procedures and your route) are drawn on top of it, much like on the Swiss charts.

It comes in two parts:
- The world outline, which ships with the app: land, sea, the larger lakes and rivers, borders, countries and capitals. This is what the map falls back on when it has no region to show, i.e. offline outside the regions you downloaded, or once the month's online allowance is used up.
- The regions, built from the full data: one per country listed on the [Countries](/countries) page, with the larger ones split further (the US states, the German Länder, the French régions…), about 236 in all. A region is either read online (within a monthly allowance) or downloaded and used offline.


## 2.0 Where the data comes from

- OpenStreetMap: © OpenStreetMap contributors, under the [Open Database Licence](https://opendatacommons.org/licenses/odbl/1-0/) (ODbL 1.0), read through the daily build of the [Protomaps basemap](https://docs.protomaps.com/basemaps/downloads). The map's data is a produced work under the ODbL; the data itself can be found at [openstreetmap.org](https://www.openstreetmap.org/copyright).
- Relief: [Mapterhorn](https://mapterhorn.com), open terrain data built from national and global elevation models. Its sources and their licences are listed at [mapterhorn.com/attribution](https://mapterhorn.com/attribution).
- Region outlines: [Overture Maps](https://overturemaps.org), taken from OpenStreetMap's boundaries and under the same ODbL (© OpenStreetMap contributors, Overture Maps Foundation).
- Country names and major rivers of the world outline: [Natural Earth](https://www.naturalearthdata.com) (public domain).
- Typeface: [B612](https://github.com/polarsys/b612), designed for cockpit screens, under the SIL Open Font License 1.1.
- Rendering: [MapLibre Native](https://maplibre.org), under the BSD 2-Clause licence.


## 3.0 What we keep, and what we leave out

Our build reads the Protomaps tiles and keeps, feature by feature, what a pilot actually uses (or, more exactly, what a pilot looks for from the cockpit). Whatever it keeps is copied as is: we don't simplify or move it.

### 3.1 Kept
- Land and land cover.
- Forests/woods, built-up areas (residential, commercial and industrial) and glaciers.
- Water: seas, lakes, rivers and canals, with their names.
- Country borders.
- Roads: motorways, trunk, primary and secondary roads, with their numbers (and whether they run through a tunnel).
- Railways: main lines, narrow-gauge lines and funiculars, with their tunnels (but not sidings or service tracks), as well as cable cars and other aerial lifts.
- Places: cities, towns, villages, hamlets and isolated dwellings, with their names and population (which decides from which zoom level a place shows up).

### 3.2 Added
- Peaks, a layer we build ourselves from OpenStreetMap's peaks: the name, the height in feet, and the distance to the nearest higher peak, which decides from which zoom level a peak shows up (a summit standing on its own appears before a bump on a ridge).

### 3.3 Left out
- Buildings, shops and other points of interest, public transport, minor roads, tracks/paths, and state or regional borders.
- Every attribute the map does not draw: a feature keeps its type, its name, its road number or its population, and nothing else.


## 4.0 Cut at the border

A region only contains the data inside its own outline. That outline is OpenStreetMap's boundary as published by Overture Maps: on land, the border itself; at sea, the territorial waters (12 NM, or 6 in the Aegean) or the middle of a strait, every island included. Every tile crossing that line is cut along it (at every zoom level), and the relief outside of it is removed. Where two regions meet, the app stitches their two halves of a tile back together; beyond the regions on your device, the world outline takes over. Borders are drawn exactly as OpenStreetMap draws them.


## 5.0 Built each month

The map is rebuilt every month from the latest OpenStreetMap data, and each file is named after its content. This keeps updates small:
- a device asks for a region's file by that name, and only asks again once the name has changed: a region that did not change is never downloaded twice;
- when checking for updates, the device states which version it has, and an "unchanged" answer is only a few bytes;
- a downloaded region updates itself every three months, on Wi-Fi and not in flight (the "Update" button, when the app offers it, fetches the newer build sooner).

OpenStreetMap is edited every minute, so a monthly map is at most a few weeks behind it. If something is missing or wrong on the map, the best place to fix it is [OpenStreetMap itself](https://www.openstreetmap.org/fixthemap): the next build will pick it up.


## 6.0 How the app gets the map

The files are stored on tiles.aerocheck.app. A downloaded region is read from the device and works offline; half of the regions are under 30 MB (Switzerland and Liechtenstein together about 90 MB, the largest a few hundred MB). Elsewhere, the app loads the tiles on screen online (zoomed out, from a single overview of every region), within a monthly allowance per device: 1,500 tiles, or 15,000 with AéroCheck Pro. A downloaded region never counts against that allowance. What these requests reveal, and what we keep of them, is detailed in [the privacy policy](/privacy), section 3.10.


## 7.0 Aerial imagery

The "Aerial imagery" layer shows open government orthophotos (and nothing else). Each device fetches them directly from the government's own service while they are on screen: AéroCheck doesn't host or store them. Each source is used under its open licence, cut at the border of the area it covers, and credited in its own words on the map whenever its imagery is visible (at a border, where several show at once, each of them is). Where no government publishes imagery we are allowed to use, the layer simply stays empty.

| Area | Provider's credit | Licence |
|---|---|---|
| Switzerland, Liechtenstein | ©swisstopo | [swisstopo free geodata](https://www.swisstopo.admin.ch/en/terms-of-use-free-geodata-and-geoservices) |
| Austria | Datenquelle: basemap.at | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| France | © IGN – BD ORTHO® | [Licence Ouverte 2.0](https://www.etalab.gouv.fr/licence-ouverte-open-licence/) |
| Netherlands | Beeldmateriaal.nl | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Luxembourg | © ACT Luxembourg | [CC0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Belgium, Flanders | Orthofoto © Digitaal Vlaanderen | Modellicentie Gratis Hergebruik |
| Belgium, Brussels | Ortho © UrbIS – paradigm.brussels | [CC0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Czech Republic | Ortofoto: ČÚZK | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Poland | Ortofotomapa © GUGiK (geoportal.gov.pl) | [GUGiK terms](https://www.geoportal.gov.pl/pl/o-geoportalu/regulamin/) |
| Slovenia | Geodetska uprava Republike Slovenije, Ortofoto DOF025 | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Italy, South Tyrol | © Autonome Provinz Bozen – Südtirol | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Germany, 12 states | Each state's survey office: Bavaria, Baden-Württemberg, North Rhine-Westphalia, Berlin, Brandenburg, Saxony, Thuringia, Rhineland-Palatinate, Hesse, Schleswig-Holstein, Mecklenburg-Western Pomerania, Bremen | CC BY 4.0, [dl-de/by-2-0](https://www.govdata.de/dl-de/by-2-0) or [dl-de/zero-2-0](https://www.govdata.de/dl-de/zero-2-0), as each state publishes |
| United States, except Alaska | USDA, USGS The National Map: Orthoimagery | Public domain |

Where a provider's licence asks for changes to be marked: the imagery is clipped at the border of the area it covers, and nothing else is changed. The list can change without an app update: a source is added once its licence has been checked, and switched off if its provider asks us to. What fetching the imagery reveals to each provider is described in [the privacy policy](/privacy), section 3.11.


## 8.0 Contact

A question about the map, or a credit we got wrong? Get in touch through [support](/support).
