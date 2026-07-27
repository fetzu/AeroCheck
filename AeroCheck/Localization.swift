import Foundation

/// Get a localized string in a specific language
/// - Parameters:
///   - key: The localization key
///   - language: The target language code (e.g., "en", "fr")
///   - defaultValue: Fallback value if localization is not found
/// - Returns: The localized string in the specified language
func localizedString(key: String, language: String, defaultValue: String = "") -> String {
    guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
          let bundle = Bundle(path: path) else {
        return defaultValue.isEmpty ? key : defaultValue
    }
    return bundle.localizedString(forKey: key, value: defaultValue, table: nil)
}

/// Localized string keys for type-safe localization access
/// All UI strings should use these keys via String(localized:) or Text() with LocalizedStringKey
enum L10n {
    // MARK: - App
    enum App {
        static let tagline = String(localized: "app.tagline")
    }

    // MARK: - Data & Storage (v4.1.0 Data Freshness)
    // Literal-keyed strings: English renders immediately; FR translations are added in the
    // localization pass (xcstrings), like other newly-introduced UI strings.
    enum DataStorage {
        static let title = String(localized: "Data & Storage")
        static let subtitle = String(localized: "Currency & offline storage")
        static let aeronauticalSection = String(localized: "Aeronautical data")
        static let chartsSection = String(localized: "Offline charts")
        static let storageSection = String(localized: "Storage")
        static let statusFresh = String(localized: "Up to date")
        static let statusAging = String(localized: "Update recommended")
        static let statusStale = String(localized: "Out of date")
        static let statusMissing = String(localized: "Not downloaded")
        static func asOf(_ date: String) -> String { String(localized: "Data as of \(date)") }
        static func coverage(_ regions: String) -> String { String(localized: "Coverage: \(regions)") }
        static let coverageGlobal = String(localized: "Worldwide")
        static let refresh = String(localized: "Refresh")
        static let delete = String(localized: "Delete")
        static let updateAll = String(localized: "Update all on Wi-Fi")
        static let removeAll = String(localized: "Remove all downloads")
        static func totalStorage(_ size: String) -> String { String(localized: "Total storage: \(size)") }
        static let caveat = String(localized: "Community-sourced data — keep it current. This is not official aeronautical information; always verify currency before flight.")
        static let deleteConfirmTitle = String(localized: "Delete downloaded data?")
        static let deleteConfirmMessage = String(localized: "This removes the cached data from this device. You can download it again later.")
        static let removeAllConfirmTitle = String(localized: "Remove all downloads?")
        static let nudgeMessage = String(localized: "Some aeronautical data is out of date. Open Data & Storage to update.")
        static let homeLabel = String(localized: "Data")
        static let statusNoData = String(localized: "No data")
        // Per-dataset name + source/description — source named first (device-test feedback).
        static let airspaceName = String(localized: "Airspace")
        static let airspaceDetail = String(localized: "OpenAIP · controlled airspace, sectors & frequencies")
        static let airportsName = String(localized: "Airports")
        static let airportsDetail = String(localized: "OurAirports · global airfields · secondary / fallback source")
        static let swissChartName = String(localized: "Swiss ICAO chart")
        static let swissChartDetail = String(localized: "swisstopo · official VFR chart (imagery)")
        static let openAIPTilesName = String(localized: "OpenAIP map tiles")
        static let openAIPTilesDetail = String(localized: "OpenAIP · optional chart imagery — airspace data above is what powers warnings")
        static let openAIPAttribution = String(localized: "Airspace data from [OpenAIP.net](https://www.openaip.net) (© OpenAIP and contributors, CC BY-NC 4.0)")
        static let checklistsName = String(localized: "Checklists")
        static let checklistsSection = String(localized: "Checklists")
        static let checklistsDetail = String(localized: "Auto-updating · aircraft checklists from aerocheck.app")
        static let noChecklists = String(localized: "No checklists cached yet")
        static let syncChecklists = String(localized: "Check for checklist updates")
        static let simulateStaleData = String(localized: "Simulate stale data")
        static let rowActions = String(localized: "More options")
        static let manageRegions = String(localized: "Manage regions & downloads")
        static let manageRegionsDetail = String(localized: "Add or remove countries and continents in Navigation & Maps")
        // About → Data sources credits
        static let dataSourcesTitle = String(localized: "Data sources")
        static let sourceCharts = String(localized: "Aeronautical charts · © swisstopo / BAZL")
        static let sourceAirspace = String(localized: "Airspace · © OpenAIP and contributors, CC BY-NC 4.0")
        static let sourceAirports = String(localized: "Airport database · public domain")
        static let sourceWind = String(localized: "Wind data · © MeteoSwiss")
        static let sourceElevation = String(localized: "Terrain elevation · Open-Meteo (CC BY 4.0), © swisstopo")
        static let navaidsName = String(localized: "Navaids")
        static let navaidsDetail = String(localized: "OpenAIP · VOR / DME / NDB radio navigation aids")
        static let showNavaidsOnMap = String(localized: "Show navaids on map")
        static let obstaclesName = String(localized: "Obstacles")
        static let obstaclesDetail = String(localized: "OpenAIP · towers, masts and wind turbines")
        static let showObstaclesOnMap = String(localized: "Show obstacles on map")
        static let reportingPointsName = String(localized: "Reporting points")
        static let reportingPointsDetail = String(localized: "OpenAIP · VFR reporting points")
        static let showReportingPointsOnMap = String(localized: "Show reporting points on map")
        static let tripSection = String(localized: "Trip data")
        static let tripFooter = String(localized: "Your active flight plan crosses areas without downloaded data:")
        static let tripDownload = String(localized: "Download data for this trip")
        static let tripDownloading = String(localized: "Downloading…")
    }

    // MARK: - Buttons
    enum Button {
        static let startFlight = String(localized: "button.startFlight")
        static let circuits = String(localized: "button.circuits")
        static let next = String(localized: "button.next")
        static let prev = String(localized: "button.prev")
        static let endFlight = String(localized: "button.endFlight")
        static let end = String(localized: "button.end")
        static let done = String(localized: "button.done")
        static let close = String(localized: "button.close")
        static let cancel = String(localized: "button.cancel")
        static let delete = String(localized: "button.delete")
        static let nav = String(localized: "button.nav")
        static let speeds = String(localized: "button.speeds")
        static let flightLog = String(localized: "button.flightLog")
    }

    // MARK: - Home
    enum Home {
        static let flightInfo = String(localized: "home.flightInfo")
        static let lastFlight = String(localized: "home.lastFlight")
        static let flightPlan = String(localized: "home.flightPlan")
        static func version(_ v: String) -> String {
            String(format: String(localized: "home.version"), v)
        }
    }

    // MARK: - Aircraft
    enum Aircraft {
        /// Non-blocking notice when a checklist was served in a fallback language. (PR-41)
        static func checklistLanguageOnly(_ language: String) -> String {
            String(format: String(localized: "aircraft.checklistLanguageOnly"), language)
        }
    }

    // MARK: - Stats
    enum Stats {
        static let checks = String(localized: "stats.checks")
        static let items = String(localized: "stats.items")
    }

    // MARK: - GPS
    enum GPS {
        static let backgroundLimited = String(localized: "gps.backgroundLimited")
        static let ready = String(localized: "gps.ready")
        static let denied = String(localized: "gps.denied")
        static let restricted = String(localized: "gps.restricted")
        static let notSet = String(localized: "gps.notSet")
        static let status = String(localized: "gps.status")
        static let sourceCompanion = String(localized: "gps.source.companion")
        static let authorized = String(localized: "gps.authorized")
        static let notDetermined = String(localized: "gps.notDetermined")
        static let unknown = String(localized: "gps.unknown")
        static let requestPermission = String(localized: "gps.requestPermission")
        static let signal = String(localized: "gps.signal")
        static let signalGood = String(localized: "gps.signal.good")
        static let signalDegraded = String(localized: "gps.signal.degraded")
        static let signalLost = String(localized: "gps.signal.lost")
        static let signalInactive = String(localized: "gps.signal.inactive")
        /// Shown when authorization was revoked — distinct from an ordinary signal dropout. (RES-14)
        static let accessRevoked = String(localized: "gps.accessRevoked")
        /// Shown when "Precise Location" is off, which otherwise looks like a permanently weak signal. (RES-09)
        static let preciseOff = String(localized: "gps.preciseOff")
        static let points = String(localized: "gps.points")
        static let pointsRecorded = String(localized: "gps.pointsRecorded")

        // GPS Status Modal
        static let statusTitle = String(localized: "gps.status.title")
        static let currentStatus = String(localized: "gps.status.current")
        static let statusGoodDesc = String(localized: "gps.status.good.description")
        static let statusDegradedDesc = String(localized: "gps.status.degraded.description")
        static let statusLostDesc = String(localized: "gps.status.lost.description")
    }

