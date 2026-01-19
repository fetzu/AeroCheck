import Foundation
import SwiftUI

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
        static func version(_ v: String) -> String {
            String(format: String(localized: "home.version"), v)
        }
    }

    // MARK: - Stats
    enum Stats {
        static let checks = String(localized: "stats.checks")
        static let items = String(localized: "stats.items")
    }

    // MARK: - GPS
    enum GPS {
        static let ready = String(localized: "gps.ready")
        static let denied = String(localized: "gps.denied")
        static let restricted = String(localized: "gps.restricted")
        static let notSet = String(localized: "gps.notSet")
        static let status = String(localized: "gps.status")
        static let authorized = String(localized: "gps.authorized")
        static let notDetermined = String(localized: "gps.notDetermined")
        static let unknown = String(localized: "gps.unknown")
        static let requestPermission = String(localized: "gps.requestPermission")
        static let signal = String(localized: "gps.signal")
        static let signalGood = String(localized: "gps.signal.good")
        static let signalDegraded = String(localized: "gps.signal.degraded")
        static let signalLost = String(localized: "gps.signal.lost")
        static let signalInactive = String(localized: "gps.signal.inactive")
        static let points = String(localized: "gps.points")
        static let pointsRecorded = String(localized: "gps.pointsRecorded")
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
        static let emergencyBriefing = String(localized: "briefing.emergencyBriefing")
        static let missedApproach = String(localized: "briefing.missedApproach")
        static let alternate = String(localized: "briefing.alternate")
        static let close = String(localized: "briefing.close")
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

        // GPS
        static let gps = String(localized: "settings.gps")
        static let gpsInterval = String(localized: "settings.gps.recordingInterval")
        static let gpsStatus = String(localized: "settings.gps.gpsStatus")
        static func seconds(_ n: Int) -> String {
            String(format: String(localized: "settings.gps.seconds"), n)
        }
        static let gpsFooter = String(localized: "settings.gps.lowerIntervals")

        // Experimental
        static let experimental = String(localized: "settings.experimental")
        static let showEstimatedAirspeed = String(localized: "settings.experimental.showEstimatedAirspeed")
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

        // Navigation
        static let navigation = String(localized: "settings.navigation")
        static let forceICAO = String(localized: "settings.navigation.forceICAO")
        static let forceICAOFooter = String(localized: "settings.navigation.forceICAODesc")

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

        // Checklist
        static let checklist = String(localized: "settings.checklist")
        static let stepByStep = String(localized: "settings.checklist.stepByStep")
        static let learningMode = String(localized: "settings.checklist.learningMode")
        static let circuitMode = String(localized: "settings.checklist.circuitMode")
        static let stepByStepFooter = String(localized: "settings.checklist.stepByStepFooter")
        static let learningModeFooter = String(localized: "settings.checklist.learningModeFooter")
        static let circuitModeFooter = String(localized: "settings.checklist.circuitModeFooter")

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
        static let forceNotSubscribed = String(localized: "settings.developer.forceNotSubscribed")
        static let showAllTransactions = String(localized: "settings.developer.showAllTransactions")
        static let showSubscriptionLogs = String(localized: "settings.developer.showSubscriptionLogs")
        static let resetSubscription = String(localized: "settings.developer.resetSubscription")
        static let marketingModeDesc = String(localized: "settings.developer.marketingModeDesc")
        static let forceNotSubscribedDesc = String(localized: "settings.developer.forceNotSubscribedDesc")
        static let showAllTransactionsDesc = String(localized: "settings.developer.showAllTransactionsDesc")
        static let showSubscriptionLogsDesc = String(localized: "settings.developer.showSubscriptionLogsDesc")
        static let resetSubscriptionDesc = String(localized: "settings.developer.resetSubscriptionDesc")
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
        static let fullStop = String(localized: "checklist.fullStop")
        static let fullStops = String(localized: "checklist.fullStops")
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

        static func fullStop(language: String) -> String {
            localizedString(key: "checklist.fullStop", language: language, defaultValue: "FULL STOP")
        }

        static func fullStops(language: String) -> String {
            localizedString(key: "checklist.fullStops", language: language, defaultValue: "Full Stops")
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
        static let airspeedsAFM = String(localized: "checklist.airspeeds.afm")
        static let maxCrosswind = String(localized: "checklist.maxCrosswind")
    }

    // MARK: - Flight Detail
    enum FlightDetail {
        // Export
        static let exportFormatTitle = String(localized: "flightDetail.exportFormat.title")
        static let exportFormatGPX = String(localized: "flightDetail.exportFormat.gpx")
        static let exportFormatJSON = String(localized: "flightDetail.exportFormat.json")
        static let exportFormatMessage = String(localized: "flightDetail.exportFormat.message")

        // Delete
        static let deleteTitle = String(localized: "flightDetail.delete.title")
        static let deleteMessage = String(localized: "flightDetail.delete.message")

        // Sections
        static let flightTrack = String(localized: "flightDetail.flightTrack")
        static let noGPSData = String(localized: "flightDetail.noGPSData")
        static let altitudeProfile = String(localized: "flightDetail.altitudeProfile")
        static let noAltitudeData = String(localized: "flightDetail.noAltitudeData")
        static let flightDetails = String(localized: "flightDetail.flightDetails")

        // Details
        static let aircraft = String(localized: "flightDetail.aircraft")
        static let date = String(localized: "flightDetail.date")
        static let flightTime = String(localized: "flightDetail.flightTime")
        static let distance = String(localized: "flightDetail.distance")
        static let gpsPoints = String(localized: "flightDetail.gpsPoints")
        static let goArounds = String(localized: "flightDetail.goArounds")
        static let touchAndGoes = String(localized: "flightDetail.touchAndGoes")
        static let fullStops = String(localized: "flightDetail.fullStops")

        // Times
        static let flightTimes = String(localized: "flightDetail.flightTimes")
        static let sessionStart = String(localized: "flightDetail.sessionStart")
        static let engineStart = String(localized: "flightDetail.engineStart")
        static let takeoff = String(localized: "flightDetail.takeoff")
        static let landing = String(localized: "flightDetail.landing")
        static let engineShutdown = String(localized: "flightDetail.engineShutdown")
        static let sessionEnd = String(localized: "flightDetail.sessionEnd")

        // Name/Notes
        static let flightName = String(localized: "flightDetail.flightName")
        static let namePlaceholder = String(localized: "flightDetail.namePlaceholder")
        static let notes = String(localized: "flightDetail.notes")

        // Actions
        static let navPlan = String(localized: "flightDetail.navPlan")
        static let export = String(localized: "flightDetail.export")
        static let delete = String(localized: "flightDetail.delete")
    }

    // MARK: - Debug
    enum Debug {
        // Transaction Debug
        static let transactionLoading = String(localized: "debug.transaction.loading")
        static let transactionNoFound = String(localized: "debug.transaction.noFound")
        static let transactionCouldMean = String(localized: "debug.transaction.couldMean")
        static let transactionTotal = String(localized: "debug.transaction.totalTransactions")
        static let transactionActive = String(localized: "debug.transaction.activeSubscriptions")
        static let transactionAccountType = String(localized: "debug.transaction.accountType")
        static let transactionSummary = String(localized: "debug.transaction.summary")
        static let transactionAll = String(localized: "debug.transaction.allTransactions")
        static let transactionTitle = String(localized: "debug.transaction.title")
        static let transactionClose = String(localized: "debug.transaction.close")
        static let transactionEnvironment = String(localized: "debug.transaction.environment")
        static let transactionPurchased = String(localized: "debug.transaction.purchased")
        static let transactionExpires = String(localized: "debug.transaction.expires")
        static let transactionID = String(localized: "debug.transaction.transactionID")
        static let transactionOriginalID = String(localized: "debug.transaction.originalID")
        static func transactionVerificationError(_ error: String) -> String {
            String(format: String(localized: "debug.transaction.verificationError"), error)
        }
        static func transactionRevokedOn(_ date: String) -> String {
            String(format: String(localized: "debug.transaction.revokedOn"), date)
        }

        // Subscription Log
        static let subscriptionLogNoLogs = String(localized: "debug.subscriptionLog.noLogs")
        static let subscriptionLogAppear = String(localized: "debug.subscriptionLog.logsAppear")
        static let subscriptionLogTitle = String(localized: "debug.subscriptionLog.title")
        static let subscriptionLogClose = String(localized: "debug.subscriptionLog.close")
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
    /// Currently only English and French checklists exist (WT9 is English-only, PA-28-181 has English and French)
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
