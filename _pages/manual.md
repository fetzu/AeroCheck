---
layout: page
title: User Manual
include_in_header: true
permalink: /manual/
---

# User Manual

Welcome to the AeroCheck user manual. This guide covers all the features of the app to help you get the most out of your flights.

**Table of Contents**
- [Getting Started](#getting-started)
- [Checklists](#checklists)
- [In-Flight Navigation](#in-flight-navigation)
- [Briefings](#briefings)
- [Flight Logging](#flight-logging)
- [Flight Planning (Beta)](#flight-planning-beta)
- [Circuit Mode](#circuit-mode)
- [Settings and Subscription](#settings-and-subscription)

---

## Getting Started

### First Launch

When you first open AeroCheck, the app will request **location permission**. This is required for GPS flight tracking, ground speed display, and the navigation map. Grant "While Using the App" or "Always" permission for full functionality, including background tracking during flights.

### Selecting an Aircraft

The home screen displays an **aircraft carousel**. Swipe left or right to browse available aircraft. The bundled aircraft (WT9 Dynamic / F-HVXA) is included free. Premium aircraft require an AeroCheck Pro subscription.

Each aircraft card shows the registration, type, and number of checklist items. Tap the **Settings** icon to manage aircraft, download additional checklists, or subscribe.

### Starting a Flight

Tap **START FLIGHT** to begin a standard flight. The app will guide you through all 16 flight phases, from Preflight to At the Hangar. For pattern training, tap **CIRCUITS** instead -- this activates Circuit Mode, which streamlines the checklist for repeated landings.

---

## Checklists

### The 16 Flight Phases

AeroCheck covers every phase of flight:

1. Preflight
2. Before Engine Start
3. Engine Start
4. After Engine Start
5. Taxi
6. Run Up
7. Before Departure
8. Line Up
9. Climb
10. Cruise
11. Descent
12. Approach
13. Landing
14. After Landing
15. Engine Shutdown
16. At the Hangar

Navigate between phases using the **phase selector** at the top of the screen. Completed phases are marked with a checkmark.

### Step-by-Step Mode

When enabled (default), the current checklist item is highlighted. Tap it to mark it as complete and advance to the next item. This helps ensure no items are skipped.

### Learning Mode

Learning mode hides items that should be memorized, allowing you to test your knowledge. Items configured as "memorizable" in the checklist will only appear when Learning Mode is turned off. Toggle this in **Settings > Checklist > Learning Mode**.

### Multi-Page Phases

Some phases span multiple pages. A page indicator at the bottom shows your position. Swipe or tap to navigate between pages within a phase.

### Checklist Language

If a checklist is available in multiple languages, you can choose your preferred language in **Settings > Checklist > Checklist Language**. Options include Auto (follows device language), English, and French.

---

## In-Flight Navigation

### Opening the Map

Tap the **NAV** button during a flight to open the full-screen navigation map. The map shows your current position with a heading indicator.

### Map Layers

AeroCheck offers several map layers:

- **Standard** -- Default Apple Maps view
- **Satellite** -- Satellite imagery
- **ICAO Chart 1:500,000** -- Swiss aeronautical chart from swisstopo
- **Landeskarten 1:100,000 / 1:50,000** -- Swiss national maps
- **Segelflugkarte 1:300,000** -- Swiss glider chart

The ICAO Chart and Segelflugkarte switch seamlessly based on zoom level. Swiss map layers are available within and near Switzerland.

### FREQ Panel

Tap the **FREQ** button to open the radio frequency panel. This displays:

- **Flight plan frequencies** (if a flight plan is active)
- **Nearby airport frequencies** -- Automatically detected airports within 15 NM, showing ATIS, TWR, GND, APP, and other published frequencies from the OurAirports database
- **Common Swiss frequencies** -- Emergency, information, and FIS frequencies
- **Nearby CTR frequencies** -- Control zone frequencies based on your position

### GPS Indicators

The navigation view displays real-time:
- **Ground speed** in knots
- **Altitude** in feet MSL
- **GPS signal quality** indicator

### Offline Maps

Swiss ICAO Chart and Segelflugkarte can be cached for offline use. Go to **Settings > Offline Maps** to download charts (~100-250 MB). When offline mode is enabled, maps are served from your local cache.

---

## Briefings

### Departure Briefing

Before departure, a dynamic briefing is displayed showing:
- **Airport** and **elevation** (automatically detected from your GPS position)
- **Runway** (detected or manually selected)
- **Departure procedure** -- First turn direction and level-off altitude (to be briefed verbally by the pilot)
- **Wind** conditions (when available from MeteoSwiss)
- **Airspeeds** -- Rotation (Vr), best angle (Vx), best rate (Vy), best glide (Vbg), and other speeds from the aircraft flight manual
- **Emergency procedures** -- Malfunction before rotation, engine failure after takeoff, minimum safe altitudes

### Approach Briefing

Before approach, a similar briefing covers:
- **Airport** and **elevation**
- **Runway**
- **Wind** conditions
- **Approach speeds** -- Initial approach, final approach, and stall speeds
- **Go-around procedure**

When wind data is unavailable, the briefing shows a reminder to check the windsock for calm, crosswind, headwind, or tailwind conditions.

---

## Flight Logging

### Automatic Timing

AeroCheck automatically records key timestamps during your flight:
- **Block off / Block on** times
- **Engine start / Engine shutdown** times
- **Takeoff / Landing** times (tap action buttons to record)

### Flight Events

The app automatically detects and logs:
- **Go-arounds** -- Detected when climbing above a threshold after an approach
- **Touch-and-goes** -- Brief ground contact followed by takeoff
- **Full-stop landings** -- Final landing at end of flight

### Engine Hours

If enabled in **Settings > Flight Logging**, the app prompts for tachometer or Hobbs meter readings at engine start and shutdown. Hours flown are calculated automatically.

### Viewing Flight History

Tap the **flight log** icon on the home screen to view past flights. Each flight entry shows the date, duration, aircraft, and distance.

Tap a flight to see its **detail view**, which includes:
- An interactive map with your flight track
- An altitude profile chart
- Route information (departure and arrival airports)
- Chronological timeline of all events
- Engine hours (if logged)
- Flight notes

### Exporting Flights

From the flight detail view, tap **Export** to save your flight as:
- **GPX** -- Standard GPS exchange format, compatible with most mapping tools
- **JSON** -- Detailed flight data including all events and metadata

You can also generate a **share card** -- a visual summary of your flight that can be shared to social media or messaging apps.

---

## Flight Planning (Beta)

> Flight planning is a beta feature. Enable it in **Settings > Flight Planning**.

### Creating a Flight Plan

Open the flight planning view to create a route. Add waypoints by:
- Searching for airports or waypoints by name or ICAO code
- Tapping on the map to place a waypoint
- Entering coordinates manually

### Route Table

The route table displays for each waypoint:
- Waypoint name and frequency
- Planned altitude
- Ground speed
- Estimated enroute time (EET)
- Estimated time of arrival (ETO)
- Magnetic course (MC)

### Terrain Profiles

For routes within Switzerland, AeroCheck displays a terrain profile using swisstopo elevation data. This visualization shows the ground elevation along your route relative to your planned altitude.

### In-Flight HUD

During a flight with an active plan, a heads-up display shows:
- Next waypoint name, heading, and distance
- Planned altitude
- Flight time and ETO
- Progress indicator
- A chronometer for timing legs

### Exporting

Flight plans can be exported as GPX files compatible with Dynon, Garmin, and other avionics systems.

---

## Circuit Mode

Circuit mode is designed for **pattern training** (touch-and-go practice). When activated:

- The checklist skips the **Cruise** and **Descent** phases
- After landing, the checklist returns directly to the **Before Departure** phase
- **Full-stop landings** are tracked automatically

Enable circuit mode when starting a flight by tapping **CIRCUITS** on the home screen, or toggle it in **Settings > Checklist > Circuit Mode**.

---

## Settings and Subscription

### Aircraft and Subscription

- **AeroCheck Pro** -- Subscribe to unlock premium aircraft checklists
- **Aircraft** -- Select your active aircraft from bundled and premium options
- **Aircraft Visibility** -- Show or hide aircraft by aeroclub

### Flight

- **Checklist** -- Step-by-step highlighting, learning mode, circuit mode, and language
- **Flight Logging** -- Enable engine hour (Hobbs meter) logging
- **GPS** -- Recording interval (1-30 seconds) and permission status
- **Display** -- Keep screen on during flight, use UTC time

### Navigation and Data

- **Navigation** -- Force ICAO chart layer
- **Flight Planning** (Beta) -- Enable route planning and terrain profiles
- **Estimated Airspeed** (Beta) -- GPS ground speed corrected with MeteoSwiss wind data (Switzerland only)
- **Airport Data** -- Download OurAirports database for worldwide airport frequencies
- **Offline Maps** -- Cache Swiss ICAO Chart and Segelflugkarte for offline use
- **iCloud Sync** -- Synchronize flight logs across devices

### About and Advanced

- **About** -- App version, website, author, and open-source information
- **Available Checklists** -- View all cached aircraft checklists and versions
- **Data** -- Flight and GPS statistics
- **Developer Options** -- Hidden debug tools (tap version number 5 times to unlock)
