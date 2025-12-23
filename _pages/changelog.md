---
layout: page
title: Releases
include_in_header: true
---

# Release History

All notable changes to AeroCheck are documented here. For full details, visit the [GitHub Releases page](https://github.com/fetzu/AeroCheck/releases).

<br>

### `Latest`
# **Version 2.6.0** - Cache-cache
*Released December 21, 2025*

## What's New

### Swiss ICAO & swisstopo Maps - Faster, Smarter, More Reliable
- **Cache-first tile loading** for ICAO charts: cached tiles now load instantly in online mode, with seamless network fallback.
- **Extended caching support** for the Segelflugkarte, with user control over caching:
  - ICAO only
  - ICAO + Segelflugkarte
- **Offline mode enhancements**:
  - Full offline support for ICAO **and** Segelflug layers
  - Smooth zoom transitions when both layers are cached
- **New Cache Info sheet** showing detailed cache status for each layer.
- Corrected branding: *"Swiss Topo" to **swisstopo***.
- Improved cache management UI and status indicators.

> Existing ICAO caches remain fully compatible - **no breaking changes**.

### Offline Downloads - Faster & More Informative
- **Faster tile downloads** thanks to optimized networking:
  - Increased concurrent connections (up to 6)
  - Larger batch sizes for improved parallelism
  - Tuned URLSession timeouts
- **Estimated Time Remaining (ETA)** now shown during offline chart downloads.

### Navigation View - Cleaner, More Aviation-Correct
- **Improved aircraft marker design**:
  - Smaller, cleaner icon aligned with Apple's HIG
  - Refined shadows, consistent aviation gold color
- **Correct heading rendering** so 0 deg = North, 90 deg = East
- **Better visibility on all map types** with high-contrast outline
- **Smoother updates** with in-place annotation updates

### Marketing Mode (Hidden)
A new **hidden Marketing Mode** for generating App Store screenshots and demos. Access via Developer Options (tap App Version 5 times).

### Flight Log Improvements
- **Year display** added below the month in the date indicator
- **Chronological sorting fixed** - most recent flights first
- Refined layout with better spacing and icon sizing

### iPhone UI Refinements
- **Speed Reference** redesigned using a two-column grid
- **Navigation View** metrics stacked into compact rows on iPhone

[Full Changelog](https://github.com/fetzu/AeroCheck/compare/2.5.0...2.6.0)

<br>

________

<br>

## **Version 2.5.0** - going with the wind!
*Released December 16, 2025*

### Clearer Speed Display
The speed indicator now correctly shows **ground speed** instead of the misleading "KIAS" label. Since GPS can only measure ground speed (not indicated airspeed), the display now shows:
- **"GND SPD"** label on iPad / **"GS"** on iPhone
- **"kt"** (knots) unit

### Experimental: Estimated Airspeed (Switzerland only)
A new optional feature that estimates your indicated airspeed by combining GPS ground speed with real-time wind data from MeteoSwiss weather stations.

**Important limitations:**
- Only works within Switzerland
- Requires constant cellular connection
- Can be highly inaccurate due to local wind variations
- **Always rely on your aircraft's onboard airspeed indicator**

[Full Changelog](https://github.com/fetzu/AeroCheck/compare/2.1.0...2.5.0)

<br>

## **Version 2.1.0** - (No) Signal in the Sky!
*Released December 15, 2025*

- **Offline ICAO chart caching** - Download Swiss ICAO charts for offline use
- **New app icon** with SF Symbol airplane
- **UTC time setting** - Option to always display times in UTC

[Full Changelog](https://github.com/fetzu/AeroCheck/compare/2.0.0...2.1.0)

<br>

## **Version 2.0.0** - Going somewhere?
*Released December 14, 2025*

Major release introducing **Navigation Mode** with an interactive map view featuring:
- Aircraft position tracking
- GPS flight visualization
- Multiple map layers: Apple Maps, ICAO charts, Swiss national maps, and aerial imagery

[Full Changelog](https://github.com/fetzu/AeroCheck/releases/tag/2.0.0)

<br>

________

<br>

### `Initial Release`
# **Version 1.0.0** - Take Off Check completed!
*Released December 7, 2025*

The first official release of AeroCheck - your digital co-pilot for flight checklists.

#### Core Features
- Complete walkthrough of the ATC "AeroCheck" task-flow (briefing -> taxi -> take-off -> en-route -> descent -> landing)
- Integrated checklists matching each phase of flight
- Live display of speed and altitude via built-in sensors
- Native support for both iPhone and iPad
- Designed as a learning and rehearsal tool

**Important:** AeroCheck is not certified for in-flight operational use. Always rely on official checklists from your aircraft manufacturer.

[Full Changelog](https://github.com/fetzu/AeroCheck/commits/1.0.0)

<br>