    // MARK: - Flight
    enum Flight {
        static func phase(_ current: Int, _ total: Int) -> String {
            String(format: String(localized: "flight.phase"), current, total)
        }
        static let phases = String(localized: "flight.phases")
        static let times = String(localized: "flight.times")
        static let info = String(localized: "flight.info")
        static let forCircuits = String(localized: "flight.forCircuits")
    }

    // MARK: - Time
    enum Time {
        static let engineStart = String(localized: "time.engineStart")
        static let takeoff = String(localized: "time.takeoff")
        static let landing = String(localized: "time.landing")
        static let shutdown = String(localized: "time.shutdown")
    }

    // MARK: - Flight Info
    enum FlightInfo {
        static let title = String(localized: "flightInfo.title")
        static let gpsStatus = String(localized: "flightInfo.gpsStatus")
        static let signal = String(localized: "flightInfo.signal")
        static let pointsRecorded = String(localized: "flightInfo.pointsRecorded")
        static let flightTimes = String(localized: "flightInfo.flightTimes")
        static let flightPhases = String(localized: "flightInfo.flightPhases")
    }

    // MARK: - Alerts
    enum Alert {
        static let endFlightTitle = String(localized: "alert.endFlight.title")
        static let endFlightMessage = String(localized: "alert.endFlight.message")
        static let abandonFlightTitle = String(localized: "alert.abandonFlight.title")
        static let abandonFlightMessage = String(localized: "alert.abandonFlight.message")
        static let abandonFlightButton = String(localized: "alert.abandonFlight.button")
        static let deleteCacheTitle = String(localized: "alert.deleteCache.title")
        static let deleteCacheMessage = String(localized: "alert.deleteCache.message")
        static let deleteFlightTitle = String(localized: "alert.deleteFlight.title")
        static let deleteFlightMessage = String(localized: "alert.deleteFlight.message")
        static let checklistNotReadyTitle = String(localized: "alert.checklistNotReady.title")
        static let checklistNotReady = String(localized: "alert.checklistNotReady.message")
        static let cannotStartFlightTitle = String(localized: "alert.cannotStartFlight.title")
        static let locationRequired = String(localized: "alert.locationRequired.message")
        static let acquiringGPS = String(localized: "alert.acquiringGPS.message")
        static let flightSaveFailedTitle = String(localized: "alert.flightSaveFailed.title")
        static let flightSaveFailed = String(localized: "alert.flightSaveFailed.message")
        static let flightRestoredTitle = String(localized: "alert.flightRestored.title")
        static let flightRestored = String(localized: "alert.flightRestored.message")
    }

    // MARK: - Phase Titles
    enum Phase {
        static let preflight = String(localized: "phase.preflight")
        static let beforeEngineStart = String(localized: "phase.beforeEngineStart")
        static let engineStart = String(localized: "phase.engineStart")
        static let afterEngineStart = String(localized: "phase.afterEngineStart")
        static let taxi = String(localized: "phase.taxi")
        static let runup = String(localized: "phase.runup")
        static let beforeDeparture = String(localized: "phase.beforeDeparture")
        static let lineUp = String(localized: "phase.lineUp")
        static let climb = String(localized: "phase.climb")
        static let cruise = String(localized: "phase.cruise")
        static let descent = String(localized: "phase.descent")
        static let approach = String(localized: "phase.approach")
        static let landing = String(localized: "phase.landing")
        static let afterLanding = String(localized: "phase.afterLanding")
        static let shutdown = String(localized: "phase.shutdown")
        static let hangar = String(localized: "phase.hangar")

        // Short titles
        enum Short {
            static let preflight = String(localized: "phase.short.preflight")
            static let beforeEngineStart = String(localized: "phase.short.beforeEngineStart")
            static let engineStart = String(localized: "phase.short.engineStart")
            static let afterEngineStart = String(localized: "phase.short.afterEngineStart")
            static let taxi = String(localized: "phase.short.taxi")
            static let runup = String(localized: "phase.short.runup")
            static let beforeDeparture = String(localized: "phase.short.beforeDeparture")
            static let lineUp = String(localized: "phase.short.lineUp")
            static let climb = String(localized: "phase.short.climb")
            static let cruise = String(localized: "phase.short.cruise")
            static let descent = String(localized: "phase.short.descent")
            static let approach = String(localized: "phase.short.approach")
            static let landing = String(localized: "phase.short.landing")
            static let afterLanding = String(localized: "phase.short.afterLanding")
            static let shutdown = String(localized: "phase.short.shutdown")
            static let hangar = String(localized: "phase.short.hangar")
        }

        static func completed(_ phase: String) -> String {
            String(format: String(localized: "phase.completed"), phase)
        }
    }

    // MARK: - Briefing
    enum Briefing {
        static let departureTitle = String(localized: "briefing.departure.title")
        static let approachTitle = String(localized: "briefing.approach.title")
        static let departure = String(localized: "briefing.departure")
        static let approach = String(localized: "briefing.approach")
        static let airspeeds = String(localized: "briefing.airspeeds")
        static let airspeedsIAS = String(localized: "briefing.airspeeds.ias")
        static let emergencyBriefing = String(localized: "briefing.emergencyBriefing")
        static let missedApproach = String(localized: "briefing.missedApproach")
        static let alternate = String(localized: "briefing.alternate")
        static let close = String(localized: "briefing.close")
        static let airport = String(localized: "briefing.airport")
        static let elevation = String(localized: "briefing.elevation")
        static let wind = String(localized: "briefing.wind")
        static let runway = String(localized: "briefing.runway")
        static let notDetected = String(localized: "briefing.notDetected")
        static let notAvailable = String(localized: "briefing.notAvailable")
        static let goAroundProcedure = String(localized: "briefing.goAround.procedure")
        static let brsConsider = String(localized: "briefing.brs.consider")

        // Departure procedure
        static let departureProcedure = String(localized: "briefing.departureProcedure")
        static let reportingPoints = String(localized: "Reporting points")   // v4.1.0 (literal-keyed)
        static let compulsory = String(localized: "Compulsory")   // v4.1.0 (review #15)
        static let onRequest = String(localized: "On request")
        static let firstTurn = String(localized: "briefing.firstTurn")
        static let levelOff = String(localized: "briefing.levelOff")
        static let toBeBriefed = String(localized: "briefing.toBeBriefed")
        static let initialTrack = String(localized: "briefing.initialTrack")
        static let climbTo = String(localized: "briefing.climbTo")
        static let windCheckHint = String(localized: "briefing.windCheckHint")

        // Emergency items
        static let malfunctionBeforeRotation = String(localized: "briefing.emergency.malfunctionBeforeRotation")
        static let engineFailureAfterRotation = String(localized: "briefing.emergency.engineFailureAfterRotation")
        static let noReturnBelow = String(localized: "briefing.emergency.noReturnBelow")
        static func noReturnBelowWithMSL(_ msl: Int) -> String {
            String(format: String(localized: "briefing.emergency.noReturnBelowWithMSL"), msl)
        }
        static let noParachuteBelow = String(localized: "briefing.emergency.noParachuteBelow")
        static func noParachuteBelowWithMSL(_ msl: Int) -> String {
            String(format: String(localized: "briefing.emergency.noParachuteBelowWithMSL"), msl)
        }

        // Speed labels
        static let speedRotation = String(localized: "briefing.speed.rotation")
        static let speedBestAngle = String(localized: "briefing.speed.bestAngle")
        static let speedBestRate = String(localized: "briefing.speed.bestRate")
        static let speedBestGlide = String(localized: "briefing.speed.bestGlide")
        static let speedInitial = String(localized: "briefing.speed.initial")
        static let speedFinal = String(localized: "briefing.speed.final")
        static let speedStall = String(localized: "briefing.speed.stall")
        static let speedNA = String(localized: "briefing.speed.na")
        static func speedFormat(_ speed: Int) -> String {
            String(format: String(localized: "briefing.speed.format"), speed)
        }
    }

    // MARK: - Settings
    enum Settings {
        static let title = String(localized: "settings.title")
        static let done = String(localized: "settings.done")

        // Subscription
        static let subscription = String(localized: "settings.subscription")
        static let aeroCheckPro = String(localized: "settings.subscription.aeroCheckPro")
        static let subscriptionSubscribed = String(localized: "settings.subscription.subscribed")
        static let subscriptionGracePeriod = String(localized: "settings.subscription.gracePeriod")
        static let subscriptionUnlock = String(localized: "settings.subscription.unlock")
        static let subscriptionAccessAll = String(localized: "settings.subscription.accessAll")
        static let subscriptionLapsed = String(localized: "settings.subscription.lapsed")
        static let subscriptionUnlockText = String(localized: "settings.subscription.unlockText")
        static func gracePeriodEnds(_ date: String) -> String {
            String(format: String(localized: "settings.subscription.gracePeriodEnds"), date)
        }

        // Alert
        static let deleteCacheTitle = String(localized: "settings.deleteCache.title")
        static let deleteCacheMessage = String(localized: "settings.deleteCache.message")

