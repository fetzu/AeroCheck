# AéroCheck

AéroCheck walks a pilot through the checklists of a flight on an iPad (or an iPhone), from the preflight to the hangar, while it records the track and keeps the paperwork that comes with it.

> AéroCheck is a training aid. Its information is not guaranteed to be accurate and must not be used for operational decisions: the aircraft's flight manual (AFM) and its approved checklists always come first.

_This app has been entirely vibe coded. If you hate that, feel free to close your browser window in disgust and not use it._

It was built for the kneeboard: an iPad in portrait on the pilot's knee, three pages in flight (the checklist, the chart and the route), big type, and buttons that stay where the thumb expects them. Around that it plans routes on the Swiss charts (OpenAIP elsewhere), briefs the departure and the approach, reads the METARs and SIGMETs, draws traffic circuits and VFR routes from open flightmaps, keeps a logbook, and can pair an iPhone as a second screen (iOS 26 on both). What it does, screen by screen, is in the [manual](https://aerocheck.app/manual/) (EN/FR); what changed, and when, is in the [releases](https://github.com/fetzu/AeroCheck/releases).

The WT9 Dynamic's checklist (F-HVXA) is bundled and free. The other aircraft (15 registrations, from GVMP Porrentruy, Lausanne Aéroclub and GVMN Neuchâtel) come from the AeroCheck API with an AeroCheck Pro subscription: monthly, yearly or a one-time lifetime purchase, through the App Store. The current list is on [aerocheck.app](https://aerocheck.app).

## Building it

You need Xcode 26 (Companion mode imports the iOS 26 SDK); the app itself runs on iOS and iPadOS 17 and later.

1. Clone the repository and copy the secrets template: `cp Secrets.example.xcconfig Secrets.xcconfig` (the copy is gitignored).
2. Fill in what you have. Without an `OPENAIP_API_KEY` the app builds and runs, but every OpenAIP request gets a 401 and the airspace, the CTR frequencies and the airspace conflicts stay empty. `WEATHER_CLIENT_SECRET` and `APP_CLIENT_SECRET` have to match the weather proxy's and the API's (they live in AeroCheck-server, which is private); left empty, the parts that need them stay quiet.
3. Open `AeroCheck.xcodeproj`, pick the `AéroCheck` scheme and your team under Signing & Capabilities, and run.

The unit tests are the `AeroCheckTests` scheme (`scripts/run-tests.sh` wraps them; read its caveats in [CLAUDE.md](./CLAUDE.md) before you use it). To try the subscriptions without paying, set the scheme's StoreKit configuration to `AeroCheck/Configuration.storekit` (Edit Scheme › Run › Options). To talk to a local API, start AeroCheck-server with `npm run dev` and point `API_BASE_URL_SANDBOX` in `Config.xcconfig` at `http:/$()/localhost:8787` (locally, don't commit it; the `$()` keeps xcconfig from reading `//` as a comment, and setting it in `Secrets.xcconfig` does nothing, since `Config.xcconfig` sets it after the include): a Debug build always uses the sandbox URL.

## How it fits together

- this repository: the app, its widget and its Watch app (Swift/SwiftUI); its `website` branch is [aerocheck.app](https://aerocheck.app) (Astro), deployed on every push;
- AeroCheck-server (private): the API on Cloudflare Workers (subscriptions, premium checklists, airfield tariffs) and the weather proxy;
- AeroCheck-checklists (private): the checklists themselves, one JSON file per registration and language.

[CLAUDE.md](./CLAUDE.md) has the project structure, the conventions and the release steps. It is written for the coding agents, but humans are allowed to read it too.

## Exports

A flight exports as GPX 1.1 or JSON (the whole logbook as a ZIP of either), and both import back. The GPX carries AéroCheck's own data (the flight's times, its distance, each point's speed and course) in a `pc:` namespace (`http://aerocheck.app/gpx/1`) inside `<extensions>`, so any other GPX reader ignores it and still sees a valid track. The JSON wraps the flight in an envelope: `metadata` (app, version, format version, export date), `flight`, and `flightPlan` when one was active.

## Privacy

Flights, tracks and settings stay on the device and in your own iCloud (CloudKit's private database); none of it goes to AeroCheck's servers. Maps, airspace, airports and the VFR data are fetched by area or by country, never by position. The one exception is the terrain profile: the route (or a sampled track, rounded to about 100 m) goes to swisstopo in Switzerland and to Open-Meteo elsewhere, to look up the ground under it. The whole policy is on [aerocheck.app/privacy](https://aerocheck.app/privacy/).

## Data sources and licences

AéroCheck shows other people's geographic, aeronautical and weather data, under their terms. The app credits each of them in Settings › About › Data sources (and on the map and share cards where their data shows).

| Data | Source | Attribution |
|------|--------|-------------|
| ICAO / Segelflug / Landeskarte / SwissImage chart tiles | **swisstopo / BAZL** (geo.admin.ch) | © swisstopo / BAZL |
| Terrain elevation (Switzerland) | **swisstopo** profile API | © swisstopo |
| Terrain elevation (worldwide), winds aloft | **Open-Meteo** (CC BY 4.0) | Elevation: Open-Meteo |
| Wind (experimental, Switzerland) | **MeteoSwiss** Open Data (geo.admin.ch) | © MeteoSwiss |
| METAR / TAF / SIGMET | **NOAA Aviation Weather Center** (public domain), through wx.aerocheck.app | NOAA Aviation Weather Center |
| Airspace, aerodromes, navaids, obstacles, reporting points | **OpenAIP** (CC BY-NC 4.0) | © OpenAIP and contributors |
| Airport / runway / frequency data | **OurAirports** (public domain) | OurAirports |
| Traffic circuits, VFR arrival and departure routes and their sectors, the reporting points OpenAIP lacks (CH, AT, DE, CZ) | **open flightmaps** (General Users' License: free, commercial use included, as long as the data is credited and errors can be reported back; never a primary source of navigation) | © open flightmaps association |
| Official chart links, per aerodrome | Links to **DFS** BasicVFR (DE), the **SIA** VAC atlas (FR), **skyguide**'s eVFR Manual on SkyBriefing (CH, subscription) and the **Austro Control** eAIP (AT); the app never downloads or shows a chart | The publisher's terms, on its own site |

The VFR procedures and the chart links are small files on aerocheck.app, rewritten every Thursday at 05:00 UTC (the AIRAC day) by `.github/workflows/vfr-data.yml` from open flightmaps and the publishers' sites; the scripts and the schema are in `scripts/vfrdata/` on the `website` branch. The offline ICAO and glider charts are a bulk download of swisstopo/BAZL products, which needs their agreement to ship (tracked as SEC-09).

## Credits

The checklists are the clubs' own: the WT9's from the Groupe de Vol à Moteur de Porrentruy (Aéroclub du Jura, v2.1e), the others from GVMP, Lausanne Aéroclub and GVMN Neuchâtel. The procedures follow SPHAIR's "Bases et procédures".

## Support and licence

Bugs and questions go to the [GitHub issues](https://github.com/fetzu/AeroCheck/issues) or to support@aerocheck.app ([aerocheck.app/support](https://aerocheck.app/support/)); support is best effort. The app's code is under the MIT licence ([LICENSE](./LICENSE)), the premium checklists are proprietary, and the third-party data stays under its providers' licences.

Safe flying!
