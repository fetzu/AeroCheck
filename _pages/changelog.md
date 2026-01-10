---
layout: page
title: Releases
include_in_header: true
---

# Release History

All notable changes to AéroCheck are documented here. For full details, visit the [GitHub Releases page](https://github.com/fetzu/AeroCheck/releases).

<br>

### `Latest`
# **Version 2.7.0** - Navigate and Communicate
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

⚠️ **Important**: AéroCheck is provided solely for training and pedagogical purposes. Always rely on official checklists and AIP for operational decisions.

**Full Changelog**: https://github.com/fetzu/AeroCheck/compare/v2.6.0...v2.7.0


[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/2.7.0)

<br>

________

<br>

### `Initial Release`
# **Version 2.6.0** - Cache-cache
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

🚀 New Navigation Mode in AéroCheck!

This release introduces a brand-new Navigation mode in AéroCheck, featuring an interactive map view directly in the app. You can now follow your aircraft position and GPS track while switching between multiple map layers, including Apple Maps (standard & satellite), ICAO charts, Swiss national maps, and aerial imagery.

The new Navigation mode makes it easier to visualize your flight, terrain, and airspace context — both during and after a flight. ✈️

Give it a try and let us know what you think!

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/2.0.0)

<br>

## **Version 1.0.0** - Take Off Check completed !
*Released December 07, 2025*

### Release description
We're excited to introduce AéroCheck v1.0.0, the first official release of our iOS/iPadOS learning application. Crafted with the powerful and inspiring assistance of Claude 4.5 Sonnet & Opus, this version brings you the following core features:
	•	Complete walkthrough of the flight task-flow (briefing → taxi → take-off → en-route → descent → landing).
	•	Integrated checklists matching each phase of flight, allowing you to tap through and familiarise with real-world procedures.
	•	On devices with cellular capability: live-display of speed and altitude (via built-in sensors) to enhance your situational awareness practice.
	•	Fully native support for both iPhone and iPad — optimised for classroom and cockpit-style tablet use alike.
	•	Designed as a learning and rehearsal tool: practice flows, reinforce knowledge, and deepen your understanding of pressure, altitude and air-taxi operations.

⚠️ Important reminder: AéroCheck is not certified for in-flight operational use. Always rely on official checklists from your aircraft manufacturer and the latest documentation from your AFM/POH. Never substitute AéroCheck for procedural compliance. Use it as a supplementary study and training aid only.

Thank you for downloading and welcome to your first step in mastering the flight checklist workflow. Safe learning — and clear skies ahead!

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

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/1.0.0)

<br>