        // Aircraft
        static let aircraft = String(localized: "settings.aircraft")
        static let premiumAircrafts = String(localized: "settings.aircraft.premiumAircrafts")
        static let loading = String(localized: "settings.aircraft.loading")
        static func available(_ accessible: Int, _ total: Int) -> String {
            String(format: String(localized: "settings.aircraft.available"), accessible, total)
        }
        static let noPremium = String(localized: "settings.aircraft.noPremiumAircraft")
        static let getLatest = String(localized: "settings.aircraft.getLatestData")
        static let aircraftFooter = String(localized: "settings.aircraft.selectAircraft")

        // Aircraft Visibility
        static let aircraftVisibility = String(localized: "settings.aircraftVisibility")
        static let noAircraftToFilter = String(localized: "settings.aircraftVisibility.noAircraft")
        static let showAll = String(localized: "settings.aircraftVisibility.showAll")
        static let hideAll = String(localized: "settings.aircraftVisibility.hideAll")
        static func aircraftVisible(_ visible: Int, _ total: Int) -> String {
            String(format: String(localized: "settings.aircraftVisibility.visible"), visible, total)
        }
        static let aircraftVisibilityFooter = String(localized: "settings.aircraftVisibility.footer")

        // GPS
        static let gps = String(localized: "settings.gps")
        static let gpsInterval = String(localized: "settings.gps.recordingInterval")
        static func seconds(_ n: Int) -> String {
            String(format: String(localized: "settings.gps.seconds"), n)
        }
        static let gpsFooter = String(localized: "settings.gps.lowerIntervals")
        static let gpsPriority = String(localized: "settings.gps.priority")
        static let gpsPrecision = String(localized: "settings.gps.precision")
        static let gpsBatterySaver = String(localized: "settings.gps.batterySaver")
        static let gpsPriorityFooter = String(localized: "settings.gps.priorityFooter")

        // Experimental
        static let experimental = String(localized: "settings.experimental")
        static let showEstimatedAirspeed = String(localized: "settings.experimental.showEstimatedAirspeed")
        static let stallAlertSound = String(localized: "settings.experimental.stallAlertSound")
        static let experimentalFooter = String(localized: "settings.experimental.whenEnabled")
        static let switzerlandOnly = String(localized: "settings.experimental.onlyInSwitzerland")

        // Flight Planning
        static let flightPlanning = String(localized: "settings.flightPlanning")
        static let enableFlightPlanning = String(localized: "settings.flightPlanning.enable")
        static let waypointProximity = String(localized: "settings.flightPlanning.waypointProximity")
        static let terrainAltitudeUnit = String(localized: "settings.flightPlanning.terrainAltitudeUnit")
        static let flightPlanningFooter = String(localized: "settings.flightPlanning.planFlightRoutes")
        static let waypointProximityFooter = String(localized: "settings.flightPlanning.waypointProximityDesc")
        static let terrainUnitFooter = String(localized: "settings.flightPlanning.terrainUnitDesc")

        // Display
        static let display = String(localized: "settings.display")
        static let keepScreenOn = String(localized: "settings.display.keepScreenOn")
        static let alwaysUseUTC = String(localized: "settings.display.alwaysUseUTC")
        static let keepScreenOnFooter = String(localized: "settings.display.keepScreenOnDesc")
        static let alwaysUseUTCFooter = String(localized: "settings.display.alwaysUseUTCDesc")
        // Cockpit theme (v4 UI/UX Revamp — replaces the night-mode picker; sunlight now selectable)
        static let theme = String(localized: "settings.display.theme")
        static let themeFooter = String(localized: "settings.display.themeDesc")
        static let themeAuto = String(localized: "settings.display.theme.auto")
        static let themeDay = String(localized: "settings.display.theme.day")
        static let themeSunlight = String(localized: "settings.display.theme.sunlight")
        static let themeNight = String(localized: "settings.display.theme.night")
        // Replay onboarding (v4 UI/UX Revamp)
        static let replayIntro = String(localized: "settings.about.replayIntro")
        static let replayIntroFooter = String(localized: "settings.about.replayIntroDesc")

        // Navigation
        static let navigation = String(localized: "settings.navigation")
        static let forceICAO = String(localized: "settings.navigation.forceICAO")
        static let forceICAOFooter = String(localized: "settings.navigation.forceICAODesc")

        // Airport Data
        static let airportData = String(localized: "settings.airportData")
        static let downloadAirportData = String(localized: "settings.airportData.download")
        static let updateAirportData = String(localized: "settings.airportData.update")
        static let deleteAirportData = String(localized: "settings.airportData.delete")
        static let downloadingAirports = String(localized: "settings.airportData.downloading")
        static let airportUpdateAvailable = String(localized: "settings.airportData.updateAvailable")
        static func airportsLoaded(_ count: Int) -> String {
            String(format: String(localized: "settings.airportData.loaded"), count)
        }
        static func lastUpdatedDate(_ date: String) -> String {
            String(format: String(localized: "settings.airportData.lastUpdated"), date)
        }
        static let airportDataFooter = String(localized: "settings.airportData.footer")
        static let showAirportsOnMap = String(localized: "settings.airportData.showOnMap")

        // iCloud
        static let icloud = String(localized: "settings.icloud")
        static let syncToICloud = String(localized: "settings.icloud.syncToICloud")
        static let lastSync = String(localized: "settings.icloud.lastSync")
        static let syncNow = String(localized: "settings.icloud.syncNow")
        static let syncing = String(localized: "settings.icloud.syncing")
        static let icloudFooter = String(localized: "settings.icloud.whenEnabledDesc")
        static let flightLogsFooter = String(localized: "settings.icloud.flightLogsStored")

        // Offline Maps
        static let offlineMaps = String(localized: "settings.offlineMaps")
        static let offlineMode = String(localized: "settings.offlineMaps.offlineMode")
        static let icaoChart = String(localized: "settings.offlineMaps.icaoChart")
        static let segelflugkarte = String(localized: "settings.offlineMaps.segelflugkarte")
        static let totalCacheSize = String(localized: "settings.offlineMaps.totalCacheSize")
        static let updateCharts = String(localized: "settings.offlineMaps.updateAddCharts")
        static let deleteCache = String(localized: "settings.offlineMaps.deleteAllCached")
        static let downloadCharts = String(localized: "settings.offlineMaps.downloadCharts")
        static let offlineActive = String(localized: "settings.offlineMaps.offlineActive")
        static let onlyICAO = String(localized: "settings.offlineMaps.onlyICAO")
        static let chartsCached = String(localized: "settings.offlineMaps.chartsCached")
        static let downloadDesc = String(localized: "settings.offlineMaps.downloadDesc")

        // OpenAIP
        static let openAIPAirspace = String(localized: "settings.openAIP.airspace")
        static let airspaceOverlay = String(localized: "settings.openAIP.airspaceOverlay")
        static let airspaceStreaming = String(localized: "settings.openAIP.airspaceStreaming")
        static let downloadingAirspaceData = String(localized: "settings.openAIP.downloadingAirspace")
        static func airspacesLoaded(_ count: Int) -> String {
            String(format: String(localized: "settings.openAIP.airspacesLoaded"), count)
        }
        static func updatedDate(_ date: String) -> String {
            String(format: String(localized: "settings.openAIP.updated"), date)
        }
        static let tileCache = String(localized: "settings.openAIP.tileCache")
        static let updateData = String(localized: "settings.openAIP.updateData")
        static let downloadData = String(localized: "settings.openAIP.downloadData")
        static let airspaceNoDataHint = String(localized: "settings.openAIP.noDataHint")
        static let deleteOpenAIPData = String(localized: "settings.openAIP.deleteData")
        static let deleteOpenAIPTitle = String(localized: "settings.openAIP.deleteTitle")
        static let deleteOpenAIPMessage = String(localized: "settings.openAIP.deleteMessage")
        static let openAIPFooter = String(localized: "settings.openAIP.footer")
        static let openAIPDataTitle = String(localized: "settings.openAIP.dataTitle")
        static let selectCountries = String(localized: "settings.openAIP.selectCountries")
        static func estimatedTileCache(_ size: String) -> String {
            String(format: String(localized: "settings.openAIP.estimatedTileCache"), size)
        }
        static func estimatedDataSize(_ size: String) -> String {
            String(format: String(localized: "settings.openAIP.estimatedDataSize"), size)
        }
        static let downloadTilesConfirmTitle = String(localized: "settings.openAIP.downloadTilesConfirmTitle")
        static func downloadTilesConfirmMessage(_ data: String, _ tiles: String) -> String {
            String(format: String(localized: "settings.openAIP.downloadTilesConfirmMessage"), data, tiles)
        }
        static let downloadDataOnly = String(localized: "settings.openAIP.downloadDataOnly")
        static let downloadTilesAnyway = String(localized: "settings.openAIP.downloadTilesAnyway")
        static func tileCountLabel(_ count: Int) -> String {
            String(format: String(localized: "settings.openAIP.tileCount"), count)
        }
        static let downloadingTiles = String(localized: "settings.openAIP.downloadingTiles")
        static let download = String(localized: "settings.openAIP.download")
        static let downloadAll = String(localized: "settings.openAIP.downloadAll")
        static let downloadAirspaceOnly = String(localized: "settings.openAIP.downloadAirspaceOnly")
        static let downloadWithTiles = String(localized: "Download data + map tiles")   // v4.1.0 (literal-keyed; FR in pass)
        static let openAIPDownloadHint = String(localized: "Data (airspace, navaids, obstacles, reporting points, airports) is small. Map tiles add raster chart imagery and are much larger.")
        static let openAIPSelectionChanged = String(localized: "settings.openAIP.selectionChanged")
        static func openAIPCountriesSelected(_ count: Int) -> String {
            String(format: String(localized: "settings.openAIP.countriesSelected"), count)
        }
        static let openAIPClearSelection = String(localized: "settings.openAIP.clearSelection")
        static func openAIPContinentCountryCount(_ count: Int) -> String {
            String(format: String(localized: "settings.openAIP.continentCountryCount"), count)
        }
        static let openAIPDeselectAll = String(localized: "settings.openAIP.deselectAll")
        static func openAIPSelectAll(_ continent: String) -> String {
            String(format: String(localized: "settings.openAIP.selectAll"), continent)
        }

