---
layout: page
title: Releases
include_in_header: true
---

# Release History

All notable changes to AéroCheck are documented here. For full details, visit the [GitHub Releases page](https://github.com/fetzu/AeroCheck/releases).

<br>

### `Latest`
# **Version 3.5.0** - Worldwide Airspace Data
*Released February 11, 2026*

### New Features

- **OpenAIP Airspace Overlay**: Worldwide airspace data overlay covering 119 countries, with support for continent-based downloads for offline use.
- **Streaming CTR Fallback**: When no airspace data is downloaded, nearby controlled airspace frequencies are fetched on-demand via the OpenAIP API (opt-in in Settings).
- **Dynamic CTR Frequencies**: The FREQ panel now shows controlled airspace boundaries, altitude limits, and frequencies from OpenAIP data instead of hardcoded Swiss CTR frequencies.

### Improvements

- **Continent-Based Downloads**: Download OpenAIP airspace data by region (Europe, Africa, Americas, Asia-Pacific) with per-country granularity.
- **FREQ Panel Reordering**: Nearby controlled airspace now appears before area frequencies for better visibility.
- **GPS Status Modal**: Redesigned as a centered card overlay for consistent display on both iPhone and iPad.

### Bug Fixes

- **OpenAIP Overlay on First Load**: Fixed OpenAIP tile overlay not rendering when first opening the map view.
- **FREQ Panel Data Loading**: Fixed CTR data not loading when navigating directly from Home to Navigation view.
- **OurAirports Fallback**: OurAirports TWR frequencies now correctly serve as fallback when no OpenAIP data is available.

**Full Changelog**: https://github.com/fetzu/AeroCheck/compare/3.4.0...3.5.0

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/3.5.0)

<br>

________

<br>

## **Version 3.4.0** - Share Cards, Navigation Fixes & Terrain Charts
*Released February 08, 2026*

### New Features

- **Flight Share Cards**: Redesigned flight share card for social media stories (1080×1920) with customizable color themes, route strip with map layers (Standard, SwissTopo ICAO, Segelflugkarte), real terrain elevation data, and aircraft/flight statistics.

### Improvements

- **Share Card Terrain Chart**: Altitude chart now shows real terrain elevation profile beneath the flight path using Path-based rendering for accurate layering.
- **Share Card Export**: Share card export uses direct UIKit presentation for reliable first-export behavior.
- **Subscription Refresh**: Aircraft list is now re-fetched automatically when a subscription becomes active.

### Bug Fixes

- **Navigation/Map**: Fixed map centering, top bar width, aircraft icon movement, track visibility, GPS status, compass size, and settings persistence.
- **Flight Planning**: Fixed next check display and image export issues.
- **Share Card**: Fixed route strip rendering, footer layout, map tile loading, share speed, path thickness, color theme label truncation.
- **General**: Resolved 13 navigation and flight plan issues, added photo library permission for share sheet save.

**Full Changelog**: https://github.com/fetzu/AeroCheck/compare/3.3.0...3.4.0

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/3.4.0)

<br>

## **Version 3.3.0** - Flight Events, Map Frequencies & Nav Plan Timing
*Released February 05, 2026*

### New Features

- **Nav Plan Auto-Timing**: Timing fields in the navigation plan are now auto-populated from flight data when a flight ends (Block Off/On, Time On/Off, Counter Start/Stop, Engine Time, Landings).

### Improvements

- **Airport Frequencies on Map**: Tapping an airport on the map now shows all available frequencies, one per line, with the airport name displayed above.
- **Flight Event Detection**: Rewritten flight event detection using a state machine for more reliable go-around and touch-and-go detection.
- **Nav Plan Timing Layout**: Time On/Off order swapped in the UI (Time On first). Engine time now displays in HH:MM format.

### Bug Fixes

