**Last updated**
September 2026


AéroCheck is an open-source flight checklist and situational-awareness app for pilots, developed and published by Julien Bono in Switzerland. This page says what the app keeps on your device, what it sends, to whom and how precisely, and what our own servers keep.

The short version: there is no account, no advertising, no analytics and no tracking. Your flights are kept on your device and in your own iCloud. Some requests carry a position, a route or a few points of a track, most of them rounded, so that the app can show weather, terrain and airspace (section 3.0 lists every one of them). Our API server keeps a record of a purchase, never a location.


## 1.0 What stays on your device

### 1.1 Flights and logbook
The GPS track, times, landings, flight plans, routes and your logbook are stored in the app's own storage on the device, and in your iCloud if you let them (section 2.0). Apart from the rounded points listed in section 3.0, they leave the device only when you export or share them (section 5.0).

### 1.2 Location and motion
The app uses GPS for the moving map, the recorded track, the instruments and the automatic detection of take-offs and landings, and the barometric altimeter (motion data) for altitude. The barometer readings never leave the device. The requests that carry a position are all listed in section 3.0.

### 1.3 Your own devices
The Apple Watch app and the companion mode (iPad and iPhone together) exchange flight data directly between your own devices, without going through a server. The home-screen widget reads the list of your aircraft from the device.

### 1.4 No analytics or tracking
AéroCheck contains no analytics or advertising SDK, no crash reporter and no tracking of any kind, and it does not use the advertising identifier. If you allow it in iOS (Settings, Privacy & Security, Analytics & Improvements, "Share With App Developers"), Apple passes anonymised crash reports to the developer; that is Apple's setting, not the app's.


## 2.0 iCloud

Your flights (with their tracks), flight plans, trips, flight pages and settings (including the pilot and instructor names you enter) are kept in AéroCheck's folder in your iCloud Drive, which is also why you can see them in the Files app. With "Sync to iCloud" on (in the app's settings, on by default), settings and flights are also synced between your devices through the app's private database in your iCloud account.