        // Checklist
        static let checklist = String(localized: "settings.checklist")
        static let stepByStep = String(localized: "settings.checklist.stepByStep")
        static let learningMode = String(localized: "settings.checklist.learningMode")
        static let circuitMode = String(localized: "settings.checklist.circuitMode")
        static let stepByStepFooter = String(localized: "settings.checklist.stepByStepFooter")
        static let learningModeFooter = String(localized: "settings.checklist.learningModeFooter")
        static let circuitModeFooter = String(localized: "settings.checklist.circuitModeFooter")

        // Flight Logging
        static let flightLogging = String(localized: "settings.flightLogging")
        static let logEngineHours = String(localized: "settings.flightLogging.logEngineHours")
        static let logEngineHoursFooter = String(localized: "settings.flightLogging.logEngineHoursFooter")

        // Checklist Language
        static let checklistLanguage = String(localized: "settings.checklistLanguage")
        static let checklistLanguageFooter = String(localized: "settings.checklistLanguage.footer")
        static let checklistLanguageAuto = String(localized: "settings.checklistLanguage.auto")

        // About
        static let about = String(localized: "settings.about")
        static let appVersion = String(localized: "settings.about.appVersion")
        static let website = String(localized: "settings.about.website")
        static let author = String(localized: "settings.about.author")
        static let openSource = String(localized: "settings.about.openSource")
        static let openSourceDescription = String(localized: "settings.about.openSourceDesc")
        static let mitLicense = String(localized: "settings.about.mitLicense")

        // Available Checklists
        static let availableChecklists = String(localized: "settings.availableChecklists")
        static let noCached = String(localized: "settings.availableChecklists.noCached")
        static func version(_ v: String) -> String {
            String(format: String(localized: "settings.availableChecklists.version"), v)
        }
        static let availableChecklistsFooter = String(localized: "settings.availableChecklists.cachedDesc")

        // Data
        static let data = String(localized: "settings.data")
        static let recordedFlights = String(localized: "settings.data.recordedFlights")
        static let totalGPSPoints = String(localized: "settings.data.totalGPSPoints")

        // Developer Options
        static let marketingMode = String(localized: "settings.developer.marketingMode")
        static let simulateLSZS = String(localized: "Simulate position: LSZS (Samedan)")   // v4.1.0 dev (literal-keyed)
        static let forceNotSubscribed = String(localized: "settings.developer.forceNotSubscribed")
        static let showAllTransactions = String(localized: "settings.developer.showAllTransactions")
        static let showSubscriptionLogs = String(localized: "settings.developer.showSubscriptionLogs")
        static let resetSubscription = String(localized: "settings.developer.resetSubscription")
        static let marketingModeDesc = String(localized: "settings.developer.marketingModeDesc")
        static let forceNotSubscribedDesc = String(localized: "settings.developer.forceNotSubscribedDesc")
        static let showAllTransactionsDesc = String(localized: "settings.developer.showAllTransactionsDesc")
        static let showSubscriptionLogsDesc = String(localized: "settings.developer.showSubscriptionLogsDesc")
        static let resetSubscriptionDesc = String(localized: "settings.developer.resetSubscriptionDesc")
        static let resetOnboarding = String(localized: "settings.developer.resetOnboarding")
        static let resetOnboardingDesc = String(localized: "settings.developer.resetOnboardingDesc")

        // Settings Hub - Navigation titles and subtitles
        static let aircraftAndSubscription = String(localized: "settings.hub.aircraftAndSubscription")
        static let aircraftAndSubscriptionSubtitle = String(localized: "settings.hub.aircraftAndSubscriptionSubtitle")
        static let checklistAndFlight = String(localized: "settings.hub.checklistAndFlight")
        static let checklistAndFlightSubtitle = String(localized: "settings.hub.checklistAndFlightSubtitle")
        static let navigationAndMaps = String(localized: "settings.hub.navigationAndMaps")
        static let navigationAndMapsSubtitle = String(localized: "settings.hub.navigationAndMapsSubtitle")
        static let flightPlanningSubtitle = String(localized: "settings.hub.flightPlanningSubtitle")
        static let syncAndData = String(localized: "iCloud & Log")
        static let syncAndDataSubtitle = String(localized: "iCloud sync, GPS recording & flight log")
        static let companionMode = String(localized: "settings.hub.companionMode")
        static let companionModeSubtitle = String(localized: "settings.hub.companionModeSubtitle")
        static let aboutSubtitle = String(localized: "settings.hub.aboutSubtitle")
    }

    // MARK: - Onboarding
    enum Onboarding {
        static let welcomeTitle = String(localized: "onboarding.welcome.title")
        static let welcomeSubtitle = String(localized: "onboarding.welcome.subtitle")
        static let checklistsTitle = String(localized: "onboarding.checklists.title")
        static let checklistsBody = String(localized: "onboarding.checklists.body")
        static let navigationTitle = String(localized: "onboarding.navigation.title")
        static let navigationBody = String(localized: "onboarding.navigation.body")
        static let downloadAirports = String(localized: "onboarding.navigation.downloadAirports")
        static let downloadCharts = String(localized: "onboarding.navigation.downloadCharts")
        static let downloading = String(localized: "onboarding.navigation.downloading")
        static let downloaded = String(localized: "onboarding.navigation.downloaded")
        static let briefingsTitle = String(localized: "onboarding.briefings.title")
        static let briefingsBody = String(localized: "onboarding.briefings.body")
        static let readyTitle = String(localized: "onboarding.ready.title")
        static let readyBody = String(localized: "onboarding.ready.body")
        static let readyButton = String(localized: "onboarding.ready.button")
        static let skip = String(localized: "onboarding.skip")
        static let getStarted = String(localized: "onboarding.getStarted")
        static let next = String(localized: "onboarding.next")
    }

    // MARK: - Sheets
    enum Sheet {
        static let speedReference = String(localized: "sheet.speedReference")
        static let selectPhase = String(localized: "sheet.selectPhase")
        static func page(_ n: Int) -> String {
            String(format: String(localized: "sheet.page"), n)
        }
    }

    // MARK: - Languages
    enum Language {
        static let en = String(localized: "language.en")
        static let fr = String(localized: "language.fr")
        static let de = String(localized: "language.de")
        static let it = String(localized: "language.it")
    }

    // MARK: - Speed
    enum Speed {
        static let gs = String(localized: "speed.gs")
        static let ias = String(localized: "speed.ias")
        static let tgt = String(localized: "speed.tgt")
        static let msl = String(localized: "speed.msl")
    }

    // MARK: - Units
    enum Unit {
        static let kt = String(localized: "unit.kt")
        static let ft = String(localized: "unit.ft")
        static let m = String(localized: "unit.m")
    }