- **Flight Log**: Fixed elapsed time display showing negatives for short flights, fixed empty state layout.
- **Navigation/Map**: Fixed heading indicator alignment, fixed frequency panel layout, fixed map overlay toggle persistence.
- **Flight Planning**: Fixed terrain profile rendering, fixed route editing sheet environment objects.
- **General**: Fixed phase names wrapping incorrectly, fixed checklist long-press reset behavior.

**Full Changelog**: https://github.com/fetzu/AeroCheck/compare/3.2.3...3.3.0

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/3.3.0)

<br>

## **Version 3.2.3** - Engine Hours Improvements
*Released February 04, 2026*

### Improvements

- **Engine Hours Display**: Engine hours now display with two decimal places for more precise readings (e.g., 1234.50 instead of 1234.5).
- **Engine Hours Modal**: The "Before Start" modal now appears when navigating to the Engine Start phase rather than when pressing the Engine Start button.
- **Engine Hours Inline Display**: Engine hours are now shown inline in the checklist view, tappable to edit.
- **Engine Hours Reset**: Re-displays the modal with pre-filled value when Engine Shutdown is reset via long-press.
- **Flight Log View**: Engine hours now show in both decimal and time formats (e.g., "1.25 / 1:15"). Before/After values are tappable to toggle format.
- **iPad Layout Fix**: Fixed the hour meter input modal where bottom buttons were cut off on iPad.

**Full Changelog**: https://github.com/fetzu/AeroCheck/compare/3.2.2...3.2.3

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/3.2.3)

<br>

## **Version 3.2.2** - Airport Data Fix
*Released February 04, 2026*

### Bug Fixes

- **Airport Data Persistence**: Fixed airport database appearing as not downloaded after restarting the app. Downloaded OurAirports data (airports, frequencies, runways) now correctly persists across app launches.

**Full Changelog**: https://github.com/fetzu/AeroCheck/compare/3.2.1...3.2.2

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/3.2.2)

<br>

## **Version 3.2.1** - Icon Fix
*Released February 03, 2026*

### Bug Fixes

- **Onboarding Logo**: Fixed missing app icon on the onboarding welcome screen. The logo outline was visible but the image was empty due to a missing asset reference.

**Full Changelog**: https://github.com/fetzu/AeroCheck/compare/3.2.0...3.2.1

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/3.2.1)

<br>

## **Version 3.2.0** - Guided Experience
*Released February 03, 2026*

### What's New

#### Onboarding Flow
A new guided introduction for first-time users:

- **5-Page Walkthrough**: Welcome, Checklists, Navigation, Briefings, and Ready to Fly screens
- **Feature Discovery**: Learn about all 16 flight phases, learning mode, circuit mode, and more
- **Download Recommendations**: Optionally download airport data and Swiss ICAO charts during onboarding
- **Existing User Bypass**: Users who already have flights in their log skip onboarding automatically

#### Redesigned Settings
Settings restructured following Apple Human Interface Guidelines:

- **NavigationStack Hub**: Clean top-level menu with 6 categorized sub-pages
- **Aircraft & Subscription**: Aircraft management and subscription in one place
- **Checklist & Flight**: Step-by-step highlighting, learning mode, and flight logging options
- **Navigation & Maps**: Map layers, offline charts, and airport data management
- **Flight Planning**: Route planning and terrain profile settings
- **Sync & Data**: iCloud sync, GPS, and data statistics
- **About**: Version info, available checklists, and developer options

#### Smart Briefings & Flight Events
New in-flight intelligence features:

- **Dynamic Briefings**: Departure and approach briefings with nearby airport detection, runway suggestions, wind data, and emergency procedures
- **Flight Event Detection**: Automatic detection of go-arounds, touch-and-gos, and full-stop landings
- **Engine Hour Logging**: Optional Hobbs meter input at the end of each flight

#### Airport Database Integration
Access worldwide airport data:

- **40,000+ Airports**: OurAirports database with frequencies, runways, and elevation data
- **Nearby Frequencies**: See relevant radio frequencies based on your GPS position
- **Lazy Loading**: Airport data loads only when needed to keep startup fast

#### Performance & Localization
Under-the-hood improvements:

