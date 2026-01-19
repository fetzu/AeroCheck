#!/bin/bash
# Script to update remaining hardcoded strings in SettingsView.swift to use L10n keys

FILE="AeroCheck/Views/SettingsView.swift"

echo "Updating SettingsView.swift with L10n keys..."

# Aircraft Section
sed -i '' 's/"Premium Aircrafts"/L10n.Settings.premiumAircrafts/g' "$FILE"
sed -i '' 's/"Loading\.\.\." \/\/ aircraft/L10n.Settings.loading/g' "$FILE"
sed -i '' 's/"No premium aircraft"/L10n.Settings.noPremium/g' "$FILE"
sed -i '' 's/"Get latest aircraft data"/L10n.Settings.getLatest/g' "$FILE"
sed -i '' 's/"Aircraft"/L10n.Settings.aircraft/g' "$FILE"

# GPS Section
sed -i '' 's/"Recording Interval"/L10n.Settings.gpsInterval/g' "$FILE"
sed -i '' 's/"GPS Status"/L10n.GPS.status/g' "$FILE"
sed -i '' 's/"Request GPS Permission"/L10n.GPS.requestPermission/g' "$FILE"
sed -i '' 's/"GPS Tracking"/L10n.Settings.gps/g' "$FILE"
sed -i '' 's/"Lower intervals provide more detailed tracks but use more storage"/L10n.Settings.gpsFooter/g' "$FILE"

# Experimental
sed -i '' 's/"Show Estimated Airspeed"/L10n.Settings.showEstimatedAirspeed/g' "$FILE"
sed -i '' 's/"Experimental"/L10n.Settings.experimental/g' "$FILE"
sed -i '' 's/"BETA" \/\/ for experimental/L10n.Tag.beta/g' "$FILE"

# Flight Planning
sed -i '' 's/"Enable Flight Planning"/L10n.Settings.enableFlightPlanning/g' "$FILE"
sed -i '' 's/"Waypoint Proximity"/L10n.Settings.waypointProximity/g' "$FILE"
sed -i '' 's/"Terrain Altitude Unit"/L10n.Settings.terrainAltitudeUnit/g' "$FILE"
sed -i '' 's/"Flight Planning"/L10n.Settings.flightPlanning/g' "$FILE"

# Display
sed -i '' 's/"Keep Screen On"/L10n.Settings.keepScreenOn/g' "$FILE"
sed -i '' 's/"Always Use UTC Times"/L10n.Settings.alwaysUseUTC/g' "$FILE"
sed -i '' 's/"Display"/L10n.Settings.display/g' "$FILE"

# Navigation
sed -i '' 's/"Navigation"/L10n.Settings.navigation/g' "$FILE"

# iCloud
sed -i '' 's/"Last Sync"/L10n.Settings.lastSync/g' "$FILE"
sed -i '' 's/"Sync Now"/L10n.Settings.syncNow/g' "$FILE"
sed -i '' 's/"Syncing\.\.\." \/\/ icloud/L10n.Settings.syncing/g' "$FILE"

# Offline Maps
sed -i '' 's/"ICAO Chart"/L10n.Settings.icaoChart/g' "$FILE"
sed -i '' 's/"Segelflugkarte"/L10n.Settings.segelflugkarte/g' "$FILE"
sed -i '' 's/"Total Cache Size"/L10n.Settings.totalCacheSize/g' "$FILE"
sed -i '' 's/"Update\/Add Charts"/L10n.Settings.updateCharts/g' "$FILE"
sed -i '' 's/"Delete All Cached Charts"/L10n.Settings.deleteCache/g' "$FILE"
sed -i '' 's/"Download Charts"/L10n.Settings.downloadCharts/g' "$FILE"
sed -i '' 's/"Offline Maps"/L10n.Settings.offlineMaps/g' "$FILE"

# Checklist
sed -i '' 's/"Checklist"/L10n.Settings.checklist/g' "$FILE"

# About
sed -i '' 's/"App Version"/L10n.Settings.appVersion/g' "$FILE"
sed -i '' 's/"Website"/L10n.Settings.website/g' "$FILE"
sed -i '' 's/"Author"/L10n.Settings.author/g' "$FILE"
sed -i '' 's/"Open Source"/L10n.Settings.openSource/g' "$FILE"
sed -i '' 's/"About"/L10n.Settings.about/g' "$FILE"

# Available Checklists
sed -i '' 's/"No checklists cached"/L10n.Settings.noCached/g' "$FILE"

# Data
sed -i '' 's/"Recorded Flights"/L10n.Settings.recordedFlights/g' "$FILE"
sed -i '' 's/"Total GPS Points"/L10n.Settings.totalGPSPoints/g' "$FILE"
sed -i '' 's/"Data"/L10n.Settings.data/g' "$FILE"

# Developer
sed -i '' 's/"Marketing Mode"/L10n.Settings.marketingMode/g' "$FILE"
sed -i '' 's/"Force .Not Subscribed. State"/L10n.Settings.forceNotSubscribed/g' "$FILE"
sed -i '' 's/"Show All Transactions"/L10n.Settings.showAllTransactions/g' "$FILE"
sed -i '' 's/"Show Subscription Logs"/L10n.Settings.showSubscriptionLogs/g' "$FILE"
sed -i '' 's/"Reset Subscription State"/L10n.Settings.resetSubscription/g' "$FILE"
sed -i '' 's/"DEV"/L10n.Tag.dev/g' "$FILE"

echo "Done! Please review the changes and test the build."
