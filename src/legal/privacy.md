**Last updated**
December 2025


AéroCheck is an open-source flight checklist application designed for pilot training. We take your privacy seriously.


## 1.0 Data Collection

### 1.1 Location Data
AéroCheck uses your device's GPS to:
- Display your current position on the map
- Record your flight track for later review
- Calculate ground speed and estimated airspeed

**This data stays on your device.** We do not collect, transmit, or store your location data on any server.

### 1.2 Flight Logs
Flight logs (including GPS tracks, timing data, and phase completions) are stored locally on your device using iOS's standard data storage mechanisms.

### 1.3 No Analytics or Tracking
AéroCheck does not include any analytics SDKs, tracking pixels, or third-party data collection tools. We do not track how you use the app.


## 2.0 Third-Party Services

### 2.1 Map Tiles
When using map features, AéroCheck may request map tiles from:
- **Apple Maps** - Subject to [Apple's Privacy Policy](https://www.apple.com/legal/privacy/)
- **swisstopo** - Swiss Federal Office of Topography for ICAO charts and Swiss maps

These services may log standard request information (IP address, timestamp) according to their respective privacy policies.

### 2.2 MeteoSwiss (Optional)
If you enable the experimental "Estimated Airspeed" feature, the app fetches wind data from MeteoSwiss. This feature is:
- Disabled by default
- Only available in Switzerland
- Does not transmit any personal data


## 3.0 Data Storage

All app data is stored locally on your device:
- **Flight logs** - Stored in the app's sandboxed container
- **Settings** - Stored in UserDefaults
- **Cached map tiles** - Stored in the app's cache directory

You can delete all app data by uninstalling AéroCheck from your device.


## 4.0 Data Export

AéroCheck allows you to export your flight data in GPX, JSON, or ZIP formats. Once exported, you control where this data goes. We recommend being mindful when sharing flight logs, as they contain detailed location history.


## 5.0 Open Source

AéroCheck is open source software. You can review the complete source code on [GitHub](https://github.com/fetzu/AeroCheck) to verify our privacy practices.


## 6.0 Changes to This Policy

We may update this privacy policy from time to time. Changes will be posted on this page with an updated revision date.


## 7.0 Contact

If you have questions about this privacy policy, please open an issue on our [GitHub repository](https://github.com/fetzu/AeroCheck/issues).
