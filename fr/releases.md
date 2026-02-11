---
layout: page
title: Releases
lang: fr
permalink: /fr/releases/
english_only: true
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

For older releases, please visit the [GitHub Releases page](https://github.com/fetzu/AeroCheck/releases).