- **Full French Translation**: All UI strings now available in English and French
- **GPS Optimization**: Improved accuracy settings and signal quality timer
- **Airport Data Lazy Loading**: Better memory usage with on-demand data loading

#### Bug Fixes
- Fixed briefing section titles showing "(tap to view)" text inside the briefing view
- Added "NAV" label text to compact iPhone navigation button
- Fixed PLAN panel content overflowing on iPhone screens
- Fixed END FLIGHT button layout wrapping on iPad in portrait mode
- Added Reset Onboarding option in developer settings
- Multiple UI/UX improvements across checklist, navigation, and settings views

---

This release focuses on making AeroCheck more welcoming for new users with guided onboarding, while improving organization with a redesigned settings experience and adding powerful in-flight briefing capabilities.

**Full Changelog**: https://github.com/fetzu/AeroCheck/compare/3.1.0...3.2.0

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/3.2.0)

<br>

## **Version 3.1.0** - Multilingual Checklists
*Released February 02, 2026*

### What's New

#### Multilingual Checklist Support
Access checklists in multiple languages:

- **French WT9 Checklist**: Now available alongside the English version
- **Bundled Checklists**: WT9 Dynamic checklists (English and French) are now bundled directly in the app for instant availability
- **Language Selection**: Choose your preferred checklist language for supported aircraft
- **Offline First**: Bundled checklists work immediately without requiring a download

#### Flying Club Organization
Better aircraft organization:

- **Aeroclub Sorting**: Aircraft are now organized and sorted by flying club
- **Club Identification**: See which aeroclub each aircraft belongs to at a glance

#### Enhanced Reliability
Improved startup and data handling:

- **API v3 Upgrade**: Updated to use the latest API version with better error handling
- **Startup Resilience**: App now handles temporary network issues gracefully during startup
- **Version Checking**: Bundled checklists are automatically checked for updates against the server

#### Bug Fixes
- **Flight Log**: Flight names now display aircraft registration (e.g., \"HB-PFA\") instead of internal IDs
- **Checklist Selection**: Fixed issue preventing French WT9 checklist from being properly selected and used

---

This release focuses on making AeroCheck more accessible with multilingual support and improving the overall user experience with better organization and reliability.

**Full Changelog**: https://github.com/fetzu/AeroCheck/compare/3.0.0...3.1.0

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/3.1.0)

<br>

## **Version 3.0.0** - Premium Takes Flight
*Released January 24, 2026*

### What's New

#### Premium Subscription
Unlock additional aircraft with a monthly or yearly subscription:

- **Premium Aircraft**: Access detailed checklists for additional aircraft types beyond the free WT9 Dynamic
- **Seamless Updates**: Premium checklists are downloaded and cached automatically
- **Subscription Management**: View your subscription status and manage it directly in the app

#### Apple Watch Companion App
Keep track of your flight from your wrist:

- **Real-time Flight Data**: View current phase, speed, and altitude on your Apple Watch
- **Always Synced**: Flight status updates automatically via WatchConnectivity
- **Glanceable Design**: Quick access to essential flight information

#### iCloud Sync
Your settings and flights, everywhere:

- **Settings Sync**: Preferences sync across all your devices
- **Flight History**: Access your flight log from any device
- **Automatic Backup**: Your data is safely stored in iCloud

#### Multi-Language Support
Now available in French:

- **Complete Translation**: All UI elements translated to French
- **Language Switching**: Follows your device language settings
- **Original Phase Names**: Checklist phase names remain in their original language for clarity

#### Flight Plan GPX Export (Beta)
Export your navigation plan for your avionics:

- **GPX Route Export**: Compatible with Dynon SkyView, Garmin G3X, and other MFDs
- **Quick Sharing**: Export directly from the flight plan editor

#### Other Improvements
- Segelflugkarte max zoom level corrected for proper tile display
- Various UI refinements and stability improvements

---

This is a major release featuring our new premium subscription model, Apple Watch support, and iCloud synchronization. The free tier continues to include the full-featured WT9 Dynamic checklist with all navigation and tracking features.