Both are your own iCloud account: Apple stores the data under [Apple's privacy policy](https://www.apple.com/legal/privacy/), and the developer has no access to it. To keep everything on the device, turn "Sync to iCloud" off in the app and turn iCloud Drive off for AéroCheck in the iOS Settings app.


## 3.0 What leaves your device, and to whom

"Rounded" below means the position is snapped to a grid before the request leaves the device. For scale, in Switzerland a quarter of a degree is about 28 by 19 km, three decimals about 100 m, and two decimals about 1 km.

### 3.1 AéroCheck weather proxy (wx.aerocheck.app)
Our own small server, which fetches aviation weather on the app's behalf.
- METAR and SIGMET near you: your position rounded to a quarter of a degree, while a flight is running or the navigation map is open, at most every five minutes.
- TAF: the ICAO code of one aerodrome (your planned destination during the approach briefing, otherwise the nearest station).
- Winds aloft: each waypoint of the route you plan, rounded to a quarter of a degree, and your position rounded the same way when you open Divert in flight.

The proxy rounds again on its side, then asks [aviationweather.gov](https://aviationweather.gov) (the US National Weather Service) for the METAR stations in a box around that grid point, for a TAF by its ICAO code, and for the SIGMET list without any position; and [Open-Meteo](https://open-meteo.com) for the winds aloft at that grid point. It never passes your IP address on. It keeps its answers in Cloudflare's cache for five minutes to an hour, by rounded position, and has no database.

### 3.2 swisstopo (Federal Office of Topography, geo.admin.ch)
- Swiss map tiles (the ICAO chart, the glider chart, the national maps and aerial images), on the navigation map and on share cards with a Swiss layer: the tiles requested show the area on screen, and the navigation map follows the aircraft. On the ICAO chart a tile is about 7 km wide; on the most detailed maps, about 100 m.
- Terrain in Switzerland: the waypoints of a route you plan (route profile, "Set altitudes", the elevation of a waypoint you edit), rounded to the metre; and, when you add terrain to a flight's share card, up to 200 points of the recorded track, its start and end included, rounded to the metre.
- MeteoSwiss surface wind, for the departure and approach briefings: during a flight, the app downloads the whole current wind dataset from data.geo.admin.ch every ten minutes, without any position. It only does so in or near Switzerland (so the request itself says that much).

### 3.3 Open-Meteo (open-meteo.com)
Terrain outside Switzerland, sent directly from the app: points along a route you plan ("Set altitudes"), or up to 80 points of a recorded track when you add terrain to its share card, start and end included, rounded to three decimals. Winds aloft go to Open-Meteo through our proxy (section 3.1).

### 3.4 OpenAIP (openaip.net)
- Airspace and other aeronautical data are downloaded per country: the request names the country, nothing else. For a planned route, the app asks OpenAIP how large the data is for the countries the route crosses that you have not downloaded yet (country codes only).
- "Online Airspace Data" (settings, off by default): while it is on, no airspace data is downloaded and the navigation map is open, your position rounded to two decimals, at most once a minute, and only once the last answer is more than five minutes old or the aircraft has moved more than 10 NM.
- OpenAIP chart tiles (off by default): the tiles show the area on screen.

### 3.5 Apple
- The Apple map layers, the route thumbnails and the maps on share cards (unless you pick a Swiss layer) come from Apple Maps, which receives the area shown.
- During the first setup, your current position once, to find your country and suggest what to download.
- Purchases go through the App Store; the app never sees your payment details or your Apple ID.

### 3.6 OurAirports
The airport database is downloaded whole, without any position.

### 3.7 AéroCheck API server (api.aerocheck.app)
No position ever. When you open an aircraft, the app sends its identifier, its registration and the language you use, to get the right checklist. With AéroCheck Pro, the app also sends the proof of purchase Apple gives it (a transaction signed by Apple) and that purchase's original transaction identifier, and from then on a session token with each request. What the server keeps is in section 4.0.


## 4.0 What our servers keep

Both servers run on Cloudflare, which handles the IP address of every request to deliver it, under [Cloudflare's privacy policy](https://www.cloudflare.com/privacypolicy/).

### 4.1 API server
- Per purchase, a record filed under the purchase's original transaction identifier: its status, expiry date, product, environment (App Store or test), whether it renews, and when it was last checked. It is kept until 30 days after a subscription's expiry date, for 90 days after the last check of a lifetime purchase, and for 7 days once a purchase has lapsed or been refunded.
- Which record a purchase belongs to, and a marker if Apple reports a refund, for 400 days.
- The session tokens the app authenticates with, as SHA-256 hashes only (never the tokens themselves), for 180 days, with a list of those hashes per purchase so that at most five are valid at a time.
- Your IP address, as part of a request counter that limits how often one address may call the server, for one minute.

Apple notifies the server of expiries, refunds and revocations; those notices only update the purchase record (and add the refund marker). The server never learns your name, your e-mail address or your Apple ID, and never receives a position. Its logs record the kind of event and identifiers shortened to their last four characters. Because the purchase record is filed under an identifier, the App Store privacy label declares the purchase history and a user ID as linked to you, used for the app's functionality and never for tracking.

### 4.2 Weather proxy
No database and no logs of its own: only the cache described in section 3.1.


## 5.0 Exports and sharing

You can export or share flights (GPX, JSON, ZIP), your logbook (PDF, CSV), flight plans and nav logs (GPX, JSON, spreadsheet, PDF) and share cards (images). Nothing is exported unless you ask. The copy the app prepares for the share sheet or the preview is deleted as soon as that sheet closes (or at the next launch, if the app was stopped first). Once shared, the file is yours to handle: it may contain your name and a detailed location history.


## 6.0 Permissions

- Location "While Using the App" draws the map and records the flight; "Always" keeps recording when the screen locks or you switch apps in flight.
- Motion lets the app read the barometric altimeter; the readings stay on the device.
- Photos (add only) lets you save a share card to your photo library. The app cannot see your photos.

You can change each of them at any time in the iOS Settings app.


## 7.0 Deleting your data

Deleting the app deletes its data on the device. To remove what is in your iCloud, delete AéroCheck's folder in iCloud Drive and the app's iCloud data (in the iOS Settings app, under your name, iCloud, storage). The purchase record on our server expires by itself (section 4.1); to have it deleted earlier, contact us (section 10.0).


## 8.0 This website

The site itself sets no cookies and runs no analytics. It is served by GitHub Pages through Cloudflare, and the aircraft page asks api.aerocheck.app for the current list from your browser.


## 9.0 Open source and changes

AéroCheck is open source: the [source code](https://github.com/fetzu/AeroCheck) lets anyone check what this page says. We update this policy when the app changes what it sends; the date at the top says when it last did.


## 10.0 Contact

For questions about this policy or your data, open an issue on the [GitHub repository](https://github.com/fetzu/AeroCheck/issues) (without personal details in it: we will get in touch to take it further).

See also the [terms of use](/terms), which cover what AéroCheck is, what it is not, and why the pilot in command remains responsible for everything it shows you.