    // MARK: - Flight Log
    enum FlightLog {
        static let title = String(localized: "flightLog.title")
        static let close = String(localized: "flightLog.close")
        static let exportAllTitle = String(localized: "flightLog.exportAll.title")
        static let exportAllGPX = String(localized: "flightLog.exportAll.gpx")
        static let exportAllJSON = String(localized: "flightLog.exportAll.json")
        static func exportAllMessage(_ count: Int) -> String {
            String(format: String(localized: "flightLog.exportAll.message"), count)
        }
        static let preparingExport = String(localized: "flightLog.preparingExport")
        static let importErrorTitle = String(localized: "flightLog.importError.title")
        static let importErrorOK = String(localized: "flightLog.importError.ok")
        static let importErrorUnknown = String(localized: "flightLog.importError.unknown")
        static let importErrorNoAccess = String(localized: "flightLog.importError.noAccess")
        static let importErrorParse = String(localized: "flightLog.importError.parse")
        static let importErrorZipNoFiles = String(localized: "flightLog.importError.zipNoFiles")
        static func importErrorZipPartial(_ success: Int, _ failed: Int) -> String {
            String(format: String(localized: "flightLog.importError.zipPartial"), success, failed)
        }
        static func importErrorZipExtract(_ error: String) -> String {
            String(format: String(localized: "flightLog.importError.zipExtract"), error)
        }
        // Decompression-budget refusals (SA-24)
        static let importErrorEntryTooLarge = String(localized: "flightLog.importError.entryTooLarge")
        static let importErrorArchiveTooLarge = String(localized: "flightLog.importError.archiveTooLarge")
        static let importErrorTooManyEntries = String(localized: "flightLog.importError.tooManyEntries")
        static let importErrorSizeMismatch = String(localized: "flightLog.importError.sizeMismatch")
        static let loading = String(localized: "flightLog.loading")
        static let noFlightsTitle = String(localized: "flightLog.noFlights.title")
        static let noFlightsMessage = String(localized: "flightLog.noFlights.message")
        static let importFlight = String(localized: "flightLog.importFlight")
        static let pts = String(localized: "flightLog.pts")
    }

    // MARK: - Premium
    enum Premium {
        static let title = String(localized: "premium.title")
        static let loadingAircraft = String(localized: "premium.loadingAircraft")
        static let noAircraftAvailable = String(localized: "premium.noAircraftAvailable")
        static let checkBackLater = String(localized: "premium.checkBackLater")
        static let requiresAeroCheckPro = String(localized: "premium.requiresAeroCheckPro")
    }

    // MARK: - Subscription View
    enum Subscription {
        static let unlockPremiumAircraft = String(localized: "subscription.unlockPremiumAircraft")
        static let accessDescription = String(localized: "subscription.accessDescription")
        static let benefits = String(localized: "subscription.benefits")
        static let benefitAllChecklists = String(localized: "subscription.benefit.allChecklists")
        static let benefitAutoUpdates = String(localized: "subscription.benefit.autoUpdates")
        static let benefitOfflineAccess = String(localized: "subscription.benefit.offlineAccess")
        static let benefitSupportDev = String(localized: "subscription.benefit.supportDev")
        static let currentStatus = String(localized: "subscription.currentStatus")
        static let choosePlan = String(localized: "subscription.choosePlan")
        static let unableToLoad = String(localized: "subscription.unableToLoad")
        static let retry = String(localized: "subscription.retry")
        static let restorePurchases = String(localized: "subscription.restorePurchases")
        static let termsDescription = String(localized: "subscription.termsDescription")
        static let termsOfService = String(localized: "subscription.termsOfService")
        static let privacyPolicy = String(localized: "subscription.privacyPolicy")
        static let bestValue = String(localized: "subscription.bestValue")
        static let error = String(localized: "subscription.error")
        static let ok = String(localized: "subscription.ok")
        // Premium revamp: contextual header, free trial, lifetime.
        static func unlockAircraft(_ name: String) -> String {
            String(format: String(localized: "subscription.unlockAircraft"), name)
        }
        static func freeTrialDays(_ days: Int) -> String {
            String(format: String(localized: "subscription.freeTrialDayFormat"), days)
        }
        static let freeTrialNote = String(localized: "subscription.freeTrialNote")
        static func freeTrialNoteDays(_ days: Int) -> String {
            String(format: String(localized: "subscription.freeTrialNoteDays"), days)
        }
        static let lifetimeTagline = String(localized: "subscription.lifetimeTagline")
        static let oneTime = String(localized: "subscription.oneTime")
    }

    // MARK: - Warnings
    enum Warning {
        static let betaFeature = String(localized: "warning.betaFeature")
        static let experimentalFeature = String(localized: "warning.experimentalFeature")
        static let iUnderstandEnable = String(localized: "warning.iUnderstandEnable")
        static let cancel = String(localized: "warning.cancel")

        // Flight Planning
        static let flightPlanningBetaDesc = String(localized: "warning.flightPlanning.betaDesc")
        static let flightPlanningPlanRoutes = String(localized: "warning.flightPlanning.planRoutes")
        static let flightPlanningAutoAdvance = String(localized: "warning.flightPlanning.autoAdvance")
        static let flightPlanningTerrainViz = String(localized: "warning.flightPlanning.terrainViz")

        // Online Airspace Streaming
        static let onlineAirspaceTitle = String(localized: "warning.onlineAirspace.title")
        static let onlineAirspaceRequiresInternet = String(localized: "warning.onlineAirspace.requiresInternet")
        static let onlineAirspaceFetches = String(localized: "warning.onlineAirspace.fetches")
        static let onlineAirspaceDownloadRecommended = String(localized: "warning.onlineAirspace.downloadRecommended")

        // Estimated Airspeed
        static let estimatedAirspeedCalculated = String(localized: "warning.estimatedAirspeed.calculated")
        static let estimatedAirspeedInaccurate = String(localized: "warning.estimatedAirspeed.inaccurate")
        static let estimatedAirspeedAlwaysRelyOnboard = String(localized: "warning.estimatedAirspeed.alwaysRelyOnboard")
        static let estimatedAirspeedRequiresCellular = String(localized: "warning.estimatedAirspeed.requiresCellular")
    }

    // MARK: - Download
    enum Download {
        static let title = String(localized: "download.title")
        static let description = String(localized: "download.description")
        static let selectCharts = String(localized: "download.selectCharts")
        static let icaoOnly = String(localized: "download.icaoOnly")
        static let icaoAndSegelflug = String(localized: "download.icaoAndSegelflug")
        static let cached = String(localized: "download.cached")
        static let downloadingTiles = String(localized: "download.downloadingTiles")
        static let throttled = String(localized: "download.throttled")
        static func downloadingLayer(_ name: String) -> String {
            String(format: String(localized: "download.downloadingLayer"), name)
        }
        static func estimatedTimeRemaining(_ time: String) -> String {
            String(format: String(localized: "download.estimatedTimeRemaining"), time)
        }
        static func total(_ size: String) -> String {
            String(format: String(localized: "download.total"), size)
        }
        static let done = String(localized: "download.done")
        static let cancel = String(localized: "download.cancel")
        static let redownload = String(localized: "download.redownload")
        static let downloadSegelflug = String(localized: "download.downloadSegelflug")
    }

    // MARK: - Tags
    enum Tag {
        static let beta = String(localized: "beta")
        static let dev = String(localized: "dev")
    }

    // MARK: - Checklist Actions
    enum ChecklistAction {
        static let engineStart = String(localized: "checklist.engineStart")
        static let started = String(localized: "checklist.started")
        static let readyForLineUp = String(localized: "checklist.readyForLineUp")
        static let lineUp = String(localized: "checklist.lineUp")
        static let engineShutdown = String(localized: "checklist.engineShutdown")
        static let shutdown = String(localized: "checklist.shutdown")
        static let goAround = String(localized: "checklist.goAround")
        static let goArounds = String(localized: "checklist.goArounds")
        static let touchAndGo = String(localized: "checklist.touchAndGo")
        static let touchAndGoes = String(localized: "checklist.touchAndGoes")
        static let landed = String(localized: "checklist.landed")
        static let landing = String(localized: "checklist.landing")

        /// Get button title in a specific language
        static func engineStart(language: String) -> String {
            localizedString(key: "checklist.engineStart", language: language, defaultValue: "ENGINE START")
        }

        static func started(language: String) -> String {
            localizedString(key: "checklist.started", language: language, defaultValue: "Started")
        }

        static func readyForLineUp(language: String) -> String {
            localizedString(key: "checklist.readyForLineUp", language: language, defaultValue: "READY FOR LINE UP")
        }

        static func lineUp(language: String) -> String {
            localizedString(key: "checklist.lineUp", language: language, defaultValue: "Line Up")
        }

        static func engineShutdown(language: String) -> String {
            localizedString(key: "checklist.engineShutdown", language: language, defaultValue: "ENGINE SHUTDOWN")
        }

        static func shutdown(language: String) -> String {
            localizedString(key: "checklist.shutdown", language: language, defaultValue: "Shutdown")
        }

        static func goAround(language: String) -> String {
            localizedString(key: "checklist.goAround", language: language, defaultValue: "GO AROUND")
        }

        static func goArounds(language: String) -> String {
            localizedString(key: "checklist.goArounds", language: language, defaultValue: "Go Arounds")
        }

        static func touchAndGo(language: String) -> String {
            localizedString(key: "checklist.touchAndGo", language: language, defaultValue: "TOUCH-AND-GO")
        }

        static func touchAndGoes(language: String) -> String {
            localizedString(key: "checklist.touchAndGoes", language: language, defaultValue: "Touch-and-goes")
        }

        static func landed(language: String) -> String {
            localizedString(key: "checklist.landed", language: language, defaultValue: "LANDED")
        }

        static func landing(language: String) -> String {
            localizedString(key: "checklist.landing", language: language, defaultValue: "Landing")
        }