**Full Changelog**: https://github.com/fetzu/AeroCheck/compare/2.7.0...3.0.0


[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/3.0.0)

<br>

## **Version 2.7.0** - Navigate and Communicate
*Released January 01, 2026*

### What's New

#### 📻 Radio Frequencies (Switzerland)
Stay tuned to the right frequency with the new radio overlay in Navigation Mode:

- **Quick access** to common Swiss frequencies (Geneva Info, Zurich Info, FIS East/West, Emergency)
- **Nearby CTR frequencies**: Automatically displays tower/info frequencies for control zones near your position
- **Flight plan frequencies**: Shows frequencies for waypoints in your navigation plan
- **Smart location detection**: Automatically suggests Geneva or Zurich sector based on your position

#### 🧭 Enhanced Navigation
- **Flight Planning** (Beta): Create waypoint routes with terrain profiles
- **ETO to next waypoint**: Estimated time shown on the chronometer overlay
- **Terrain profiles**: Visualize elevation along your planned route

#### 🔄 Circuit Training Mode
Perfect for pattern work and touch-and-go practice:

- **Streamlined phases**: Skips irrelevant phases (Cruise, Descent) during circuit training
- **Full-stop tracking**: New FULL STOP button records your landings
- **Go-around support**: Easily cycle back through approach phases

#### 🐛 Fixes & Improvements
- Improved layouts for small devices (iPhone) and large devices (iPad Pro)
- Better backward compatibility for importing old flight exports
- Various UI and stability improvements

---

⚠️ **Important**: This application is provided solely for training and pedagogical purposes. Always rely on official checklists and AIP for operational decisions.

**Full Changelog**: https://github.com/fetzu/AeroCheck/compare/v2.6.0...v2.7.0


[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/2.7.0)

<br>

## **Version 2.6.0** - Cache-cache
*Released December 21, 2025*

### What’s New

#### Swiss ICAO & swisstopo Maps — Faster, Smarter, More Reliable
- **Cache-first tile loading** for ICAO charts: cached tiles now load instantly in online mode, with seamless network fallback.
- **Extended caching support** for the Segelflugkarte, with user control over caching:
  - ICAO only  
  - ICAO + Segelflugkarte
- **Offline mode enhancements**:
  - Full offline support for ICAO **and** Segelflug layers
  - Smooth zoom transitions when both layers are cached
- **New Cache Info sheet** showing detailed cache status for each layer.
- Corrected branding: *“Swiss Topo” → **swisstopo***.
- Improved cache management UI and status indicators.

> Existing ICAO caches remain fully compatible — **no breaking changes**.

#### Offline Downloads — Faster & More Informative
- **Faster tile downloads** thanks to optimized networking:
  - Increased concurrent connections (up to 6)
  - Larger batch sizes for improved parallelism
  - Tuned URLSession timeouts
- **Estimated Time Remaining (ETA)** now shown during offline chart downloads, updating live based on download speed.

#### Navigation View — Cleaner, More Aviation-Correct
- **Improved aircraft marker design**:
  - Smaller, cleaner icon (18pt) aligned with Apple’s HIG
  - Removed glow, refined shadows, consistent aviation gold color
- **Correct heading rendering**:
  - Fixed SF Symbol orientation quirks so 0° = North, 90° = East, etc.
- **Better visibility on all map types**:
  - Added high-contrast black outline for readability on satellite and SWISSIMAGE.
- **Smoother updates**:
  - Aircraft annotation now updates in place (no blinking).
  - Smooth heading animations.
- **Marketing mode track support**:
  - Flight path is now visible during simulated flights.

#### Marketing Mode (Hidden)
A new **hidden Marketing Mode** for generating App Store screenshots and demos:
- Hidden **Developer Options** (tap App Version 5 times)
- **Marketing Location Provider** with predefined Swiss flight scenarios
- Playback controls with speed adjustment (0.5×–20×)
- Custom static positioning for screenshots
- Stable GPS signal simulation
- Shake gesture to show/hide marketing controls
- Includes historical and demo flight logs:
  - Wright (1903), Quimby (1912), Lindbergh (1927), Yeager (1947)
  - LSZQ Alpine Tour (Bressaucourt → Sion → Samedan → Bressaucourt)

