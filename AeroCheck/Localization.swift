import Foundation
import SwiftUI

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
            String(localized: "home.version", defaultValue: "Version \(v)")
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
            String(localized: "flight.phase \(current) \(total)")
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
            String(localized: "phase.completed", defaultValue: "\(phase) COMPLETED")
        }
    }

    // MARK: - Briefing
    enum Briefing {
        static let departure = String(localized: "briefing.departure")
        static let approach = String(localized: "briefing.approach")
    }

    // MARK: - Settings
    enum Settings {
        static let title = String(localized: "settings.title")
        static let subscription = String(localized: "settings.subscription")
        static let aeroCheckPro = String(localized: "settings.aeroCheckPro")
        static let subscriptionSubscribed = String(localized: "settings.subscription.subscribed")
        static let subscriptionGracePeriod = String(localized: "settings.subscription.gracePeriod")
        static let subscriptionUnlock = String(localized: "settings.subscription.unlock")
        static func gracePeriodEnds(_ date: String) -> String {
            String(localized: "settings.subscription.gracePeriodEnds", defaultValue: "Grace period ends \(date)")
        }

        // Aircraft
        static let aircraft = String(localized: "settings.aircraft")
        static let premiumAircrafts = String(localized: "settings.aircraft.premium")
        static let loading = String(localized: "settings.aircraft.loading")
        static func available(_ accessible: Int, _ total: Int) -> String {
            String(localized: "settings.aircraft.available", defaultValue: "\(accessible)/\(total) available")
        }
        static let noPremium = String(localized: "settings.aircraft.noPremium")
        static let getLatest = String(localized: "settings.aircraft.getLatest")
        static let aircraftFooter = String(localized: "settings.aircraft.footer")

        // GPS
        static let gps = String(localized: "settings.gps")
        static let gpsInterval = String(localized: "settings.gps.interval")
        static func seconds(_ n: Int) -> String {
            String(localized: "settings.gps.seconds", defaultValue: "\(n) seconds")
        }
        static let gpsFooter = String(localized: "settings.gps.footer")

        // Experimental
        static let experimental = String(localized: "settings.experimental")
        static let showEstimatedAirspeed = String(localized: "settings.experimental.showEstimatedAirspeed")
        static let experimentalFooter = String(localized: "settings.experimental.footer")
        static let switzerlandOnly = String(localized: "settings.experimental.switzerlandOnly")

        // Flight Planning
        static let flightPlanning = String(localized: "settings.flightPlanning")
        static let enableFlightPlanning = String(localized: "settings.flightPlanning.enable")
        static let waypointProximity = String(localized: "settings.flightPlanning.waypointProximity")
        static let terrainUnit = String(localized: "settings.flightPlanning.terrainUnit")
        static let flightPlanningFooter = String(localized: "settings.flightPlanning.footer")
        static let waypointProximityFooter = String(localized: "settings.flightPlanning.waypointProximityFooter")
        static let terrainUnitFooter = String(localized: "settings.flightPlanning.terrainUnitFooter")

        // Display
        static let display = String(localized: "settings.display")
        static let keepScreenOn = String(localized: "settings.display.keepScreenOn")
        static let alwaysUseUTC = String(localized: "settings.display.alwaysUseUTC")
        static let keepScreenOnFooter = String(localized: "settings.display.keepScreenOnFooter")
        static let alwaysUseUTCFooter = String(localized: "settings.display.alwaysUseUTCFooter")

        // Navigation
        static let navigation = String(localized: "settings.navigation")
        static let forceICAO = String(localized: "settings.navigation.forceICAO")
        static let forceICAOFooter = String(localized: "settings.navigation.forceICAOFooter")

        // iCloud
        static let icloud = String(localized: "settings.icloud")
        static let syncToICloud = String(localized: "settings.icloud.syncToICloud")
        static let lastSync = String(localized: "settings.icloud.lastSync")
        static let syncNow = String(localized: "settings.icloud.syncNow")
        static let syncing = String(localized: "settings.icloud.syncing")
        static let icloudFooter = String(localized: "settings.icloud.footer")
        static let flightLogsFooter = String(localized: "settings.icloud.flightLogsFooter")

        // Offline Maps
        static let offlineMaps = String(localized: "settings.offlineMaps")
        static let offlineMode = String(localized: "settings.offlineMaps.offlineMode")
        static let icaoChart = String(localized: "settings.offlineMaps.icaoChart")
        static let segelflugkarte = String(localized: "settings.offlineMaps.segelflugkarte")
        static let totalCacheSize = String(localized: "settings.offlineMaps.totalCacheSize")
        static let updateCharts = String(localized: "settings.offlineMaps.updateCharts")
        static let deleteCache = String(localized: "settings.offlineMaps.deleteCache")
        static let downloadCharts = String(localized: "settings.offlineMaps.downloadCharts")

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
        static let openSourceDescription = String(localized: "settings.about.openSourceDescription")
        static let mitLicense = String(localized: "settings.about.mitLicense")

        // Available Checklists
        static let availableChecklists = String(localized: "settings.availableChecklists")
        static let noCached = String(localized: "settings.availableChecklists.noCached")
        static let availableChecklistsFooter = String(localized: "settings.availableChecklists.footer")

        // Data
        static let data = String(localized: "settings.data")
        static let recordedFlights = String(localized: "settings.data.recordedFlights")
        static let totalGPSPoints = String(localized: "settings.data.totalGPSPoints")
    }

    // MARK: - Sheets
    enum Sheet {
        static let speedReference = String(localized: "sheet.speedReference")
        static let selectPhase = String(localized: "sheet.selectPhase")
        static func page(_ n: Int) -> String {
            String(localized: "sheet.page", defaultValue: "Page \(n)")
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
        static let noFlights = String(localized: "flightLog.noFlights")
        static let startFlightPrompt = String(localized: "flightLog.startFlightPrompt")
        static let export = String(localized: "flightLog.export")
        static let importFlight = String(localized: "flightLog.import")
        static let exportAll = String(localized: "flightLog.exportAll")
        static let exportAsGPX = String(localized: "flightLog.exportAsGPX")
        static let exportAsJSON = String(localized: "flightLog.exportAsJSON")
        static let exportAsZIP = String(localized: "flightLog.exportAsZIP")
    }

    // MARK: - Premium
    enum Premium {
        static let title = String(localized: "premium.title")
        static let loading = String(localized: "premium.loading")
        static let noAircraft = String(localized: "premium.noAircraft")
        static let checkBack = String(localized: "premium.checkBack")
        static let requiresSubscription = String(localized: "premium.requiresSubscription")
    }

    // MARK: - Warnings
    enum Warning {
        static let betaFeature = String(localized: "warning.betaFeature")
        static let experimentalFeature = String(localized: "warning.experimentalFeature")
        static let iUnderstand = String(localized: "warning.iUnderstand")
    }

    // MARK: - Download
    enum Download {
        static let title = String(localized: "download.title")
        static let description = String(localized: "download.description")
        static let selectCharts = String(localized: "download.selectCharts")
        static let icaoOnly = String(localized: "download.icaoOnly")
        static let icaoAndSegelflug = String(localized: "download.icaoAndSegelflug")
        static let cached = String(localized: "download.cached")
        static let downloading = String(localized: "download.downloading")
        static func downloadingLayer(_ name: String) -> String {
            String(localized: "download.downloadingLayer", defaultValue: "Downloading \(name)...")
        }
        static func estimatedTime(_ time: String) -> String {
            String(localized: "download.estimatedTime", defaultValue: "Estimated time remaining: \(time)")
        }
        static func total(_ size: String) -> String {
            String(localized: "download.total", defaultValue: "Total: \(size)")
        }
        static let redownload = String(localized: "download.redownload")
        static let downloadSegelflug = String(localized: "download.downloadSegelflug")
    }

    // MARK: - Tags
    enum Tag {
        static let beta = String(localized: "beta")
        static let dev = String(localized: "dev")
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