        // Hidden Items
        static let hiddenItemsTitle = String(localized: "checklist.hiddenItems.title")
        static func hiddenItemsCount(_ count: Int, _ plural: String) -> String {
            String(format: String(localized: "checklist.hiddenItems.count"), count, plural)
        }
        static let holdToUpdate = String(localized: "checklist.hiddenItems.holdToUpdate")
        static func updateConfirm(_ label: String) -> String {
            String(format: String(localized: "checklist.hiddenItems.updateConfirm"), label)
        }

        // Other
        static func page(_ n: Int) -> String {
            String(format: String(localized: "checklist.page"), n)
        }
        static let tapToAdvance = String(localized: "checklist.tapToAdvance")
        static let holdToConfirm = String(localized: "checklist.holdToConfirm")
        static let airspeedsAFM = String(localized: "checklist.airspeeds.afm")
        static let maxCrosswind = String(localized: "checklist.maxCrosswind")
        static func crosswindFormat(takeoff: String, landing: String) -> String {
            String(format: String(localized: "checklist.crosswindFormat"), takeoff, landing)
        }
        static let updateTimeTitle = String(localized: "checklist.updateTime.title")
        static let update = String(localized: "checklist.update")
    }

    // MARK: - Flight Detail
    enum FlightDetail {
        // Export
        static let exportFormatTitle = String(localized: "flightDetail.exportFormat.title")
        static let exportFormatGPX = String(localized: "flightDetail.exportFormat.gpx")
        static let exportFormatJSON = String(localized: "flightDetail.exportFormat.json")
        static let exportFormatMessage = String(localized: "flightDetail.exportFormat.message")
        static let exportFailedTitle = String(localized: "flightDetail.exportFailed.title")
        static let exportFailedMessage = String(localized: "flightDetail.exportFailed.message")

        // Delete
        static let deleteTitle = String(localized: "flightDetail.delete.title")
        static let deleteMessage = String(localized: "flightDetail.delete.message")

        // Sections
        static let flightTrack = String(localized: "flightDetail.flightTrack")
        static let noGPSData = String(localized: "flightDetail.noGPSData")
        static let noAltitudeData = String(localized: "flightDetail.noAltitudeData")
        static let altitudeFtMSL = String(localized: "flightDetail.altitudeFtMSL")

        // Times
        static let sessionStart = String(localized: "flightDetail.sessionStart")
        static let engineStart = String(localized: "flightDetail.engineStart")
        static let takeoff = String(localized: "flightDetail.takeoff")
        static let landing = String(localized: "flightDetail.landing")
        static let engineShutdown = String(localized: "flightDetail.engineShutdown")
        static let sessionEnd = String(localized: "flightDetail.sessionEnd")

        // Engine Hours
        static let engineHours = String(localized: "flightDetail.engineHours")
        static let hoursBefore = String(localized: "flightDetail.hoursBefore")
        static let hoursAfter = String(localized: "flightDetail.hoursAfter")
        static let hoursFlown = String(localized: "flightDetail.hoursFlown")

        // Block Times
        static let blockOff = String(localized: "flightDetail.blockOff")
        static let blockOn = String(localized: "flightDetail.blockOn")

        // Name/Notes
        static let flightName = String(localized: "flightDetail.flightName")
        static let namePlaceholder = String(localized: "flightDetail.namePlaceholder")
        static let notes = String(localized: "flightDetail.notes")

        // Actions
        static let export = String(localized: "flightDetail.export")
    }

    // MARK: - Event Confirmation
    enum EventConfirmation {
        static let dismiss = String(localized: "eventConfirmation.dismiss")
        static let confirm = String(localized: "eventConfirmation.confirm")
        static func autoConfirm(_ seconds: Int) -> String {
            String(format: String(localized: "eventConfirmation.autoConfirm"), seconds)
        }
        static func autoDismiss(_ seconds: Int) -> String {
            String(format: String(localized: "eventConfirmation.autoDismiss"), seconds)
        }
    }

    // MARK: - Hour Meter
    enum HourMeter {
        static let beforeStartTitle = String(localized: "hourMeter.beforeStart.title")
        static let afterStopTitle = String(localized: "hourMeter.afterStop.title")
        static let beforeStartSubtitle = String(localized: "hourMeter.beforeStart.subtitle")
        static let afterStopSubtitle = String(localized: "hourMeter.afterStop.subtitle")
        static let hours = String(localized: "hourMeter.hours")
        static let formatHint = String(localized: "hourMeter.formatHint")
        static let clear = String(localized: "hourMeter.clear")
        static let skip = String(localized: "hourMeter.skip")
        static let save = String(localized: "hourMeter.save")
        static let invalidFormatTitle = String(localized: "hourMeter.invalidFormat.title")
        static let invalidFormatMessage = String(localized: "hourMeter.invalidFormat.message")
        static let endBeforeStartTitle = String(localized: "hourMeter.endBeforeStart.title")
        static let endBeforeStartMessage = String(localized: "hourMeter.endBeforeStart.message")
    }

    // MARK: - Content View
    enum ContentViewStrings {
        static let rotateDevice = String(localized: "contentView.rotateDevice")
        static let portraitMode = String(localized: "contentView.portraitMode")
    }

    // MARK: - Map Layer Selector
    enum MapLayer {
        static let title = String(localized: "mapLayer.title")
    }

    // MARK: - Flight Plan Overlay
    enum FlightPlan {
        static let fltTime = String(localized: "flightPlan.overlay.fltTime")
    }

    // MARK: - Navigation / Flight Plans
    enum ImportLimits {
        /// Shown when a picked import file exceeds the size budget. (SEC-C31)
        static let tooLarge = String(localized: "import.errorTooLarge")
    }

    enum Export {
        /// Shown in the XLSX/PDF nav log when the route exceeds the fixed table height. (SEC-C21)
        static func routeTruncated(_ count: Int) -> String {
            String(format: String(localized: "export.routeTruncated"), count)
        }
    }

    enum PDF {
        static let title = String(localized: "pdf.title")
        static let pilot = String(localized: "pdf.pilot")
        static let aircraft = String(localized: "pdf.aircraft")
        static let totalEET = String(localized: "pdf.totalEET")
        static let endurance = String(localized: "pdf.endurance")
        static let runwayInUse = String(localized: "pdf.runwayInUse")
        static let instructor = String(localized: "pdf.instructor")
        static let noticeDate = String(localized: "pdf.noticeDate")
        static let noticeTime = String(localized: "pdf.noticeTime")
        static let sectionFuel = String(localized: "pdf.sectionFuel")
        static let groupTimes = String(localized: "pdf.groupTimes")
        static let groupCounter = String(localized: "pdf.groupCounter")
        static let counterStart = String(localized: "pdf.counterStart")
        static let counterStop = String(localized: "pdf.counterStop")
        static let landings = String(localized: "pdf.landings")
    }

    enum Nav {
        // Waypoint validation (SEC-C20)
        static let invalidValueTitle = String(localized: "nav.invalidValueTitle")
        static let invalidCoordinatesMessage = String(localized: "nav.invalidCoordinatesMessage")
        static let invalidAltitudeMessage = String(localized: "nav.invalidAltitudeMessage")

        // Flight Plans List
        static let flightPlans = String(localized: "nav.flightPlans")
        static let allFlightPlans = String(localized: "nav.allFlightPlans")
        static let activeFlightPlan = String(localized: "nav.activeFlightPlan")
        static let noFlightPlans = String(localized: "nav.noFlightPlans")
        static let noFlightPlansMessage = String(localized: "nav.noFlightPlansMessage")
        static let newFlightPlan = String(localized: "nav.newFlightPlan")
        static let importFlightPlan = String(localized: "nav.importFlightPlan")
        static let deleteFlightPlan = String(localized: "nav.deleteFlightPlan")
        static let deleteFlightPlanMessage = String(localized: "nav.deleteFlightPlanMessage")
        static let importError = String(localized: "nav.importError")
        static let importErrorMessage = String(localized: "nav.importErrorMessage")
        static let importErrorAccess = String(localized: "nav.importErrorAccess")
        static let importErrorFormat = String(localized: "nav.importErrorFormat")
        static let unnamedPlan = String(localized: "nav.unnamedPlan")
        static let active = String(localized: "nav.active")
        static let duplicate = String(localized: "nav.duplicate")
        static let activate = String(localized: "nav.activate")
        static let deactivate = String(localized: "nav.deactivate")
        static let inUse = String(localized: "nav.inUse")
        static let tapToBuild = String(localized: "nav.tapToBuild")
        static let from = String(localized: "nav.from")
        static let to = String(localized: "nav.to")
        static let swapEndpoints = String(localized: "nav.swapEndpoints")
        static let reorderWaypoints = String(localized: "nav.reorderWaypoints")
        static let dragToReorder = String(localized: "nav.dragToReorder")
        static let airspaceNotChecked = String(localized: "nav.airspaceNotChecked")
        static let airspaceNotCheckedDetail = String(localized: "nav.airspaceNotCheckedDetail")
        static let terrainNotChecked = String(localized: "nav.terrainNotChecked")
        static let terrainNotCheckedDetail = String(localized: "nav.terrainNotCheckedDetail")
        static let terrainProximity = String(localized: "nav.terrainProximity")
        static let terrainProximityDetail = String(localized: "nav.terrainProximityDetail")
        static let exportGPX = String(localized: "nav.exportGPX")
        static let routeProfileTitle = String(localized: "nav.routeProfileTitle")
        static let editRoute = String(localized: "nav.editRoute")
        static let logbookTimes = String(localized: "nav.logbookTimes")
        static let navLog = String(localized: "nav.navLog")
        static let expandProfile = String(localized: "nav.expandProfile")
        static let waypointsTab = String(localized: "nav.waypointsTab")
        static let conflictsTab = String(localized: "nav.conflictsTab")
        static let noConflicts = String(localized: "nav.noConflicts")
        static let addWaypoints = String(localized: "nav.addWaypoints")
        static let activateEmptyTitle = String(localized: "nav.activateEmptyTitle")
        static let activateEmptyMessage = String(localized: "nav.activateEmptyMessage")
        static let edit = String(localized: "nav.edit")
        static let export = String(localized: "nav.export")
        static let exportAsGPX = String(localized: "nav.exportAsGPX")
        static let exportAsJSON = String(localized: "nav.exportAsJSON")
        static let progress = String(localized: "nav.progress")
        static let next = String(localized: "nav.next")
        static let dist = String(localized: "nav.dist")