Marketing mode is **session-only** and does not persist across app restarts.

#### Flight Log Improvements
- **Year display** added below the month in the date indicator.
- **Chronological sorting fixed** — most recent flights first, including imports.
- Refined layout:
  - Better spacing and icon sizing
  - Added clock icon for session start time
  - Cleaner metadata ordering (time, distance, GPS points)

#### iPhone UI Refinements
- **Speed Reference** redesigned using a two-column grid:
  - Larger fonts
  - Clearer grouping of values and descriptions
- **Navigation View** metrics stacked into two compact rows on iPhone.
- **Settings**: fixed external link icon alignment in Open Source section.

### Bug Fixes & Stability

#### iPad ICAO Grid & Zoom Issues — Fully Resolved
A series of fixes addressing the **grey grid pattern** and zoom glitches on iPad:
- ICAO is now the **default map layer**, avoiding invalid Apple Maps zoom carry-over.
- Initial map region is **clamped** to valid Swiss tile zoom levels.
- Initialization order fixed so tile overlays are ready before MapKit requests tiles.
- Corrected ICAO / Segelflugkarte zoom mismatches (Segelflug max zoom = 14).
- Added a targeted workaround simulating a layer switch on init to fully resolve iPad-specific edge cases.

### Internal Improvements
- Centralized version numbers as a single source of truth:
  - Checklist versions now live in their respective data files.
  - App version is read directly from `Info.plist`.
- Minor cleanup and removal of unused variables.

Happy flying! 🛩️

**Full Changelog**: https://github.com/fetzu/AeroCheck/compare/2.5.0...2.6.0

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/2.6.0)

<br>

## **Version 2.5.0** - going with the wind!
*Released December 16, 2025*

### What's New

#### Clearer Speed Display
The speed indicator now correctly shows **ground speed** instead of the misleading "KIAS" label. Since GPS can only measure ground speed (not indicated airspeed), the display now shows:
- **"GND SPD"** label on iPad / **"GS"** on iPhone
- **"kt"** (knots) unit

This change provides clearer, more accurate information to pilots.

#### Experimental: Estimated Airspeed (Switzerland only)
A new optional feature that estimates your indicated airspeed by combining GPS ground speed with real-time wind data from MeteoSwiss weather stations.

**How it works:**
- Fetches wind speed and direction from the nearest MeteoSwiss automatic weather station
- Applies wind correction to your GPS ground speed
- Displays "EST. IAS" with amber highlighting

**Important limitations:**
- ⚠️ Only works within Switzerland
- ⚠️ Requires constant cellular connection
- ⚠️ Can be highly inaccurate due to local wind variations and station distance
- ⚠️ **Always rely on your aircraft's onboard airspeed indicator**

This feature is disabled by default. Enable it in Settings > Experimental, where you'll need to acknowledge a safety warning before activation.

#### Other Improvements
- Briefing views now show "AIRSPEEDS (IAS)" section header
- Speed reference modal renamed to "AIRSPEEDS (AFM)" for clarity
- Documentation updated to reflect all changes

**Safe flying! ✈️**

---

### What's Changed
* feat: clarify ground speed display and add experimental estimated airspeed by @fetzu in https://github.com/fetzu/AeroCheck/pull/15
* feat(ui): add NAV button and fix GPS status display by @fetzu in https://github.com/fetzu/AeroCheck/pull/16


**Full Changelog**: https://github.com/fetzu/AeroCheck/compare/2.1.0...2.5.0

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/2.5.0)

<br>

## **Version 2.1.0** - (No) Signal in the Sky !
*Released December 15, 2025*

