**Last updated**
October 2026


Since version 6.8.0, AéroCheck draws its own map for flying, the pilot's map. This page says where its data comes from, what we keep of it and what we leave out, how it is cut and updated, and who is credited. Section 4.6 of the Open Database Licence asks that anyone using a map made from OpenStreetMap can find out how it was made: this is that page.


## 1.0 What the map is

The pilot's map is drawn on your device by MapLibre Native, from vector tiles we build each month from OpenStreetMap, and from relief. It shows what you look for out of the window: towns and villages by size, main roads, railways, rivers and lakes, forests, built-up areas, glaciers, borders, cable cars, and peaks with their height in feet. The aeronautical layers (airspace, aerodromes, procedures, your route) are drawn over it, as on the Swiss charts.

It comes in two parts:
- **The world outline**, in the app itself: land, sea, the larger lakes and rivers, borders, countries and capitals. It is what the map shows where no region is on the device.
- **Regions**, one per country, built from the full data: Switzerland with Liechtenstein first, more to follow. A region is read online within a monthly allowance, or downloaded and used offline.


## 2.0 Where the data comes from

- **OpenStreetMap**: © OpenStreetMap contributors, under the [Open Database Licence](https://opendatacommons.org/licenses/odbl/1-0/) (ODbL 1.0), read through the daily build of the [Protomaps basemap](https://docs.protomaps.com/basemaps/downloads). The map's data is a produced work under the ODbL: you can find the data itself at [openstreetmap.org](https://www.openstreetmap.org/copyright).
- **Relief**: [Mapterhorn](https://mapterhorn.com), open terrain data from national and global elevation models. Its sources and their licences are listed at [mapterhorn.com/attribution](https://mapterhorn.com/attribution).
- **Country names and major rivers** of the world outline: [Natural Earth](https://www.naturalearthdata.com) (public domain).
- **Typeface**: [B612](https://github.com/polarsys/b612), designed for cockpit screens, under the SIL Open Font License 1.1.
- **Drawing**: [MapLibre Native](https://maplibre.org), under the BSD 2-Clause licence.


## 3.0 What we keep, and what we leave out

The build reads the Protomaps tiles and keeps, feature by feature, what a pilot uses. The geometry of what it keeps is copied as it is: nothing is simplified again or moved.

### 3.1 Kept
- Land and land cover.
- Forests and woods, built-up areas (residential, commercial and industrial) and glaciers.
- Water: seas, lakes, rivers and canals, with their names.
- Country borders.
- Roads: motorways, trunk, primary and secondary roads, with their numbers, and whether they run in a tunnel.
- Railways: main lines, narrow-gauge lines and funiculars, with their tunnels (not sidings or service tracks). Cable cars and other aerial lifts.
- Places: cities, towns, villages, hamlets and isolated dwellings, with their names and population, which decide from which zoom a place shows.

### 3.2 Added
- **Peaks**, a layer of our own made from OpenStreetMap's peaks: the name, the height in feet, and the distance to the nearest higher peak, which decides from which zoom a peak shows (a summit standing alone shows before a bump on a ridge).

### 3.3 Left out
- Buildings, shops and other points of interest, public transport, minor roads, tracks and paths, and state or regional borders.
- Every field the map does not draw: a feature keeps its kind, its name, its road number or its population, nothing else.


## 4.0 Cut at the border

A region holds the data inside its own country and nothing else, so two regions never draw the same place twice. The border is OpenStreetMap's own, taken from the region's most detailed tiles and closed into a line around the country, with the enclaves left out. Every tile that crosses it is cut along it, at every zoom, and the relief outside it is cleared. Past the border, the neighbouring region takes over where it is on the device, and the world outline everywhere else.


## 5.0 Built each month

The map is rebuilt every month from the latest OpenStreetMap data, and the same data always gives the same file, byte for byte. Each file is named after its content. That is what keeps updates small:
- A device asks for a region's file by that name, and asks again only when the name has changed: a region that did not change is never downloaded twice.
- When it checks, the device says which version it has, and an unchanged answer is a few bytes.
- A downloaded region updates itself every three months, on Wi-Fi, never in flight. When the app offers **Update**, it fetches the newer build sooner.

OpenStreetMap is edited every minute, so a monthly map is at most a few weeks behind it. Something missing or wrong on the map is best fixed [in OpenStreetMap itself](https://www.openstreetmap.org/fixthemap): the next build picks it up.


## 6.0 How the app gets the map

The files are kept on tiles.aerocheck.app, Cloudflare's storage under our name. A downloaded region is read on the device and works offline. Elsewhere the app reads the tiles on screen online, within a monthly allowance per device: 1,500 tiles, or 15,000 with AéroCheck Pro. A downloaded region never counts against it. What these requests show, and what we keep of them, is in [the privacy policy](/privacy), section 3.10.


## 7.0 Aerial imagery

The **Aerial imagery** layer shows open government orthophotos, and only those. Each device fetches them from the government's own service while they are on screen: AéroCheck hosts none, bundles none and downloads none ahead. Each source is used under its open licence, cut at the border of the area it covers, and credited in its own words on the map while its imagery shows; where several are on screen at a border, each one is. Where no government publishes imagery we may use, the layer shows no imagery.

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
| Italy, South Tyrol | © Autonome Provinz Bozen – Südtirol | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Germany, 12 states | Each state's survey office: Bavaria, Baden-Württemberg, North Rhine-Westphalia, Berlin, Brandenburg, Saxony, Thuringia, Rhineland-Palatinate, Hesse, Schleswig-Holstein, Mecklenburg-Western Pomerania, Bremen | CC BY 4.0, [dl-de/by-2-0](https://www.govdata.de/dl-de/by-2-0) or [dl-de/zero-2-0](https://www.govdata.de/dl-de/zero-2-0), as each state publishes |
| United States, except Alaska | USDA, USGS The National Map: Orthoimagery | Public domain |

Where a provider's licence asks that changes be marked: the imagery is clipped at the border of the area it covers, and nothing else is changed. The list can change without an app update: a source is added once its licence is checked, and switched off if its provider asks. What fetching the imagery shows to each provider is in [the privacy policy](/privacy), section 3.11.


## 8.0 Contact

A question about the map, or a credit we got wrong: [support](/support).