        // Flight Plan Editor
        static let aircraft = String(localized: "nav.aircraft")
        static let allAircraft = String(localized: "nav.allAircraft")
        static let filterByAircraft = String(localized: "nav.filterByAircraft")
        static let save = String(localized: "nav.save")
        static let flightPlan = String(localized: "nav.flightPlan")
        static let navigationFlightPlan = String(localized: "nav.navigationFlightPlan")
        static let flightType = String(localized: "nav.flightType")
        static let pilot = String(localized: "nav.pilot")
        static let date = String(localized: "nav.date")
        static let runway = String(localized: "nav.runway")
        static let instructor = String(localized: "nav.instructor")
        static let totalEET = String(localized: "nav.totalEET")
        static let distance = String(localized: "nav.distance")
        static let endurance = String(localized: "nav.endurance")
        static let freq = String(localized: "nav.freq")
        static let freqUnavailable = String(localized: "nav.freqUnavailable")
        static let noNearbyFreq = String(localized: "nav.noNearbyFreq")
        static let eto = String(localized: "nav.eto")
        static let mc = String(localized: "nav.mc")
        static let moveUp = String(localized: "nav.moveUp")
        static let moveDown = String(localized: "nav.moveDown")

        // Fuel Calculation
        static let fuelCalculation = String(localized: "nav.fuelCalculation")
        static let fuelFlow = String(localized: "nav.fuelFlow")
        static let tripFuel = String(localized: "nav.tripFuel")
        static let reserveFuel = String(localized: "nav.reserveFuel")
        static let additionalFuel = String(localized: "nav.additionalFuel")
        static let extraFuel = String(localized: "nav.extraFuel")
        static let requiredFuel = String(localized: "nav.requiredFuel")

        // Timing
        static let timing = String(localized: "nav.timing")
        static let counterStart = String(localized: "nav.counterStart")
        static let counterStop = String(localized: "nav.counterStop")
        static let blockOff = String(localized: "nav.blockOff")
        static let blockOn = String(localized: "nav.blockOn")
        static let timeOff = String(localized: "nav.timeOff")
        static let timeOn = String(localized: "nav.timeOn")
        static let ldgsAtBase = String(localized: "nav.ldgsAtBase")
        static let totalLdgs = String(localized: "nav.totalLdgs")
        static let engineTime = String(localized: "nav.engineTime")

        // Notes
        static let notes = String(localized: "nav.notes")
        static let remarks = String(localized: "nav.remarks")
        static let debriefing = String(localized: "nav.debriefing")

        // Actions
        static let activateFlightPlan = String(localized: "nav.activateFlightPlan")
        static let deactivateFlightPlan = String(localized: "nav.deactivateFlightPlan")

        // Waypoint Editor
        static let waypointName = String(localized: "nav.waypointName")
        static let latitude = String(localized: "nav.latitude")
        static let longitude = String(localized: "nav.longitude")
        static let altitude = String(localized: "nav.altitude")
        static let frequency = String(localized: "nav.frequency")
        static let location = String(localized: "nav.location")
        static let loadingElevation = String(localized: "nav.loadingElevation")
        static func groundLevel(_ ft: Int) -> String {
            String(format: String(localized: "nav.groundLevel"), ft)
        }
        static let defaultAGL = String(localized: "nav.defaultAGL")
        static let selectLocation = String(localized: "nav.selectLocation")
        static let waypointNamePlaceholder = String(localized: "nav.waypointNamePlaceholder")
        static let layer = String(localized: "nav.layer")
        static let selectDate = String(localized: "nav.selectDate")
        static let selectTime = String(localized: "nav.selectTime")
        static let set = String(localized: "nav.set")

        // Navigation View - Frequencies
        static let radioFrequencies = String(localized: "nav.radioFrequencies")
        static let allFrequencies = String(localized: "nav.allFrequencies")
        static let showLess = String(localized: "nav.showLess")
        static let fredaCheck = String(localized: "nav.fredaCheck")
        static let trackVector = String(localized: "nav.trackVector")
        static let trackVectorDesc = String(localized: "nav.trackVectorDesc")
        static let cruise = String(localized: "nav.cruise")
        static let checkNow = String(localized: "nav.checkNow")
        static let holdToReset = String(localized: "nav.holdToReset")
        static let freqCurrent = String(localized: "nav.freqCurrent")
        static let freqNext = String(localized: "nav.freqNext")
        static let startLeg = String(localized: "nav.startLeg")
        static let mark = String(localized: "nav.mark")
        static let overlays = String(localized: "nav.overlays")
        static let airspace = String(localized: "nav.airspace")
        static let airspaceNoData = String(localized: "nav.airspaceNoData")
        static let downloadAirspaceData = String(localized: "nav.downloadAirspaceData")
        static let tripDataMissing = String(localized: "Missing data for this trip")   // v4.1.0 prefetch banner (literal-keyed)
        static let layers = String(localized: "Layers")   // v4.1.0 ② (literal-keyed; FR in pass)
        static let airspaceCharts = String(localized: "Airspace & charts")
        static let mapTiles = String(localized: "Map tiles")
        static let mapMarkers = String(localized: "Map markers")
        static let flightSection = String(localized: "Flight")
        static let showAll = String(localized: "Show all")
        static let hideAll = String(localized: "Hide all")
        static let resumeLeg = String(localized: "nav.resumeLeg")
        static let resumeLegTitle = String(localized: "nav.resumeLegTitle")
        static let resumeLegMessage = String(localized: "nav.resumeLegMessage")

        // Navigation View - Waypoint Info
        static let hdgTo = String(localized: "nav.hdgTo")
        static let pauseChronometer = String(localized: "nav.pauseChronometer")
        static let startChronometer = String(localized: "nav.startChronometer")
        static let resetChronometer = String(localized: "nav.resetChronometer")
        static let wpt = String(localized: "nav.wpt")

        // Offline/Cache
        static let offline = String(localized: "nav.offline")
        static let cached = String(localized: "nav.cached")
        static let offlineModeActive = String(localized: "nav.offlineModeActive")
        static let usingCachedCharts = String(localized: "nav.usingCachedCharts")
        static let offlineDesc = String(localized: "nav.offlineDesc")
        static let offlineICAOOnly = String(localized: "nav.offlineICAOOnly")
        static let downloadSegelflugkarteDesc = String(localized: "nav.downloadSegelflugkarteDesc")
        static let cachedChartsDesc = String(localized: "nav.cachedChartsDesc")
        static let cachedTilesDesc = String(localized: "nav.cachedTilesDesc")
        static let icaoChart = String(localized: "nav.icaoChart")
        static let segelflugkarte = String(localized: "nav.segelflugkarte")
        static let notCached = String(localized: "nav.notCached")
        static let totalSize = String(localized: "nav.totalSize")
        static let goOnline = String(localized: "nav.goOnline")
        static let stayOffline = String(localized: "nav.stayOffline")