### What's Changed
* feat(nav): add offline ICAO chart caching by @fetzu in https://github.com/fetzu/AeroCheck/pull/12
* style(icon): replace app icon with SF Symbol airplane by @fetzu in https://github.com/fetzu/AeroCheck/pull/13
* feat: add "Always use UTC times" setting by @fetzu in https://github.com/fetzu/AeroCheck/pull/14


**Full Changelog**: https://github.com/fetzu/AeroCheck/compare/2.0.0...2.1.0

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/2.1.0)

<br>

## **Version 2.0.0** - Going somewhere?
*Released December 14, 2025*

🚀 New Navigation Mode in AeroCheck!

This release introduces a brand-new Navigation mode in AeroCheck, featuring an interactive map view directly in the app. You can now follow your aircraft position and GPS track while switching between multiple map layers, including Apple Maps (standard & satellite), ICAO charts, Swiss national maps, and aerial imagery.

The new Navigation mode makes it easier to visualize your flight, terrain, and airspace context — both during and after a flight. ✈️

Give it a try and let us know what you think!

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/2.0.0)

<br>

### `Initial Release`
## **Version 1.0.0** - Take Off Check completed !
*Released December 07, 2025*

### Release description
We’re excited to introduce AeroCheck v1.0.0, the first official release of our iOS/iPadOS learning application. Crafted with the powerful and inspiring assistance of Claude 4.5 Sonnet & Opus, this version brings you the following core features:
	•	Complete walkthrough of the ATC “AeroCheck” task-flow (briefing → taxi → take-off → en-route → descent → landing).
	•	Integrated checklists matching each phase of flight, allowing you to tap through and familiarise with real-world procedures.
	•	On devices with cellular capability: live-display of speed and altitude (via built-in sensors) to enhance your situational awareness practice.
	•	Fully native support for both iPhone and iPad — optimised for classroom and cockpit-style tablet use alike.
	•	Designed as a learning and rehearsal tool: practice flows, reinforce knowledge, and deepen your understanding of pressure, altitude and air-taxi operations.

⚠️ Important reminder: AeroCheck is not certified for in-flight operational use. Always rely on official checklists from your aircraft manufacturer and the latest documentation from your AFM/POH. Never substitute AeroCheck for procedural compliance. Use it as a supplementary study and training aid only.

Thank you for downloading and welcome to your first step in mastering the AeroCheck workflow. Safe learning — and clear skies ahead!

### What's Changed
* feat: add altitude tracking and altimeter display by @fetzu in https://github.com/fetzu/AeroCheck/pull/1
* feat: add multi-aircraft support with PA-28 checklist  by @fetzu in https://github.com/fetzu/AeroCheck/pull/2
* feat: added iPhone support by @fetzu in https://github.com/fetzu/AeroCheck/pull/3
* feat: enhance UX with altitude profile, GPS-flags & quick-start widgets by @fetzu in https://github.com/fetzu/AeroCheck/pull/4
* feat(flight-share): redesign share card to portrait (9:16) + map & altitude profile by @fetzu in https://github.com/fetzu/AeroCheck/pull/5
* feat(settings): enrich About screen with links & open-source details by @fetzu in https://github.com/fetzu/AeroCheck/pull/6
* feat(flight-log): display go-arounds and touch-and-goes in altitude profile by @fetzu in https://github.com/fetzu/AeroCheck/pull/7
* fix(flight): keep timer running after engine shutdown by @fetzu in https://github.com/fetzu/AeroCheck/pull/8
* fix(flight-log): constrain altitude chart area fill to visible range by @fetzu in https://github.com/fetzu/AeroCheck/pull/9
* feat(import-export): add bulk import & enhance export/import metadata by @fetzu in https://github.com/fetzu/AeroCheck/pull/10

### New Contributors
* @fetzu made their first contribution in https://github.com/fetzu/AeroCheck/pull/1

**Full Changelog**: https://github.com/fetzu/AeroCheck/commits/1.0.0

### Note
The original app name (and release notes) was "AéroCheck". It has been subsequently renamed to "AeroCheck" to avoid confusion.

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/1.0.0)

<br>