        // Waypoint Editor
        static let editWaypoint = String(localized: "nav.editWaypoint")
        static let deleteWaypoint = String(localized: "nav.deleteWaypoint")
        static let deleteWaypointConfirmation = String(localized: "nav.deleteWaypointConfirmation")
        static let selectOnMap = String(localized: "nav.selectOnMap")
        static let coordinatesHelp = String(localized: "nav.coordinatesHelp")
        static let plannedAltitude = String(localized: "nav.plannedAltitude")
        static let groundLevelNA = String(localized: "nav.groundLevelNA")
        static let navigation = String(localized: "nav.navigation")
        static let speeds = String(localized: "nav.speeds")
        static let zoomIn = String(localized: "nav.zoomIn")
        static let zoomOut = String(localized: "nav.zoomOut")
        static let groundSpeed = String(localized: "nav.groundSpeed")
        static let windDirection = String(localized: "nav.windDirection")
        static let windSpeed = String(localized: "nav.windSpeed")
        static let magneticCourse = String(localized: "nav.magneticCourse")
        static let distanceToNext = String(localized: "nav.distanceToNext")
        static let navigationHelp = String(localized: "nav.navigationHelp")
        static let radio = String(localized: "nav.radio")
        static let callsign = String(localized: "nav.callsign")
        static let eetFromDeparture = String(localized: "nav.eetFromDeparture")
        static let atoRecorded = String(localized: "nav.atoRecorded")
        static let selectedCoordinates = String(localized: "nav.selectedCoordinates")
        static let useThisLocation = String(localized: "nav.useThisLocation")

        // ICAO Flight Plan
        static let icaoDetails = String(localized: "nav.icaoDetails")
        static let icaoAircraftType = String(localized: "nav.icaoAircraftType")
        static let wakeTurbulence = String(localized: "nav.wakeTurbulence")
        static let equipmentCodes = String(localized: "nav.equipmentCodes")
        static let surveillanceCodes = String(localized: "nav.surveillanceCodes")
        static let alternateAerodrome = String(localized: "nav.alternateAerodrome")
        static let personsOnBoard = String(localized: "nav.personsOnBoard")
        static let aircraftColour = String(localized: "nav.aircraftColour")
        static let copyICAOFlightPlan = String(localized: "nav.copyICAOFlightPlan")
    }

    // MARK: - Companion Mode
    enum Companion {
        // Companion command authorisation (SEC-C40)
        static let allowControlTitle = String(localized: "companion.allowControlTitle")
        static let allowControl = String(localized: "companion.allowControl")
        static func allowControlMessage(_ device: String) -> String {
            String(format: String(localized: "companion.allowControlMessage"), device)
        }

        // Connectivity
        static let dataStale = String(localized: "companion.dataStale")
        // Settings
        static let companionMode = String(localized: "companion.companionMode")
        static let enableCompanionMode = String(localized: "companion.enableCompanionMode")
        static let enableDescription = String(localized: "companion.enableDescription")
        static let requiresIOS26 = String(localized: "companion.requiresIOS26")
        static let deviceRole = String(localized: "companion.deviceRole")
        static let roleAuto = String(localized: "companion.roleAuto")
        static let rolePrimary = String(localized: "companion.rolePrimary")
        static let roleCompanion = String(localized: "companion.roleCompanion")
        static let roleDescriptionMaster = String(localized: "companion.roleDescriptionMaster")
        static let roleDescriptionViewer = String(localized: "companion.roleDescriptionViewer")

        // Connection states
        static let connection = String(localized: "companion.connection")
        static let connected = String(localized: "companion.connected")
        static let disconnected = String(localized: "companion.disconnected")
        static let connecting = String(localized: "companion.connecting")
        static let reconnecting = String(localized: "companion.reconnecting")
        static let pairing = String(localized: "companion.pairing")
        static let connectedTo = String(localized: "companion.connectedTo")
        static let disconnect = String(localized: "companion.disconnect")
        static let connectToiPad = String(localized: "companion.connectToiPad")
        static let startListening = String(localized: "companion.startListening")

        // Pairing
        static let pairDevice = String(localized: "companion.pairDevice")
        static let pairNewDevice = String(localized: "companion.pairNewDevice")
        static let pairedDevices = String(localized: "companion.pairedDevices")
        static let noPairedDevices = String(localized: "companion.noPairedDevices")
        static let unknownDevice = String(localized: "companion.unknownDevice")
        static let companionDevice = String(localized: "companion.companionDevice")
        static let masterDevice = String(localized: "companion.masterDevice")
        static let pairDeviceFirst = String(localized: "companion.pairDeviceFirst")
        static let waitingForPairing = String(localized: "companion.waitingForPairing")
        static let pairingMasterDescription = String(localized: "companion.pairingMasterDescription")
        static let pairWithiPad = String(localized: "companion.pairWithiPad")
        static let pairWithiPhone = String(localized: "companion.pairWithiPhone")
        static let pairingViewerDescription = String(localized: "companion.pairingViewerDescription")
        static let scanForDevices = String(localized: "companion.scanForDevices")
        static let makeDiscoverable = String(localized: "companion.makeDiscoverable")
        // Shared pairing guidance: the user must tap the button on BOTH devices for discovery to work.
        static let pairBothDevices = String(localized: "companion.pairBothDevices")

        // Pairing guidance (role is automatic by device type)
        static let pairingGuidanceMaster = String(localized: "companion.pairingGuidanceMaster")
        static let pairingGuidanceViewer = String(localized: "companion.pairingGuidanceViewer")

        // Wi-Fi Aware
        static let wifiAwareUnavailable = String(localized: "companion.wifiAwareUnavailable")
        static let wifiAwareRequirement = String(localized: "companion.wifiAwareRequirement")
        static let wifiAwareInfo = String(localized: "companion.wifiAwareInfo")
        static let noNetworkRequired = String(localized: "companion.noNetworkRequired")

        // Diagnostics (developer mode)
        static let diagnostics = String(localized: "companion.diagnostics")
        static let diagnosticsFooter = String(localized: "companion.diagnosticsFooter")
        static let diagWifiAware = String(localized: "companion.diagWifiAware")
        static let diagSupported = String(localized: "companion.diagSupported")
        static let diagUnsupported = String(localized: "companion.diagUnsupported")
        static let diagThisDevice = String(localized: "companion.diagThisDevice")
        static let diagConnection = String(localized: "companion.diagConnection")
        static let diagService = String(localized: "companion.diagService")
        static let diagRoleMaster = String(localized: "companion.diagRoleMaster")
        static let diagRoleViewer = String(localized: "companion.diagRoleViewer")
        static let diagNoEvents = String(localized: "companion.diagNoEvents")
        static let diagCopy = String(localized: "companion.diagCopy")

        // Flight view
        static let connectionLost = String(localized: "companion.connectionLost")
        static let switchToStandalone = String(localized: "companion.switchToStandalone")
        static let holdToExit = String(localized: "companion.holdToExit")
        // Companion v2 wingman
        static let providingGPS = String(localized: "companion.providingGPS")
        static let checklistUnavailable = String(localized: "companion.checklistUnavailable")
        static let checkAndNext = String(localized: "companion.checkAndNext")
        static let nextPhase = String(localized: "companion.nextPhase")
        static let connectedWith = String(localized: "companion.connectedWith")
        static let startFlightOnMaster = String(localized: "companion.startFlightOnMaster")
        static let connectingTo = String(localized: "companion.connectingTo")
        static let keepTrying = String(localized: "companion.keepTrying")
        static let recordATO = String(localized: "companion.recordATO")
        static let noFlightPlan = String(localized: "companion.noFlightPlan")
        static let holdToReveal = String(localized: "companion.holdToReveal")
        static let exitConfirmTitle = String(localized: "companion.exitConfirmTitle")
        static let exitConfirmMessage = String(localized: "companion.exitConfirmMessage")
        static let exitConfirmLeave = String(localized: "companion.exitConfirmLeave")
        static let pairInSettings = String(localized: "companion.pairInSettings")
    }
}

// MARK: - Checklist Language

/// Represents available languages for checklists
enum ChecklistLanguage: String, CaseIterable, Codable, Identifiable {
    case auto = "auto"
    case en = "en"
    case fr = "fr"
    case de = "de"
    case it = "it"

    var id: String { rawValue }

    /// Languages for which at least one checklist is currently available
    /// Currently English and French checklists exist (both WT9 and PA-28-181 have English and French)
    static var availableLanguages: [ChecklistLanguage] {
        return [.auto, .en, .fr]
    }

    /// Display name for the language
    var displayName: String {
        switch self {
        case .auto:
            return L10n.Settings.checklistLanguageAuto
        case .en:
            return L10n.Language.en
        case .fr:
            return L10n.Language.fr
        case .de:
            return L10n.Language.de
        case .it:
            return L10n.Language.it
        }
    }

    /// ISO 639-1 code (for API requests)
    var isoCode: String? {
        switch self {
        case .auto:
            return nil
        default:
            return rawValue
        }
    }

    /// Resolves the actual language to use, considering system language for .auto
    var resolvedLanguage: String {
        switch self {
        case .auto:
            // Get the preferred language from the system
            let preferred = Locale.preferredLanguages.first ?? "en"
            let languageCode = Locale(identifier: preferred).language.languageCode?.identifier ?? "en"
            // Only return if it's a supported checklist language
            if ChecklistLanguage.allCases.contains(where: { $0.rawValue == languageCode && $0 != .auto }) {
                return languageCode
            }
            return "en" // Fallback to English
        default:
            return rawValue
        }
    }
}
