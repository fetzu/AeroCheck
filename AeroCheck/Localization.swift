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

/// The languages the app ships in: English first, then the others as the bundle has them ("de", "fr"). What
/// measures a word in every language reads this (the act band's frames, the width tests), and so does the request
/// flow, so a new language is its catalog and nothing else. (6.5.0)
enum AppLanguage {
    static let shipped: [String] = {
        let found = Set(Bundle.main.localizations.filter { $0 != "Base" }.map { String($0.prefix(2)) })
        return ["en"] + found.subtracting(["en"]).sorted()
    }()

    /// The language the app reads in now: the device's when the app ships it, else English.
    static var current: String {
        Bundle.main.preferredLocalizations.first.map { String($0.prefix(2)) } ?? "en"
    }
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
        static let subtitle = String(localized: "Updates & offline storage")
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
        static let caveat = String(localized: "This data comes from the community, so keep it up to date. It is not official aeronautical information: always check that it is current before flight.")
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
        static let openAIPTilesDetail = String(localized: "OpenAIP · optional chart imagery. Warnings come from the airspace data above.")
        static let openAIPAttribution = String(localized: "Airspace data from [OpenAIP.net](https://www.openaip.net) (© OpenAIP and contributors, CC BY-NC 4.0)")
        static let checklistsSection = String(localized: "Checklists")
        static let checklistsDetail = String(localized: "Auto-updating · aircraft checklists from aerocheck.app")
        static let noChecklists = String(localized: "No checklists cached yet")
        static let syncChecklists = String(localized: "Check for checklist updates")
        /// Shown only when the device is missing checklists it owns — an update check cannot fetch a
        /// first copy, so this is a separate, honestly-labelled action. The count is parenthesised so
        /// neither language needs a plural form. (v4.4.0)
        static func downloadMissingChecklists(_ count: Int) -> String {
            String(format: String(localized: "dataStorage.downloadMissingChecklists"), count)
        }
        static let simulateStaleData = String(localized: "Simulate stale data")
        static let rowActions = String(localized: "More options")
        static let manageRegions = String(localized: "Manage regions & downloads")
        static let manageRegionsDetail = String(localized: "Add or remove countries and continents in Navigation & Maps")
        // About → Data sources credits
        static let dataSourcesTitle = String(localized: "Data sources")
        static let sourceCharts = String(localized: "Aeronautical charts · © swisstopo / BAZL")
        static let sourceAirspace = String(localized: "Airspace · © OpenAIP and contributors, CC BY-NC 4.0")
        /// open flightmaps' licence asks for the credit, and its data is never a primary source. (6.2.0)
        static let sourceVFRProcedures = String(localized: "Traffic circuits, VFR routes & reporting points · © open flightmaps association · indicative, not for primary navigation")
        static let sourceAirports = String(localized: "Airport database · public domain")
        static let sourceWind = String(localized: "Surface wind (Switzerland) · © MeteoSwiss")
        static let sourceElevation = String(localized: "Terrain elevation & winds aloft · Open-Meteo (CC BY 4.0), © swisstopo")
        static let sourceObservations = String(localized: "METAR / TAF / SIGMET · NOAA Aviation Weather Center, public domain")
        /// Prepare's and the close-out's links, and the US traffic patterns. (6.5.0)
        static let sourceBriefingName = String(localized: "settings.source.briefingName")
        static let sourceBriefing = String(localized: "settings.source.briefing")
        static let sourcePatterns = String(localized: "settings.source.patterns")
        static let sourceTypeface = String(localized: "dataStorage.source.typeface")
        static let sourceBorders = String(localized: "National borders (trip data coverage) · Natural Earth, public domain")
        static let navaidsName = String(localized: "Navaids")
        static let navaidsDetail = String(localized: "OpenAIP · VOR / DME / NDB radio navigation aids")
        static let showNavaidsOnMap = String(localized: "Show navaids on map")
        static let obstaclesName = String(localized: "Obstacles")
        static let obstaclesDetail = String(localized: "OpenAIP · towers, masts and wind turbines")
        static let showObstaclesOnMap = String(localized: "Show obstacles on map")
        static let reportingPointsName = String(localized: "Reporting points")
        static let reportingPointsDetail = String(localized: "OpenAIP · VFR reporting points")
        static let showReportingPointsOnMap = String(localized: "Show reporting points on map")
        static let openAIPAirportsName = String(localized: "Aerodromes")
        static let openAIPAirportsDetail = String(localized: "OpenAIP · runways, frequencies & PPR · primary source")
        // open flightmaps VFR procedures (6.2.0)
        static let vfrProceduresName = String(localized: "VFR procedures (open flightmaps)")
        static let vfrProceduresDetail = String(localized: "open flightmaps · traffic circuits, VFR arrival & departure routes, sectors")
        static let vfrProceduresAttribution = String(localized: "© open flightmaps association · not for primary navigation")
        /// "AIRAC 2610 · valid Oct 1 – 28, 2026": the cycle on disk while it is current.
        static func vfrCycleValid(_ airac: String, _ days: String) -> String {
            String(localized: "AIRAC \(airac) · valid \(days)")
        }
        /// The cycle has ended and OFM hasn't published the next one yet.
        static func vfrCycleNotPublished(_ airac: String) -> String {
            String(localized: "AIRAC \(airac) · a newer cycle isn't published yet")
        }
        /// The cycle has ended and the next one is out (the update hasn't run, or failed).
        static func vfrCycleAvailable(_ airac: String, _ newer: String) -> String {
            String(localized: "AIRAC \(airac) · AIRAC \(newer) is available")
        }
        /// Under a data row, and in Navigation & Maps, after an update that did not complete: the
        /// countries that kept their old data, or none for a dataset that isn't per-country. (6.2.0)
        static func updateFailed(_ countries: [String]) -> String {
            countries.isEmpty
                ? String(localized: "Couldn't update. Try again on Wi-Fi.")
                : String(localized: "Couldn't update \(countries.joined(separator: ", ")). Try again on Wi-Fi.")
        }
        /// Lower-case layer name for the trip-size breakdown ("29 841 obstacles · 152 navaids").
        ///
        /// Reuses the row titles, which are already plural and read correctly after a count in both
        /// languages — except the airspace row, which is the singular mass noun "Airspace" /
        /// "Espace aérien" and would produce "1 557 airspace". That one gets its own countable form.
        /// (v4.4.0)
        static func layerName(_ layer: TripDataSizeEstimator.Layer) -> String {
            switch layer {
            case .airspace: return String(localized: "dataStorage.countAirspaces")
            case .navaids: return inSentence(navaidsName)
            case .obstacles: return inSentence(obstaclesName)
            case .reportingPoints: return inSentence(reportingPointsName)
            case .vfrProcedures: return String(localized: "VFR procedures")
            }
        }
        /// A row's name inside a sentence ("152 navaids"): lower case, except in German, whose nouns keep
        /// their capital ("152 Navigationshilfen"). (6.5.0)
        private static func inSentence(_ name: String) -> String {
            AppLanguage.current == "de" ? name : name.lowercased()
        }
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
        /// END FLIGHT in the iPhone's act band, on one line. (6.2.0)
        static let endFlightShort = String(localized: "button.endFlight.short")
        static let end = String(localized: "button.end")
        static let done = String(localized: "button.done")
        static let close = String(localized: "button.close")
        static let clear = String(localized: "button.clear")
        static let retry = String(localized: "button.retry")
        static let cancel = String(localized: "button.cancel")
        static let delete = String(localized: "button.delete")
        static let flightLog = String(localized: "button.flightLog")
        static let back = String(localized: "button.back")
        /// The app's own page in the Settings app, where its permissions are changed. (6.3.2)
        static let openSettings = String(localized: "button.openSettings")
    }

    // MARK: - Border crossing (v5.0.0)
    enum Border {
        static let required = String(localized: "Required")
        static let conditional = String(localized: "Under conditions")
        static let notRequired = String(localized: "Not required")
        static let unknown = String(localized: "Not established")
        static let disputed = String(localized: "Official sources disagree")
        static let customsAerodrome = String(localized: "Customs aerodrome")
        static let priorNotification = String(localized: "Prior notification")
        static let noticeLeadTime = String(localized: "Lead time")
        static let swissSide = String(localized: "Swiss side")
        static let openOfficial = String(localized: "Official rules")
        static func reviewed(_ date: String) -> String {
            String(localized: "Checked \(date)")
        }
        static let notCurated = String(localized: "Not checked for this country yet: see the AIP and the national customs authority")
        static let advisory = String(localized: "A reminder, not a clearance: the authority's page is the reference")
        static let unknownWarning = String(localized: "If a requirement is not established, assume it applies until you have checked")
    }

    enum ThreadBadge {
        /// Rendered on a task the app ticks by itself. Identical in French, but it was the one
        /// prose literal in FlightThreadView that bypassed the catalogue. (review, localization 12)
        static let auto = String(localized: "AUTO")
    }

    // MARK: - Logbook line (v5.0.0)
    // MARK: - Flights (v5.0.0)

    enum Flights {
        static let title = String(localized: "Flights")
        static func circuitsAt(_ ident: String) -> String {
            String(localized: "Circuits at \(ident)")
        }

        // Plan new flight
        static let planNewFlight = String(localized: "Plan new flight")
        static let savedRoutes = String(localized: "Saved routes")
        static let createFlight = String(localized: "Create flight")
        static let circuits = String(localized: "Circuits")
        static let when = String(localized: "When")
        static let whenHint = String(localized: "Used for the reminder the day before")
        static let aircraft = String(localized: "settings.aircraft")
        static let from = String(localized: "From")
        static let to = String(localized: "To")
        static let identPlaceholder = String(localized: "ICAO or name")
        static func legCount(_ count: Int) -> String {
            String(localized: "\(count) legs")
        }
        static func legOf(_ index: Int, _ total: Int) -> String {
            String(localized: "Leg \(index) of \(total)")
        }
        static func tripProgress(_ done: Int, _ total: Int) -> String {
            String(localized: "TRIP · \(done) of \(total)")
        }
        static func recheckForThisLeg(_ when: String) -> String {
            String(localized: "Checked \(when), re-check for this leg")
        }

        // Home
        static let homeExplainer = String(localized: "Follow a flight from planning to logbook: fuel, weather, customs, then the numbers")
        static func savedPlans(_ count: Int) -> String {
            String(localized: "\(count) saved plans")
        }

        // Flights destination
        static let upcoming = String(localized: "Upcoming")
        static let past = String(localized: "Past")
        static let needsAttention = String(localized: "Needs attention")
        static let nothingPlanned = String(localized: "Nothing planned")
        static let planThisAgain = String(localized: "Plan this again")
        static func toDo(_ count: Int) -> String {
            String(localized: "\(count) to do")
        }
    }

    /// A circuits flight's laps and loops, as VoiceOver says them (6.3.0).
    enum Circuits {
        /// The touch-and-go loop's count, "3 touch-and-goes and go-arounds"; "1 full stop".
        static func touchAndGoLoopLaps(_ count: Int) -> String { String(localized: "\(count) touch-and-goes and go-arounds") }
        static func fullStops(_ count: Int) -> String { String(localized: "\(count) full stops") }
        /// The phase bar's two brackets.
        static let touchAndGoLoop = String(localized: "circuits.touchAndGoLoop")
        static let fullStopLoop = String(localized: "circuits.fullStopLoop")
        /// The bracket the lap being flown took.
        static let thisLap = String(localized: "circuits.thisLap")
        /// Cruise and descent in the phase list of a circuits flight, and the question a tap on one asks.
        /// (6.3.0, Q5)
        static let skippedInCircuits = String(localized: "circuits.skippedInCircuits")
        static let leaveTitle = String(localized: "circuits.leaveTitle")
        static let leaveMessage = String(localized: "circuits.leaveMessage")
        /// "Leave circuits, go to CRUISE CHECK"
        static func leaveAndGo(_ check: String) -> String {
            String(format: String(localized: "circuits.leaveAndGo"), check)
        }
        static let stay = String(localized: "circuits.stay")
        /// The phone's phase button: "circuit 4: 2 touch-and-goes, 1 full stop".
        static func lapSpeech(_ lap: Int, touchAndGoes: Int, fullStops: Int) -> String {
            String(format: String(localized: "circuits.lapSpeech"), lap,
                   [Self.touchAndGoLoopLaps(touchAndGoes), Self.fullStops(fullStops)].joined(separator: ", "))
        }
    }

    enum Logbook {
        static let title = String(localized: "Logbook line")
        static let subtitle = String(localized: "EASA AMC1 FCL.050")
        static let functionPIC = String(localized: "PIC")
        static let functionDual = String(localized: "Dual")
        static let functionCoPilot = String(localized: "Co-pilot")
        static let functionInstructor = String(localized: "Instructor")
        static func remarkTouchAndGo(_ count: Int) -> String {
            String(localized: "\(count) touch-and-go")
        }
        static func remarkGoAround(_ count: Int) -> String {
            String(localized: "\(count) go-around")
        }
        static func remarkStopAndGo(_ count: Int) -> String {
            String(localized: "\(count) stop-and-go")
        }
        static let copyLine = String(localized: "Copy line")
        static let lineCopied = String(localized: "Logbook line copied")
        static let showRow = String(localized: "Logbook row")
        static let showRowHint = String(localized: "These are the same values, in your logbook's column order. Scroll sideways for the other columns, and use Edit to correct them.")
        static let exportCSV = String(localized: "Export CSV")
        static let picName = String(localized: "PIC name")
        static let function = String(localized: "Function")
        static let nightTime = String(localized: "Night")
        static let ifrTime = String(localized: "IFR")
        static let remarks = String(localized: "Remarks")
        static let notALogbook = String(localized: "A draft for your logbook: AeroCheck is not a logbook of record")
        static let timesAreUTC = String(localized: "Times are UTC, from off-block and on-block times")
        static let nightLandings = String(localized: "Night landings")
        /// The PIC-column fallback when no pilot name is set.
        static let picSelf = String(localized: "logbook.pic.self")
        static let nightNotComputed = String(localized: "Enter night and IFR time yourself: the app does not compute twilight")

        // PDF extract
        static let exportPDF = String(localized: "Export logbook PDF")
        static func pdfPage(_ page: Int, _ total: Int) -> String {
            String(localized: "Page \(page) of \(total)")
        }
        static func pdfHolder(_ name: String) -> String {
            String(localized: "Holder: \(name)")
        }
        static let pdfLayoutNote = String(localized: "Layout per EASA AMC1 FCL.050 · flights only, no FSTD sessions · times UTC")
        static let pdfDisclaimer = String(localized: "Extract generated by AeroCheck from recorded flights. AeroCheck is not a logbook of record and is not a FOCA-accepted digital logbook: check every entry against your own records before signing or submitting it.")
    }

    // MARK: - Flight cost (v5.0.0)
    enum Cost {
        static let title = String(localized: "Flight cost")
        /// The sheet that holds the cost, the logbook line and mass & balance. Named after all
        /// three, since the logbook is what a pilot most often comes for. (v5.x)
        static let afterTheFlight = String(localized: "Logbook & costs")
        static let basisBlock = String(localized: "Block time")
        static let basisFlight = String(localized: "Flight time")
        static let basisEngineHours = String(localized: "Engine hours")
        static let hourlyRate = String(localized: "Hourly rate")
        static let billingBasis = String(localized: "Billed on")
        static let currency = String(localized: "Currency")
        static let addFee = String(localized: "Add fee")
        static let feeLabel = String(localized: "What for")
        static let feeAmount = String(localized: "Amount")
        static let total = String(localized: "Total")
        static let noRateSet = String(localized: "No hourly rate set for this aircraft")
        static let setRate = String(localized: "Set a rate")
        static let notRecorded = String(localized: "No cost recorded")
        static func missingCost(_ count: Int) -> String {
            String(localized: "\(count) flights without a recorded cost")
        }
        static let ledgerTitle = String(localized: "Spend")
        static let openTariff = String(localized: "Operator's tariff")
        static let rateProfiles = String(localized: "Aircraft rates")
        static let rateProfilesHint = String(localized: "Your club's hourly rate per aircraft, and the time it bills on")
    }

    // MARK: - Mass & balance (v5.0.0)
    enum WeightBalance {
        static let title = String(localized: "Mass & balance")
        static let emptyWeight = String(localized: "Empty mass")
        static let emptyArm = String(localized: "Empty arm")
        static let mtow = String(localized: "MTOM")
        static let stations = String(localized: "Stations")
        static let addStation = String(localized: "Add station")
        static let stationName = String(localized: "Station")
        static let arm = String(localized: "Arm")
        static let totalWeight = String(localized: "Total mass")
        static let centreOfGravity = String(localized: "CG")
        static let insideEnvelope = String(localized: "Inside the envelope")
        static let outsideEnvelope = String(localized: "OUTSIDE the envelope")
        static let envelopeUnknown = String(localized: "No envelope entered: mass and CG only")
        static let overweight = String(localized: "OVER MTOM")
        // review F22 / F23 — an incomplete load sheet and the landing case.
        static let incomplete = String(localized: "Some stations have no mass, so this is not a valid check")
        static func stationsUnset(_ names: String) -> String {
            String(localized: "No mass entered for: \(names)")
        }
        static let fuelBurn = String(localized: "Fuel burn")
        static let fuelStation = String(localized: "Fuel station")
        static let takeoffCase = String(localized: "TAKE-OFF")
        static let landingCase = String(localized: "LANDING")
        static let landingOutside = String(localized: "OUTSIDE the envelope at landing")
        static let remainingPayload = String(localized: "Remaining payload")
        static let notConfigured = String(localized: "Enter this aircraft's figures to use the calculator")
        static let setup = String(localized: "Set up this aircraft")
        static let advisory = String(localized: "Advisory only: check against the load sheet and the AFM")
        static let fromWeighingReport = String(localized: "These figures come from the aircraft's weighing report and AFM. The app does not include them.")
        static let envelope = String(localized: "Envelope")
        static let addEnvelopePoint = String(localized: "Add envelope point")
        static let envelopeHint = String(localized: "Corners of the AFM envelope, in order around it")
    }

    // MARK: - Flight Thread (v5.0.0)
    // Literal-keyed strings: English renders immediately; FR translations are added in the
    // localization pass (xcstrings), like the other newer UI strings in this file.
    enum Thread {
        static let title = String(localized: "Flight")
        static let followFlight = String(localized: "Follow this flight")
        static let untitledFlight = String(localized: "Untitled flight")
        static let noThread = String(localized: "Not followed")
        static let circuitCloseOutOffer = String(localized: "Log the session and write a debrief?")
        static let circuitCloseOutAccept = String(localized: "Close out")

        // Chapters
        static let chapterPlan = String(localized: "Plan")
        static let chapterPrepare = String(localized: "Prepare")
        static let chapterFly = String(localized: "Fly")
        static let chapterClose = String(localized: "Close")
        static let chapterFlyDetail = String(localized: "16 phases · checklist, nav and briefings")
        static let startNow = String(localized: "thread.startNow")
        static let startEarlyTitle = String(localized: "thread.startEarlyTitle")
        static func plannedFor(_ when: String) -> String {
            String(format: String(localized: "thread.plannedFor"), when)
        }
        static func startEarlyMessage(_ when: String) -> String {
            String(format: String(localized: "thread.startEarlyMessage"), when)
        }
        /// In FLY's card while another flight is running, where its start button would be. (6.2.0)
        static let flightInProgress = String(localized: "thread.flightInProgress")
        /// "Flight in progress (F-HVXA)"
        static func flightInProgress(aircraft registration: String) -> String {
            String(format: String(localized: "thread.flightInProgressAircraft"), registration)
        }
        static let endBeforeStarting = String(localized: "thread.endBeforeStarting")

        // States
        static let statePlanned = String(localized: "PLANNED")
        static let stateReady = String(localized: "READY")
        static let stateFlying = String(localized: "IN FLIGHT")
        static let stateCloseOut = String(localized: "CLOSE-OUT")
        static let stateDone = String(localized: "DONE")

        // Task titles
        static let taskRoute = String(localized: "Route planned")
        static let taskFuel = String(localized: "Fuel plan")
        static let taskMassBalance = String(localized: "Mass & balance")
        static let taskReservation = String(localized: "Aircraft reserved")
        static let taskWeather = String(localized: "Weather briefed")
        static let taskNotam = String(localized: "NOTAMs checked")
        /// A country's airspace activity and area forecast, one task each: "Airspace activity CH". (6.5.0)
        static func taskAirspace(_ country: String) -> String {
            String(format: String(localized: "thread.task.airspace"), country)
        }
        static func taskForecast(_ country: String) -> String {
            String(format: String(localized: "thread.task.forecast"), country)
        }
        static let taskFlightPlanFiled = String(localized: "Flight plan filed")
        static let taskNavLog = String(localized: "Nav log ready")
        static let taskFlightPlanClose = String(localized: "Close the flight plan")
        static let taskLogbook = String(localized: "Logbook entry")
        static let taskDebrief = String(localized: "Debrief")
        static let debriefOptional = String(localized: "thread.debrief.optional")
        static let debriefPlaceholder = String(localized: "thread.debrief.placeholder")
        static func taskPPR(_ ident: String) -> String { String(localized: "PPR: \(ident)") }
        static func taskCustoms(_ country: String) -> String { String(localized: "Border crossing: \(country)") }
        static func taskFees(_ ident: String) -> String { String(localized: "Fees: \(ident)") }

        // Task subtitles
        static let hintFuel = String(localized: "REQ = trip + alternate + 45-min final reserve + extra. FOB = what you plan to carry.")
        static let hintMassBalance = String(localized: "Check the load sheet against the envelope in the POH")
        /// A page by day, said for this flight's day only (the author's v65-2, 22 Oct 2026): "DABS for today.",
        /// "DABS for tomorrow.", "Tomorrow's DABS comes out today at 16:00.", "The DABS for Saturday 24 October comes out
        /// on Friday 23 October at 16:00." (6.5.0)
        static func byDayToday(_ name: String) -> String {
            String(format: String(localized: "thread.byDay.today"), name)
        }
        static func byDayTomorrow(_ name: String) -> String {
            String(format: String(localized: "thread.byDay.tomorrow"), name)
        }
        static func byDayLaterToday(_ name: String, at time: String) -> String {
            String(format: String(localized: "thread.byDay.laterToday"), name, time)
        }
        static func byDayLater(_ name: String, for flightDay: String, on publishDay: String, at time: String) -> String {
            String(format: String(localized: "thread.byDay.later"), name, flightDay, publishDay, time)
        }
        static let hintFlightPlanFiled = String(localized: "thread.hint.flightPlanFiled")
        /// A plan filed from a field without ATS, in a country that wants the pilot to activate it. (6.5.0)
        static func activateWithoutATS(_ ident: String) -> String {
            String(format: String(localized: "thread.activation"), ident)
        }
        /// A route through a country whose airspace is closed. (6.5.0)
        static func prohibitedTitle(_ country: String) -> String {
            String(format: String(localized: "thread.prohibited.title"), country)
        }
        static let prohibitedHint = String(localized: "thread.prohibited.hint")
        static let hintReservation = String(localized: "Booked with your club")
        static let hintNavLog = String(localized: "Exported or printed for the cockpit")
        static let hintPPR = String(localized: "Prior permission required: call ahead")

        // Actions
        static let markDone = String(localized: "Mark done")
        static let markNotApplicable = String(localized: "Not applicable")
        // What a briefing link takes, under its name. (6.5.0)
        static let accessAccount = String(localized: "thread.access.account")
        static let accessPaid = String(localized: "thread.access.paid")
        static let accessRestricted = String(localized: "thread.access.restricted")
        static let linkGeneral = String(localized: "thread.link.general")
        /// What a weather block's link gives, beside its country: "Weather", "Area forecast", both. (6.5.0)
        static let linkWeather = String(localized: "thread.link.weather")
        static let linkForecast = String(localized: "thread.link.forecast")
        /// The weather block (6.5.0, v65-1): its links' heading, its folded line, and the NEXT card pointing to it.
        static let briefOfficially = String(localized: "thread.weather.briefOfficially")
        static func weatherBriefedAt(_ time: String) -> String {
            String(format: String(localized: "thread.weather.briefedAt"), time)
        }
        static let weatherNotTicked = String(localized: "thread.weather.notTicked")
        static let weatherBelow = String(localized: "thread.weather.below")
        static let exportNavLog = String(localized: "Export nav log")
        static let editRoute = String(localized: "View route")
        static let markFlightPlanClosed = String(localized: "Mark closed")
        static let finishThread = String(localized: "Finish")
        /// "Thread" is our internal word for it; a pilot cancels a flight.
        static let deleteThread = String(localized: "Cancel flight")
        static let cancelConfirmTitle = String(localized: "thread.cancelConfirm.title")
        static let cancelConfirmMessage = String(localized: "thread.cancelConfirm.message")
        static let keepFlight = String(localized: "thread.cancelConfirm.keep")

        // Readiness
        static func readiness(_ done: Int, _ total: Int) -> String {
            String(localized: "\(done) of \(total) done")
        }
        /// After the flight: "3 of 4 closed". (v6.0 · D3)
        static func closedProgress(_ done: Int, _ total: Int) -> String {
            String(localized: "\(done) of \(total) closed")
        }
        /// A chapter's ticked tasks, folded into one row. (v6.0 · D3)
        static func doneCount(_ count: Int) -> String { String(localized: "\(count) done") }
        static let nextUp = String(localized: "Next")
        static let allDone = String(localized: "Everything done")

        // Notifications
        static let closeFlightPlanTitle = String(localized: "Close your flight plan")
        /// The route, then the close-out's rule for the country landed in. (6.5.0)
        static func closeFlightPlanBody(_ route: String, rule: String) -> String {
            String(format: String(localized: "thread.closeFlightPlan.body"), route, rule)
        }
        static let prepareReminderTitle = String(localized: "Flight tomorrow")
        static func prepareReminderBody(_ route: String) -> String {
            String(localized: "\(route): time to check the weather, the airspace activity and any PPR.")
        }

        // Banner
        static let openFlightPlanBanner = String(localized: "Flight plan not marked closed")
    }

    // MARK: - Download and import errors, in the app's language (6.5.0, q8)
    enum DataErrors {
        static func invalidJSON(_ detail: String) -> String {
            String(format: String(localized: "error.import.json"), detail)
        }
        static let invalidGPX = String(localized: "error.import.gpx")
        static let invalidCoordinates = String(localized: "error.import.coordinates")
        static let invalidURL = String(localized: "error.download.invalidURL")
        static func http(_ status: Int) -> String { String(format: String(localized: "error.download.http"), status) }
        static let unreadable = String(localized: "error.download.unreadable")
        static let hostNotAllowed = String(localized: "error.download.hostNotAllowed")
        static func tooLarge(_ bytes: Int) -> String { String(format: String(localized: "error.download.tooLarge"), bytes) }
        static let checksum = String(localized: "error.download.checksum")
        static func wrongCountry(_ country: String) -> String {
            String(format: String(localized: "error.download.wrongCountry"), country)
        }
    }

    // MARK: - Closing a flight plan, by country (6.5.0)
    enum CloseOut {
        static func ruleAlert(_ country: String, minutes: Int) -> String {
            String(format: String(localized: "closeOut.rule.alert"), country, minutes)
        }
        static func ruleReport(_ country: String, minutes: Int) -> String {
            String(format: String(localized: "closeOut.rule.report"), country, minutes)
        }
        static func ruleReportTo(_ country: String, _ unit: String) -> String {
            String(format: String(localized: "closeOut.rule.reportTo"), country, unit)
        }
        static func ruleNoDelay(_ country: String) -> String {
            String(format: String(localized: "closeOut.rule.noDelay"), country)
        }
        static let ruleUnknown = String(localized: "closeOut.rule.unknown")
        static let atsSera = String(localized: "closeOut.ats.sera")
        static let atsControlled = String(localized: "closeOut.ats.controlled")
        static func notControlled(_ aerodrome: String) -> String {
            String(format: String(localized: "closeOut.ats.notControlled"), aerodrome)
        }
        static let atsATSU = String(localized: "closeOut.ats.atsu")
        static let atsReport = String(localized: "closeOut.ats.report")
        /// "Call skyguide ARO".
        static func call(_ unit: String) -> String { String(format: String(localized: "closeOut.call"), unit) }
    }

    // MARK: - Prepare's weather (6.5.0)
    enum PrepareWeather {
        static let title = String(localized: "prepareWeather.title")
        static let departure = String(localized: "prepareWeather.role.departure")
        static let destination = String(localized: "prepareWeather.role.destination")
        static let alternate = String(localized: "prepareWeather.role.alternate")
        static let nearest = String(localized: "prepareWeather.role.nearest")
        /// "No METAR or TAF · nearest LFSB, 19 NM".
        static func noMetarOrTaf(nearest: String, distanceNm: Int) -> String {
            String(format: String(localized: "prepareWeather.noMetarOrTaf"), nearest, distanceNm)
        }
        static func noTaf(nearest: String, distanceNm: Int) -> String {
            String(format: String(localized: "prepareWeather.noTaf"), nearest, distanceNm)
        }
        static let nothingWithin = String(localized: "prepareWeather.nothingWithin")
        static let noTafWithin = String(localized: "prepareWeather.noTafWithin")
        static let noMetar = String(localized: "prepareWeather.noMetar")
        /// After a nearest station whose row is higher up the card.
        static let above = String(localized: "prepareWeather.above")
        static func noSigmetAlongRoute(_ received: Int) -> String {
            String(localized: "No SIGMET along the route · \(received) received")
        }
        static let noSigmetReceived = String(localized: "prepareWeather.noSigmetReceived")
        static let sigmetFailed = String(localized: "prepareWeather.sigmetFailed")
        static let sigmetsAlongRoute = String(localized: "prepareWeather.sigmetsAlongRoute")
        static let source = String(localized: "prepareWeather.source")
        static let loading = String(localized: "prepareWeather.loading")
        static let failed = String(localized: "prepareWeather.failed")
        /// A refresh that failed with reports on the card: they stay, with their time. (6.5.0, the author's v65-18)
        static func refreshFailed(_ time: String) -> String {
            String(format: String(localized: "prepareWeather.refreshFailed"), time)
        }
        static let refresh = String(localized: "prepareWeather.refresh")
    }

    // MARK: - Home
    enum Home {
        static let flightInfo = String(localized: "home.flightInfo")
        static let lastFlight = String(localized: "home.lastFlight")
        static let flightPlan = String(localized: "home.flightPlan")
        /// Chip on the Home flight-plan strip when a plan is activated. Deliberately not "ACTIVE":
        /// that word is already the plan list's badge for the same state, and this one has to read as
        /// "ready to fly" at a glance on a card that also has a "departing today" state. (v4.4.0)
        static let flightPlanArmed = String(localized: "home.flightPlanArmed")
        static let outstandingTitle = String(localized: "Not everything is ticked")
        // START FLIGHT with another day's flight on the map (v6.0 review)
        static let otherDayTitle = String(localized: "home.otherDayTitle")
        static func otherDayMessage(_ flight: String, _ when: String) -> String {
            String(format: String(localized: "home.otherDayMessage"), flight, when)
        }
        static func undatedMessage(_ flight: String) -> String {
            String(format: String(localized: "home.undatedMessage"), flight)
        }
        static let flyItNow = String(localized: "home.flyItNow")
        static let startSeparateFlight = String(localized: "home.startSeparateFlight")
        static func outstandingBeforeFlight(_ route: String, _ remaining: Int) -> String {
            String(localized: "\(route) still has \(remaining) item(s) open in Plan and Prepare.")
        }
        static let reviewFlightFirst = String(localized: "Review the flight")
        static let startAnyway = String(localized: "Start anyway")
        static let startThisFlight = String(localized: "Start this flight")
        static let resumeThisFlight = String(localized: "Resume this flight")
        static let reviewFlight = String(localized: "Review")
        static let flyWithoutAPlan = String(localized: "Fly without a plan")
        static let today = String(localized: "Today")
        static let readyToFly = String(localized: "Everything ticked, ready to fly")
        static func nextOnly(_ task: String) -> String {
            String(localized: "Next: \(task)")
        }
        static func nextAndRemaining(_ task: String, _ remaining: Int) -> String {
            String(localized: "Next: \(task) · \(remaining) open in Plan and Prepare")
        }
        static func flightPlanWaypointCount(_ count: Int) -> String {
            String(format: String(localized: "home.flightPlanWaypointCount"), count)
        }
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
        /// The permission's state in Settings › GPS, under the row's own "GPS Status". (6.3.2)
        static let statusDenied = String(localized: "gps.status.denied")
        static let statusRestricted = String(localized: "gps.status.restricted")
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
        /// The "Simulate position" developer option is on: real GPS is ignored. (S9-25)
        static let simulatedPosition = String(localized: "gps.simulatedPosition")
        static let points = String(localized: "gps.points")
        static let pointsRecorded = String(localized: "gps.pointsRecorded")
        // The GPS Status drawer: why the signal is degraded or lost, and the fix tiles (6.2: English
        // in French until then).
        static func reasonReducedAccuracy(_ metres: Int) -> String {
            String(format: String(localized: "gps.reason.reducedAccuracy"), metres)
        }
        static func reasonNoUpdate(_ seconds: Int) -> String {
            String(format: String(localized: "gps.reason.noUpdate"), seconds)
        }
        static func reasonNetworkPosition(_ metres: Int) -> String {
            String(format: String(localized: "gps.reason.networkPosition"), metres)
        }
        static let reasonWeakSignal = String(localized: "gps.reason.weakSignal")
        static let reasonNoFix = String(localized: "gps.reason.noFix")
        static let fixAccuracy = String(localized: "gps.fix.accuracy")
        static let fixVertical = String(localized: "gps.fix.vertical")
        static let fixTime = String(localized: "gps.fix.time")
        static let fixAltitude = String(localized: "gps.fix.altitudeMSL")
        static let fixPosition = String(localized: "gps.fix.position")

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

        /// "4 mo ago", "in 3 hr"; "il y a 4 m.", "dans 3 h". One style for every relative time: the
        /// abbreviated one is CLDR's narrow form, which French writes "-4 m." and "-13 s". (6.2)
        static func relative(_ date: Date, to now: Date = Date()) -> String {
            relativeFormatter.localizedString(for: date, relativeTo: now)
        }
        static func makeRelativeFormatter(locale: Locale) -> RelativeDateTimeFormatter {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            formatter.locale = locale
            return formatter
        }
        private static let relativeFormatter = makeRelativeFormatter(locale: .current)
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
        static let checklistNotReady = String(localized: "alert.checklistNotReady.message")
        static let cannotStartFlightTitle = String(localized: "alert.cannotStartFlight.title")
        static let proNotActiveTitle = String(localized: "alert.proNotActive.title")
        static func proNotActive(_ registration: String) -> String {
            String(format: String(localized: "alert.proNotActive.message"), registration)
        }
        static func checklistUnreachable(_ registration: String) -> String {
            String(format: String(localized: "alert.checklistUnreachable.message"), registration)
        }
        static let seePlans = String(localized: "alert.proNotActive.seePlans")
        /// START FLIGHT with location off for the app: fly without a position, or Settings. (6.3.2)
        static let locationOffTitle = String(localized: "alert.locationOff.title")
        static let locationOffMessage = String(localized: "alert.locationOff.message")
        static let startWithoutGPS = String(localized: "alert.locationOff.startWithoutGPS")
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

        /// The check slot's word on the iPhone, one line in a slot about 90 pt wide: the check's name
        /// without CHECK, "CRUISE", "CROISIÈRE". (6.2.0, device check 11 Oct)
        enum Word {
            static let preflight = String(localized: "phase.word.preflight")
            static let beforeEngineStart = String(localized: "phase.word.beforeEngineStart")
            static let engineStart = String(localized: "phase.word.engineStart")
            static let afterEngineStart = String(localized: "phase.word.afterEngineStart")
            static let taxi = String(localized: "phase.word.taxi")
            static let runup = String(localized: "phase.word.runup")
            static let beforeDeparture = String(localized: "phase.word.beforeDeparture")
            static let lineUp = String(localized: "phase.word.lineUp")
            static let climb = String(localized: "phase.word.climb")
            static let cruise = String(localized: "phase.word.cruise")
            static let descent = String(localized: "phase.word.descent")
            static let approach = String(localized: "phase.word.approach")
            static let landing = String(localized: "phase.word.landing")
            static let afterLanding = String(localized: "phase.word.afterLanding")
            static let shutdown = String(localized: "phase.word.shutdown")
            static let hangar = String(localized: "phase.word.hangar")
        }

        static func completed(_ phase: String) -> String {
            String(format: String(localized: "phase.completed"), phase)
        }
    }

    // MARK: - Briefing
    enum Briefing {
        /// Provenance qualifier when the briefing wind came from the model rather than a station.
        static let windModelForecast = String(localized: "briefing.wind.modelForecast")
        /// VoiceOver label for the raw TAF, which is unreadable letter-by-letter.
        static func tafAccessibility(_ icao: String) -> String {
            String(format: String(localized: "briefing.taf.accessibility"), icao)
        }
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
        // A US destination's traffic pattern (6.5.0)
        static let trafficPattern = String(localized: "briefing.trafficPattern")
        static func patternTraffic(_ side: NASRPatterns.Side) -> String {
            String(localized: side == .right ? "briefing.pattern.right" : "briefing.pattern.left")
        }
        static func patternAltitude(msl: Int, agl: Int) -> String {
            String(format: String(localized: "briefing.tpa.value"), msl, agl)
        }
        static func patternAltitudeAGL(_ agl: Int) -> String { String(format: String(localized: "briefing.tpa.agl"), agl) }
        static let patternSeeRemark = String(localized: "briefing.tpa.seeRemark")
        static func patternRecommended(_ agl: Int) -> String {
            String(format: String(localized: "briefing.tpa.recommended"), agl)
        }
        static let asWrittenByFAA = String(localized: "briefing.tpa.asWritten")
        static let checkChartSupplement = String(localized: "briefing.checkChartSupplement")
        static let wind = String(localized: "briefing.wind")
        static let runway = String(localized: "briefing.runway")
        static let notDetected = String(localized: "briefing.notDetected")
        static let notAvailable = String(localized: "briefing.notAvailable")
        static let goAroundProcedure = String(localized: "briefing.goAround.procedure")

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

        // Flight Planning
        static let flightPlanning = String(localized: "settings.flightPlanning")
        static let sunlightBoost = String(localized: "High contrast in sunlight")
        static let sunlightBoostFooter = String(localized: "Switches to the high-contrast palette when the screen is near full brightness. The app can't measure ambient light, so it goes by the screen brightness.")
        static let pilot = String(localized: "Pilot")
        static let pilotName = String(localized: "Your name")
        static let pilotNamePlaceholder = String(localized: "Name as it appears in your logbook")
        static let studentPilot = String(localized: "Student pilot")
        static let studentPilotSubtitle = String(localized: "Log flights as dual, with your instructor as PIC")
        static let instructorNamePlaceholder = String(localized: "Instructor's name")
        static let pilotNameFooter = String(localized: "Used for the PIC column and for the holder's name on the logbook PDF.")
        static let costTracking = String(localized: "Track flight costs")
        static let costTrackingFooter = String(localized: "Off hides the landing-fee tasks. Your logbook line is unaffected.")
        static let terrainAltitudeUnit = String(localized: "settings.flightPlanning.terrainAltitudeUnit")
        static let flightPlanningFooter = String(localized: "settings.flightPlanning.planFlightRoutes")
        static let terrainUnitFooter = String(localized: "settings.flightPlanning.terrainUnitDesc")

        // Display
        static let display = String(localized: "settings.display")
        static let alwaysUseUTC = String(localized: "settings.display.alwaysUseUTC")
        static let alwaysUseUTCFooter = String(localized: "settings.display.alwaysUseUTCDesc")
        // Cockpit theme (v4 UI/UX Revamp — replaces the night-mode picker; sunlight now selectable)
        static let theme = String(localized: "settings.display.theme")
        static let themeFooter = String(localized: "settings.display.themeDesc")
        static let themeAuto = String(localized: "settings.display.theme.auto")
        static let themeDay = String(localized: "settings.display.theme.day")
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
        /// What "Sync to iCloud" off means now that it covers iCloud Drive too.
        static let icloudOffFooter = String(localized: "settings.icloud.offKeepsLocal")

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
        /// Under Download data while a layer is still downloading: "Still downloading: Airspace, Obstacles." (6.5.0)
        static func stillDownloading(_ layers: String) -> String {
            String(format: String(localized: "settings.openAIP.stillDownloading"), layers)
        }
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
        static let downloadingTiles = String(localized: "settings.openAIP.downloadingTiles")
        static let download = String(localized: "settings.openAIP.download")
        static let downloadAll = String(localized: "settings.openAIP.downloadAll")
        static let downloadAirspaceOnly = String(localized: "settings.openAIP.downloadAirspaceOnly")
        static let downloadWithTiles = String(localized: "Download data + map tiles")   // v4.1.0 (literal-keyed; FR in pass)
        static let openAIPDownloadHint = String(localized: "Data (airspace, navaids, obstacles, reporting points, airports) is small. Map tiles add raster chart imagery and are much larger.")
        /// Under the selection: the countries that also get open flightmaps' circuits and VFR routes. (6.2.0)
        static func vfrProceduresIncluded(_ countries: String) -> String {
            String(localized: "VFR procedures (open flightmaps): \(countries)")
        }
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
        /// On = memorisable checks hidden (`AppSettings.learningMode` off). (v6.0 · A7)
        static let memoryTest = String(localized: "settings.checklist.memoryTest")
        static let memoryTestOnboarding = String(localized: "settings.checklist.memoryTestOnboarding")
        static let memoryTestFooter = String(localized: "settings.checklist.memoryTestFooter")

        // Flight Logging
        static let flightLogging = String(localized: "settings.flightLogging")
        static let logEngineHours = String(localized: "settings.flightLogging.logEngineHours")
        static let logEngineHoursFooter = String(localized: "settings.flightLogging.logEngineHoursFooter")
        static let confirmFlightEvents = String(localized: "settings.flightLogging.confirmFlightEvents")
        static let confirmFlightEventsFooter = String(localized: "settings.flightLogging.confirmFlightEventsFooter")
        /// The radio's settings: the aerodromes on the way (q7). (6.4.2)
        static let radio = String(localized: "settings.radio")
        static let fieldsOnTheWay = String(localized: "settings.radio.fieldsOnTheWay")
        static let fieldsOnTheWayFooter = String(localized: "settings.radio.fieldsOnTheWayFooter")

        // Checklist Language
        static let checklistLanguage = String(localized: "settings.checklistLanguage")
        static let checklistLanguageFooter = String(localized: "settings.checklistLanguage.footer")
        static let checklistLanguageAuto = String(localized: "settings.checklistLanguage.auto")

        // About
        static let about = String(localized: "settings.about")
        static let appVersion = String(localized: "settings.about.appVersion")
        static let website = String(localized: "settings.about.website")

        // Legal (About → Legal)
        static let legal = String(localized: "settings.legal")
        static let legalFooter = String(localized: "settings.legal.footer")
        static let safetyNotice = String(localized: "settings.legal.safetyNotice")
        static let safetyNoticeSubtitle = String(localized: "settings.legal.safetyNoticeSubtitle")
        static let termsOfUse = String(localized: "settings.legal.termsOfUse")
        static let privacyPolicy = String(localized: "settings.legal.privacyPolicy")
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
        static let navigationTitle = String(localized: "onboarding.navigation.title")
        static let downloadAirports = String(localized: "onboarding.navigation.downloadAirports")
        static let downloadCharts = String(localized: "onboarding.navigation.downloadCharts")
        static let downloading = String(localized: "onboarding.navigation.downloading")
        static let downloaded = String(localized: "onboarding.navigation.downloaded")
        static let readyTitle = String(localized: "onboarding.ready.title")
        static let readyBody = String(localized: "onboarding.ready.body")
        static let readyButton = String(localized: "onboarding.ready.button")
        static let skip = String(localized: "onboarding.skip")
        static let getStarted = String(localized: "onboarding.getStarted")
        static let next = String(localized: "onboarding.next")
        /// Under the location step's reasons, while iOS has yet to ask. (6.3.2)
        static let locationNext = String(localized: "onboarding.location.next")
    }

    // MARK: - Safety notice
    enum Disclaimer {
        static let title = String(localized: "disclaimer.title")
        static let intro = String(localized: "disclaimer.intro")
        static let notCertifiedTitle = String(localized: "disclaimer.notCertified.title")
        static let notCertifiedBody = String(localized: "disclaimer.notCertified.body")
        static let checklistTitle = String(localized: "disclaimer.checklist.title")
        static let checklistBody = String(localized: "disclaimer.checklist.body")
        static let dataTitle = String(localized: "disclaimer.data.title")
        static let dataBody = String(localized: "disclaimer.data.body")
        static let pilotTitle = String(localized: "disclaimer.pilot.title")
        static let pilotBody = String(localized: "disclaimer.pilot.body")
        static let readTerms = String(localized: "disclaimer.readTerms")
        static let asIs = String(localized: "disclaimer.asIs")
        static let accept = String(localized: "disclaimer.accept")
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
        static let preparingExport = String(localized: "flightLog.preparingExport")
        static let importFlights = String(localized: "flightLog.import")
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
        /// The year menu, closed, when no year is picked: "All". (6.2)
        static let allYears = String(localized: "flightLog.allYears")
        /// A row's landings: "3 ldg". `String(format:)` keeps the number ungrouped, like the distance beside it.
        static func landingCount(_ count: Int) -> String {
            String(format: String(localized: "flightLog.landingCount"), count)
        }
        // Naming a flight just imported (v6.1)
        static let nameImportedTitle = String(localized: "flightLog.nameImported.title")
        static func nameImportedMessage(_ title: String) -> String {
            String(format: String(localized: "flightLog.nameImported.message"), title)
        }
        static let nameImportedSave = String(localized: "flightLog.nameImported.save")
        static let nameImportedSkip = String(localized: "flightLog.nameImported.skip")

        // The dashboard and the list (6.2: English in French until then)
        static let hours = String(localized: "Hours", comment: "Logbook metric card: the hours flown in the period.")
        static let flights = String(localized: "Flights")
        static let landings = String(localized: "Landings", comment: "Logbook metric card: the landings in the period.")
        static let filter = String(localized: "Filter", comment: "Logbook list: the aircraft filter, before an aircraft is picked.")
        /// Over the list: "1 FLIGHT", "12 FLIGHTS". The plural is the catalog's (`ShareCard.flightCount`).
        static func listHeader(_ count: Int) -> String { L10n.ShareCard.flightCount(count).uppercased() }
        /// A month's line: "1 flight · 1.9 h".
        static func monthSummary(_ count: Int, hours: Double) -> String {
            "\(L10n.ShareCard.flightCount(count)) · \(String(format: "%.1f", hours)) h"
        }
    }

    // MARK: - Flight titles, read aloud (v6.1)
    enum FlightTitle {
        /// What VoiceOver says for the "?" end of a route.
        static let unknownAerodrome = String(localized: "flightTitle.unknownAerodrome")
        /// "LSZQ to LSGE", for VoiceOver.
        static func spokenRoute(_ departure: String, _ arrival: String) -> String {
            String(format: String(localized: "flightTitle.spokenRoute"), departure, arrival)
        }
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
        static let termsOfUse = String(localized: "subscription.termsOfUse")
        static let privacyPolicy = String(localized: "subscription.privacyPolicy")
        static let errorPending = String(localized: "subscription.error.pending")
        static let errorUnknownResult = String(localized: "subscription.error.unknownResult")
        static let errorPurchaseFailed = String(localized: "subscription.error.purchaseFailed")
        static let errorRestoreFailed = String(localized: "subscription.error.restoreFailed")
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
        /// "…, then <the yearly price> per year": the trial with what it turns into. (6.3.2)
        static func freeTrialNoteDays(_ days: Int, then yearlyPrice: String) -> String {
            String(format: String(localized: "subscription.freeTrialNoteDaysPrice"), days, yearlyPrice)
        }
        static let lifetimeTagline = String(localized: "subscription.lifetimeTagline")
        static let oneTime = String(localized: "subscription.oneTime")
    }

    // MARK: - Warnings
    enum Warning {
        static let experimentalFeature = String(localized: "warning.experimentalFeature")
        static let iUnderstandEnable = String(localized: "warning.iUnderstandEnable")
        static let cancel = String(localized: "warning.cancel")

        // Flight Planning

        // Online Airspace Streaming
        static let onlineAirspaceTitle = String(localized: "warning.onlineAirspace.title")
        static let onlineAirspaceRequiresInternet = String(localized: "warning.onlineAirspace.requiresInternet")
        static let onlineAirspaceFetches = String(localized: "warning.onlineAirspace.fetches")
        static let onlineAirspaceDownloadRecommended = String(localized: "warning.onlineAirspace.downloadRecommended")

        // Estimated Airspeed
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
    /// Strings spoken by VoiceOver rather than drawn on screen. Localised like any other user-facing
    /// copy — a French pilot running VoiceOver hears French.
    enum Accessibility {
        static let itemCompleted = String(localized: "a11y.item.completed")
        static let notRecorded = String(localized: "a11y.notRecorded")
        static let phaseCompleted = String(localized: "a11y.phase.completed")
        static let phaseSkipped = String(localized: "a11y.phase.skipped")
        static let phaseMissingAction = String(localized: "a11y.phase.missingAction")
        static let phaseNothingToDo = String(localized: "a11y.phase.nothingToDo")
        /// A memory check confirmed with one tap. (6.1)
        static let phaseDoneFromMemory = String(localized: "a11y.phase.doneFromMemory")
        static let phaseNotStarted = String(localized: "a11y.phase.notStarted")
        /// The cruise segment, amber: FREDA is due. (6.1)
        static let phaseFredaDue = String(localized: "a11y.phase.fredaDue")
        /// The current check, owed: the flight moved past it open. (6.1)
        static let phaseOwed = String(localized: "a11y.phase.owed")
        /// The landing check, "yes, it was done" on the landed card. (6.1)
        static let phaseConfirmedAfterLanding = String(localized: "a11y.phase.confirmedAfterLanding")
        /// The landing check, "not sure" on the landed card. (6.1)
        static let phaseNotSure = String(localized: "a11y.phase.notSure")
        static let previousPhase = String(localized: "a11y.previousPhase")
        static let nextPhase = String(localized: "a11y.nextPhase")
        static let gpsGood = String(localized: "a11y.gps.good")
        static let gpsDegraded = String(localized: "a11y.gps.degraded")
        static let gpsLost = String(localized: "a11y.gps.lost")
        static let gpsUnknown = String(localized: "a11y.gps.unknown")

        // The instruments' values: the Cockpit strip and the boxed instruments (6.2: English in French
        // until then). Their labels, "Ground speed", "Altitude" and "Heading", are keys in the views.
        /// The speed and the altitude read nothing else with the GPS lost.
        static let instrumentGPSLost = String(localized: "GPS signal lost")
        /// A phase without a target speed (taxi, run-up): "12 knots ground speed".
        static func groundSpeed(_ knots: Int) -> String {
            String(localized: "\(knots) knots ground speed")
        }
        /// "55 knots ground speed, on target. Target 55 knots": the state in words, never colour alone.
        static func groundSpeedOnTarget(_ knots: Int, target: Int) -> String {
            String(localized: "\(knots) knots ground speed, on target. Target \(target) knots")
        }
        static func groundSpeedOffTarget(_ knots: Int, target: Int) -> String {
            String(localized: "\(knots) knots ground speed, off target. Target \(target) knots")
        }
        /// "3500 feet M S L". Formatted apart, so the figure stays ungrouped as it always was: interpolated,
        /// `String(localized:)` writes "3'500" in a Swiss region.
        static func altitudeMSL(_ feet: Int) -> String {
            String(format: String(localized: "%lld feet M S L"), feet)
        }
        /// The GPS track under the strip's TRK: "270 degrees track".
        static func track(_ degrees: Int) -> String {
            String(localized: "\(degrees) degrees track")
        }
        /// No valid GPS course to read.
        static let trackUnknown = String(localized: "unknown")
    }

    enum ChecklistAction {
        static let notRecorded = String(localized: "a11y.notRecorded")
        static let engineStart = String(localized: "checklist.engineStart")
        static let started = String(localized: "checklist.started")
        /// The check before departure's NEXT, on the Cockpit, the map's check slot and the Companion. In
        /// the app's language, like the CHECK and NEXT it stands for. (6.2)
        static let readyForLineUp = String(localized: "checklist.readyForLineUp")
        /// READY FOR LINE UP in the iPhone's act band, on one line. (6.2.0)
        static let readyForLineUpShort = String(localized: "checklist.readyForLineUp.short")
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

        static func engineShutdown(language: String) -> String {
            localizedString(key: "checklist.engineShutdown", language: language, defaultValue: "ENGINE SHUTDOWN")
        }

        /// ENGINE START and ENGINE SHUTDOWN in the iPhone's act band, on one line: "START", "DÉMARRAGE".
        /// (6.2.0)
        static func engineStartShort(language: String) -> String {
            localizedString(key: "checklist.engineStart.short", language: language, defaultValue: "START")
        }

        static func engineShutdownShort(language: String) -> String {
            localizedString(key: "checklist.engineShutdown.short", language: language, defaultValue: "SHUTDOWN")
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
        /// The header chip over the landings: "LDG". (6.2)
        static let landingsChip = String(localized: "flightDetail.landingsChip")

        // Times
        static let sessionStart = String(localized: "flightDetail.sessionStart")
        static let engineStart = String(localized: "flightDetail.engineStart")
        static let takeoff = String(localized: "flightDetail.takeoff")
        static let landing = String(localized: "flightDetail.landing")
        /// The timeline's landings and go-arounds between the take-off and the last landing. (6.3.0)
        static let touchAndGo = String(localized: "flightDetail.touchAndGo")
        static let goAround = String(localized: "flightDetail.goAround")
        static let stopAndGo = String(localized: "flightDetail.stopAndGo")
        static let stop = String(localized: "flightDetail.stop")
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

        // The header, the track and the chart (6.2: English in French until then)
        static let time = String(localized: "flightDetail.time")
        static let timeline = String(localized: "TIMELINE")
        static let trackStart = String(localized: "flightDetail.trackStart")
        static let trackEnd = String(localized: "flightDetail.trackEnd")
        static let chartAltitude = String(localized: "Altitude")
        static let chartSpeed = String(localized: "Speed")

        // Name/Notes
        static let flightName = String(localized: "flightDetail.flightName")
        static let namePlaceholder = String(localized: "flightDetail.namePlaceholder")
        static let notes = String(localized: "flightDetail.notes")

        // Actions
        static let export = String(localized: "flightDetail.export")
    }

    // MARK: - Share card (6.1)
    // Literal-keyed, EN and FR by hand in the catalog. Units (ft, NM, km), UTC and the data sources'
    // names stay as they are.
    enum ShareCard {
        // The duration beside the title, named for what it is.
        static let flightTime = String(localized: "FLIGHT TIME")
        static let blockTime = String(localized: "BLOCK TIME")
        static let engineTime = String(localized: "ENGINE TIME")
        static let sessionTime = String(localized: "SESSION TIME")

        // The figures under the map and the row of times and counts.
        static let maxAltitude = String(localized: "MAX ALT")
        static let distance = String(localized: "DISTANCE")
        static let takeoff = String(localized: "TAKE-OFF")
        static let landing = String(localized: "LANDING")
        static func landings(_ count: Int) -> String {
            count == 1 ? String(localized: "LANDING") : String(localized: "LANDINGS")
        }
        static func touchAndGoes(_ count: Int) -> String {
            count == 1 ? String(localized: "TOUCH-AND-GO") : String(localized: "TOUCH-AND-GOES")
        }
        static func goArounds(_ count: Int) -> String {
            count == 1 ? String(localized: "GO-AROUND") : String(localized: "GO-AROUNDS")
        }
        static func stopAndGoes(_ count: Int) -> String {
            count == 1 ? String(localized: "STOP-AND-GO") : String(localized: "STOP-AND-GOES")
        }
        /// A full stop at another aerodrome, before the flight's last landing.
        static func stops(_ count: Int) -> String {
            count == 1 ? String(localized: "STOP") : String(localized: "STOPS")
        }
        static func peak(_ altitude: String) -> String { String(localized: "PEAK \(altitude)") }

        // The tuned card (6.1): its tiles, its row of times and the note under it.
        static let maxAltitudeTile = String(localized: "MAX ALTITUDE")
        static let maxGroundSpeed = String(localized: "MAX GROUND SPEED")
        static let blockOff = String(localized: "OFF-BLOCK")
        static let blockOn = String(localized: "ON-BLOCK")
        /// Under the row of times: "Local time · UTC+2".
        static func localTimeNote(_ offset: String) -> String {
            String(localized: "Local time · \(offset)", comment: "Under the times on the flight share card; the argument is the offset, UTC+2.")
        }
        static let timesInUTC = String(localized: "Times in UTC")
        /// Under the take-off to landing span of the Full map style.
        static let localTimeLabel = String(localized: "LOCAL TIME")

        // The map.
        static let mapUnavailable = String(localized: "Map unavailable (offline?)")
        static let creditChart = String(localized: "Chart © swisstopo / BAZL")
        static let creditImagery = String(localized: "Imagery © swisstopo")
        static let creditAppleMaps = String(localized: "Map: Apple Maps")
        static let creditTerrainSwisstopo = String(localized: "Terrain © swisstopo")
        static let creditTerrainOpenMeteo = String(localized: "Elevation: Open-Meteo")
        /// A circuit or a short local flight, drawn on the national map instead of an aviation chart.
        static let creditNationalMap = String(localized: "National map © swisstopo")

        // The customisation sheet.
        static let themeLight = String(localized: "Light", comment: "A colour theme of the flight share card.")
        static let themeAviation = String(localized: "Aviation", comment: "A colour theme of the flight share card (aviation blue).")
        static let themeNavy = String(localized: "Navy", comment: "A colour theme of the flight share card (navy blue).")
        static let themeDark = String(localized: "Dark", comment: "A colour theme of the flight share card (black).")
        static let gliderChart = String(localized: "Glider chart")
        static let style = String(localized: "STYLE", comment: "Share card sheet: the card's look, Standard or Full map.")
        static let styleStandard = String(localized: "Standard", comment: "Share card style: the tuned card.")
        static let styleFullMap = String(localized: "Full map", comment: "Share card style: the chart edge to edge.")
        static let format = String(localized: "FORMAT", comment: "Share card sheet: 9:16 or 4:5.")
        static let formatStory = String(localized: "Story, 9:16")
        static let formatFeed = String(localized: "Feed post, 4:5")
        static let hideParking = String(localized: "Hide where I parked")
        static let hideParkingHint = String(localized: "Leaves out the track's first and last 300 m")
        /// Under the map styles when an aviation chart gives way to the national map.
        static let nationalMapNote = String(localized: "Short flight: drawn on the national map, sharper at this scale")
        /// Under the map styles when the ICAO chart gives way to the glider chart.
        static let gliderChartNote = String(localized: "Drawn on the glider chart, sharper at this scale")

        // The Logbook's stats sheet (6.2: English in French until then). Its section labels, toggles,
        // accents and layouts took a `String`, which `Text` shows as it is, so the lookup happens here.
        static let shareStats = String(localized: "Share Stats")
        static let colorTheme = String(localized: "COLOUR THEME")
        static let accent = String(localized: "ACCENT", comment: "Logbook stats sheet: the card's accent colour.")
        static let accentGold = String(localized: "Gold", comment: "An accent colour of the Logbook stats card.")
        static let accentBlue = String(localized: "Blue", comment: "An accent colour of the Logbook stats card.")
        static let accentGreen = String(localized: "Green", comment: "An accent colour of the Logbook stats card.")
        static let accentOrange = String(localized: "Orange", comment: "An accent colour of the Logbook stats card.")
        static let accentRed = String(localized: "Red", comment: "An accent colour of the Logbook stats card.")
        static let layout = String(localized: "LAYOUT", comment: "Logbook stats sheet: Tiles or Hero.")
        static let layoutTiles = String(localized: "Tiles", comment: "Logbook stats card layout: four equal tiles in a row.")
        static let layoutHero = String(localized: "Hero", comment: "Logbook stats card layout: the hours in big, then three smaller tiles.")
        static let content = String(localized: "CONTENT", comment: "Logbook stats sheet: what the card shows.")
        static let showHoursByAircraft = String(localized: "Hours by aircraft", comment: "Logbook stats sheet: a toggle for the card's hours per aircraft.")
        static let showPeriodTitle = String(localized: "Period title", comment: "Logbook stats sheet: a toggle for the period under the card's title, 2026 or All time.")

        // The journey card (6.1): a day of the Logbook or a trip's legs on one card.
        /// "3 flights", "1 flight": a day with circuits or a local flight in it, and the Logbook's day
        /// header, list header and month lines. A plural in the catalog, in both languages.
        static func flightCount(_ count: Int) -> String { String(localized: "\(count) flights") }
        /// The Logbook's day header: "1:26 flying".
        static func flying(_ duration: String) -> String {
            String(localized: "\(duration) flying", comment: "Logbook day header: the day's flight time, 1:26.")
        }
        /// A leg recorded without a track.
        static let noTrack = String(localized: "no track")
        /// Over the timeline: the day, or a trip over several days.
        static let theDay = String(localized: "THE DAY")
        static let theTrip = String(localized: "THE TRIP")
        /// Over the profile of the legs in the air, joined by the stops.
        static let altitudeInTheAir = String(localized: "ALTITUDE, IN THE AIR")
        /// A stop between two legs: "24 min on the ground".
        static func onTheGround(_ duration: String) -> String {
            String(localized: "\(duration) on the ground", comment: "Journey card: a stop between two legs; the argument is 24 min.")
        }
        static let shareDay = String(localized: "Share day")
        static let shareTrip = String(localized: "Share trip")
        static let eachLeg = String(localized: "Add each leg's card")
        static func eachLegHint(_ images: Int) -> String {
            String(localized: "\(images) images: this card first, then one for each leg")
        }
        /// "Hide where I parked" on a journey: the day's first departure and last arrival only.
        static let hideParkingJourneyHint = String(localized: "Leaves out the first 300 m of the first leg and the last 300 m of the last leg")

        // The Logbook's stats card (6.2: English in French until then). Its tiles take a `String`, which
        // `Text` shows as it is, so the lookup happens here.
        static let statsTitle = String(localized: "FLIGHT LOG")
        static let statsHours = String(localized: "HOURS")
        static let statsFlights = String(localized: "FLIGHTS")
        static let statsLandings = String(localized: "LANDINGS")
        static let statsHoursByAircraft = String(localized: "HOURS BY AIRCRAFT")
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
        // The event's name: the card's title and the post-flight review's type menu. (6.2)
        static let goAround = String(localized: "flightEvent.goAround")
        static let touchAndGo = String(localized: "flightEvent.touchAndGo")
        static let fullStop = String(localized: "flightEvent.fullStop")
    }

    // MARK: - Post-Flight Reconciliation
    enum Reconciliation {
        static let title = String(localized: "reconciliation.title")
        static let subtitle = String(localized: "reconciliation.subtitle")
        static let apply = String(localized: "reconciliation.apply")
        static let keepRecorded = String(localized: "reconciliation.keepRecorded")
        static let badgeConfirmed = String(localized: "reconciliation.badge.confirmed")
        static let badgeDetected = String(localized: "reconciliation.badge.detected")
        static let badgeTaken = String(localized: "reconciliation.badge.taken")
        static func badgeWas(_ type: String) -> String {
            String(format: String(localized: "reconciliation.badge.was"), type)
        }
        /// A landing marked a while after its touchdown: "you marked it at 13:42". (6.4.1)
        static func badgeMarkedAt(_ time: String) -> String {
            String(format: String(localized: "reconciliation.badge.markedAt"), time)
        }
        static let blockBackfill = String(localized: "reconciliation.blockBackfill")
        static let includedLabel = String(localized: "reconciliation.included")
        static let excludedLabel = String(localized: "reconciliation.excluded")
    }

    // MARK: - Hour Meter
    enum HourMeter {
        /// Inline prompts in the checklist, engine off. (v6.0 · B4)
        static let promptBeforeStart = String(localized: "hourMeter.prompt.beforeStart")
        static let promptAfterStop = String(localized: "hourMeter.prompt.afterStop")
        static let enter = String(localized: "hourMeter.prompt.enter")
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
        static let icao = String(localized: "mapLayer.icao")
        /// Plan › Map's chart, from the ICAO chart to the glider chart as it zooms in: "ICAO chart/Glider map". (6.4.2)
        static let icaoGlider = String(localized: "mapLayer.icaoGlider")
        /// The route builder's chart, from the ICAO chart to the glider chart to the National Map as it zooms in.
        /// (6.4.2)
        static let icaoGliderNational = String(localized: "mapLayer.icaoGliderNational")
        static let landeskarte = String(localized: "mapLayer.landeskarte")
        static let swissimage = String(localized: "mapLayer.swissimage")
        static let satellite = String(localized: "mapLayer.satellite")
        static let standard = String(localized: "mapLayer.standard")
        /// Under the Map sheet's charts, outside Switzerland: "ICAO chart: Switzerland only. Here, Apple Maps." (6.5.0)
        static func switzerlandOnly(_ chart: String, _ shown: String) -> String {
            String(format: String(localized: "mapLayer.switzerlandOnly"), chart, shown)
        }
    }

    // MARK: - Flight Plan Overlay
    enum FlightPlan {
    }

    // MARK: - Navigation / Flight Plans
    enum ImportLimits {
        /// Shown when a picked import file exceeds the size budget. (SEC-C31)
        static let tooLarge = String(localized: "import.errorTooLarge")
    }

    enum Export {
        /// Radio box footnote: a TMA with no published frequency borrows its CTR's.
        static func inferredFrequency(_ callSign: String, _ source: String) -> String {
            String(format: String(localized: "export.inferredFrequency"), callSign, source)
        }
        /// Radio box: countries the route crosses with no airspace data on the device.
        static func missingAirspace(_ countries: String) -> String {
            String(format: String(localized: "export.missingAirspace"), countries)
        }
        static func missingAirspaceShort(_ countries: String) -> String {
            String(format: String(localized: "export.missingAirspaceShort"), countries)
        }
        static let noRadioData = String(localized: "export.noRadioData")
        static let noAirspaceData = String(localized: "export.noAirspaceData")
        /// Radio box footnote for the "▸?" / "?" remarks: a limit in ft AGL or a flight level. (APP-11)
        static let verticalLimitUncertain = String(localized: "export.verticalLimitUncertain")
        static func radioSource(_ source: String) -> String {
            String(format: String(localized: "export.radioSource"), source)
        }
        static let verifyFrequencies = String(localized: "export.verifyFrequencies")
        /// Export menu: "1 page" / "2 pages".
        static func pages(_ count: Int) -> String {
            count == 1 ? String(localized: "export.onePage") : String(format: String(localized: "export.pages"), count)
        }
        static func waypointCount(_ count: Int) -> String {
            String(format: String(localized: "export.waypointCount"), count)
        }
        static let allWaypoints = String(localized: "export.allWaypoints")
        static let saveToFiles = String(localized: "export.saveToFiles")
        /// "Save GPX to Files…"
        static func saveFormat(_ format: String) -> String {
            String(format: String(localized: "export.saveFormat"), format)
        }
        static let previewPrint = String(localized: "export.previewPrint")
    }

    /// Trips: stops, legs, diversions and continuing after one. (v5.1)
    /// The ground tabs. (v6.0 · P1)
    /// The route editor. (planning proposal D)
    enum RouteEditor {
        static let legs = String(localized: "routeEditor.legs")
        static func conflicts(_ count: Int) -> String {
            count == 1 ? String(localized: "routeEditor.oneConflict")
                       : String(format: String(localized: "routeEditor.conflicts"), count)
        }
        static let noConflicts = String(localized: "routeEditor.noConflicts")
        static let notChecked = String(localized: "routeEditor.notChecked")
        static let waypoint = String(localized: "routeEditor.waypoint")
        static let mc = String(localized: "routeEditor.mc")
        static let altFt = String(localized: "routeEditor.altFt")
        static let destination = String(localized: "routeEditor.destination")
        static let selectLeg = String(localized: "routeEditor.selectLeg")
    }

    /// Plan › Flights. (planning proposal C)
    enum FlightsPage {
        static func upcomingCount(_ count: Int) -> String {
            String(format: String(localized: "flightsPage.upcomingCount"), count)
        }
        static let today = String(localized: "flightsPage.today")
        static let tomorrow = String(localized: "flightsPage.tomorrow")
        static let notScheduled = String(localized: "flightsPage.notScheduled")
        /// Over a flight whose day has gone by without it being flown. (v6.0 review)
        static let datePassed = String(localized: "flightsPage.datePassed")
        static let openFlight = String(localized: "flightsPage.openFlight")
        static let noRoute = String(localized: "flightsPage.noRoute")
        static func border(_ country: String) -> String {
            String(format: String(localized: "flightsPage.border"), country)
        }
        static func tripLeg(_ leg: Int, _ count: Int) -> String {
            String(format: String(localized: "flightsPage.tripLeg"), leg, count)
        }
        static func progress(_ done: Int, _ total: Int) -> String {
            String(format: String(localized: "flightsPage.progress"), done, total)
        }
        static func progressNext(_ done: Int, _ total: Int, _ next: String) -> String {
            String(format: String(localized: "flightsPage.progressNext"), done, total, next)
        }
    }

    /// Plan new flight. (planning proposal B)
    enum PlanFlight {
        static let route = String(localized: "planFlight.route")
        static let airports = String(localized: "planFlight.airports")
        static let savedRoute = String(localized: "planFlight.savedRoute")
        static let drawLater = String(localized: "planFlight.drawLater")
        static let noDateYet = String(localized: "planFlight.noDateYet")
        static let pickADate = String(localized: "planFlight.pickADate")
        static let noRouteYet = String(localized: "planFlight.noRouteYet")
        // Resolving what was typed against the airport data (v6.0 review)
        static let loadingAerodromes = String(localized: "planFlight.loadingAerodromes")
        static let unknownAerodrome = String(localized: "planFlight.unknownAerodrome")
        static func unknownInSummary(_ idents: String) -> String {
            String(format: String(localized: "planFlight.unknownInSummary"), idents)
        }
        static let noAirportData = String(localized: "planFlight.noAirportData")
        /// "Back to LSZQ: a local flight, or add a stop to land on the way."
        static func sameAerodrome(_ ident: String) -> String {
            String(format: String(localized: "planFlight.sameAerodrome"), ident)
        }
        // Stops (6.1, trips proposal M1)
        /// "Stop 1"
        static func stopLabel(_ number: Int) -> String {
            String(format: String(localized: "planFlight.stopLabel"), number)
        }
        static let addStopOnTheWay = String(localized: "planFlight.addStopOnTheWay")
        static let removeStop = String(localized: "planFlight.removeStop")
        /// "Bressaucourt · back home"
        static func backHome(_ name: String) -> String {
            String(format: String(localized: "planFlight.backHome"), name)
        }
        /// "80 NM direct · 1:18 flying"
        static func legsTotal(_ distance: String, _ eet: String) -> String {
            String(format: String(localized: "planFlight.legsTotal"), distance, eet)
        }
        /// "On the ground at LSGE"
        static func onTheGroundAt(_ ident: String) -> String {
            String(format: String(localized: "planFlight.onTheGroundAt"), ident)
        }
        /// "30 min"
        static func groundMinutes(_ minutes: Int) -> String {
            String(format: String(localized: "planFlight.groundMinutes"), minutes)
        }
        static let refuel = String(localized: "planFlight.refuel")
        static let legsExplainer = String(localized: "planFlight.legsExplainer")
        static let leg1Departure = String(localized: "planFlight.leg1Departure")
        // Landing on the way from a saved route (6.1, trips proposal M2)
        static let aerodromesOnRoute = String(localized: "planFlight.aerodromesOnRoute")
        static let inFlyingOrder = String(localized: "planFlight.inFlyingOrder")
        static let noAerodromesOnRoute = String(localized: "planFlight.noAerodromesOnRoute")
        /// "Show 14 more within 5 NM"
        static func moreNearRoute(_ count: Int) -> String {
            String(format: String(localized: "planFlight.moreNearRoute"), count)
        }
        static let landHere = String(localized: "planFlight.landHere")
        /// "Land at LSGE" (VoiceOver)
        static func landAt(_ ident: String) -> String {
            String(format: String(localized: "planFlight.landAt"), ident)
        }
        static let landElsewhere = String(localized: "planFlight.landElsewhere")
        /// "split from “Tour du Jura”"
        static func splitFrom(_ route: String) -> String {
            String(format: String(localized: "planFlight.splitFrom"), route)
        }
        static let routeLegsExplainer = String(localized: "planFlight.routeLegsExplainer")
        /// "Tour du Jura, landing at LSGE and LSGN"
        static func routeLandingAt(_ route: String, _ idents: String) -> String {
            String(format: String(localized: "planFlight.routeLandingAt"), route, idents)
        }
        /// "131 NM · 1:22 flying"
        static func legsTotalRoute(_ distance: String, _ eet: String) -> String {
            String(format: String(localized: "planFlight.legsTotalRoute"), distance, eet)
        }
    }

    /// "Add a stop…" with several stops at once, and on a local flight; a leg's stop, edited on its
    /// page. (6.1)
    enum AddStops {
        static let explainer = String(localized: "addStops.explainer")
        /// "Aerodromes within 40 NM of LSZQ, nearest first. Tick them in the order you will land."
        static func localHint(_ radiusNM: Int, _ ident: String) -> String {
            String(format: String(localized: "addStops.localHint"), radiusNM, ident)
        }
        /// "No aerodrome within 40 NM. Search for one above."
        static func noLocalCandidates(_ radiusNM: Int) -> String {
            String(format: String(localized: "addStops.noLocalCandidates"), radiusNM)
        }
        static let tickStops = String(localized: "addStops.tickStops")
        /// "Split into 3 legs"
        static func splitInto(_ legs: Int) -> String {
            String(format: String(localized: "addStops.splitInto"), legs)
        }
        /// "Stop at LSGE"
        static func stopAt(_ ident: String) -> String {
            String(format: String(localized: "addStops.stopAt"), ident)
        }
        /// "Leaves ≈ 10:53, when the leg before lands plus the time on the ground."
        static func leavesEstimated(_ time: String) -> String {
            String(format: String(localized: "addStops.leavesEstimated"), time)
        }
        /// "Leaves at 11:30, the time you chose. A new time on the ground estimates it again."
        static func leavesChosen(_ time: String) -> String {
            String(format: String(localized: "addStops.leavesChosen"), time)
        }
    }

    /// Where the pilot is based: Settings › Flight Planning and onboarding. (v6.1)
    enum HomeAerodrome {
        static let title = String(localized: "homeAerodrome.title")
        static let basedAt = String(localized: "homeAerodrome.basedAt")
        static let rowSubtitle = String(localized: "homeAerodrome.rowSubtitle")
        static let onboardingSubtitle = String(localized: "homeAerodrome.onboardingSubtitle")
        static let optionalNote = String(localized: "homeAerodrome.optionalNote")
        static func use(_ ident: String) -> String {
            String(format: String(localized: "homeAerodrome.use"), ident)
        }
        static let suggestionReason = String(localized: "homeAerodrome.suggestionReason")
        static let noAirportData = String(localized: "homeAerodrome.noAirportData")
        static let clear = String(localized: "homeAerodrome.clear")
    }

    /// The flight sheet: nav log, fuel, times. (planning proposal A)
    enum FlightSheet {
        static let route = String(localized: "flightSheet.route")
        static let fuelFlow = String(localized: "flightSheet.fuelFlow")
        static let departure = String(localized: "flightSheet.departure")
        static let localTime = String(localized: "flightSheet.localTime")
        static let dateAndTime = String(localized: "flightSheet.dateAndTime")
        static let crew = String(localized: "flightSheet.crew")
        static let fuel = String(localized: "flightSheet.fuel")
        static let litres = String(localized: "flightSheet.litres")
        static let defaultTag = String(localized: "flightSheet.default")
        static let flowNote = String(localized: "flightSheet.flowNote")
        static let trip = String(localized: "flightSheet.trip")
        static let fromRoute = String(localized: "flightSheet.fromRoute")
        static let alternate = String(localized: "flightSheet.alternate")
        static let finalReserve = String(localized: "flightSheet.finalReserve")
        static let extra = String(localized: "flightSheet.extra")
        static let required = String(localized: "flightSheet.required")
        static let onBoard = String(localized: "flightSheet.onBoard")
        static let margin = String(localized: "flightSheet.margin")
        static let short = String(localized: "flightSheet.short")
        static let endurance = String(localized: "flightSheet.endurance")
        static let afterFlight = String(localized: "flightSheet.afterFlight")
        static let afterFlightSummary = String(localized: "flightSheet.afterFlightSummary")
        static let notesSummary = String(localized: "flightSheet.notesSummary")
        static let atcSummary = String(localized: "flightSheet.atcSummary")
        static let rename = String(localized: "flightSheet.rename")
        static let airTime = String(localized: "flightSheet.airTime")
        static func aircraftFromFlight(_ aircraft: String) -> String {
            String(format: String(localized: "flightSheet.aircraftFromFlight"), aircraft)
        }
        static func tripNote(_ eet: String, _ flow: String) -> String {
            String(format: String(localized: "flightSheet.tripNote"), eet, flow)
        }
        static func finalReserveNote(_ flow: String) -> String {
            String(format: String(localized: "flightSheet.finalReserveNote"), flow)
        }
        static func marginMinutes(_ minutes: String) -> String {
            String(format: String(localized: "flightSheet.marginMinutes"), minutes)
        }
        static func enduranceNote(_ flow: String) -> String {
            String(format: String(localized: "flightSheet.enduranceNote"), flow)
        }
    }

    /// Naming a flight or a trip. (on-device review #4)
    enum FlightNames {
        static let renameFlight = String(localized: "flightNames.renameFlight")
        static let renameTrip = String(localized: "flightNames.renameTrip")
        static let renameFlightMessage = String(localized: "flightNames.renameFlightMessage")
        static let renameTripMessage = String(localized: "flightNames.renameTripMessage")
    }

    /// ICAO codes for the place names of an imported route. (on-device review #4)
    enum ICAONames {
        static let title = String(localized: "icaoNames.title")
        static let explainer = String(localized: "icaoNames.explainer")
        static let footer = String(localized: "icaoNames.footer")
        static let keepNames = String(localized: "icaoNames.keepNames")
        static let useCodes = String(localized: "icaoNames.useCodes")
        static let menu = String(localized: "icaoNames.menu")
        static let noneFound = String(localized: "icaoNames.noneFound")
    }

    /// The Routes list: search, archive, rename. (on-device review #4)
    enum Routes {
        static let searchPrompt = String(localized: "routes.searchPrompt")
        static let scope = String(localized: "routes.scope")
        static let routesScope = String(localized: "routes.routesScope")
        static func archivedScope(_ count: Int) -> String {
            String(format: String(localized: "routes.archivedScope"), count)
        }
        static let archive = String(localized: "routes.archive")
        static let unarchive = String(localized: "routes.unarchive")
        static let archivedHeader = String(localized: "routes.archivedHeader")
        static let archivedTag = String(localized: "routes.archivedTag")
        static let noArchived = String(localized: "routes.noArchived")
        static let allArchived = String(localized: "routes.allArchived")
        static let noneYet = String(localized: "routes.noneYet")
        static func noMatch(_ query: String) -> String {
            String(format: String(localized: "routes.noMatch"), query)
        }
        static let rename = String(localized: "routes.rename")
        static let renameTitle = String(localized: "routes.renameTitle")
        static let renameMessage = String(localized: "routes.renameMessage")
        static let namePlaceholder = String(localized: "routes.namePlaceholder")
    }

    /// The fuel-on-board sheet and the full-tanks figure. (on-device review #4, point 3)
    /// Where a plan's EET comes from: the allowances and the cruise speed. (6.1)
    enum EETPlanning {
        /// "departure +1 at LSZQ (6 flights)"
        static func departure(_ minutes: String, at aerodrome: String?, _ source: String) -> String {
            guard let aerodrome else { return String(format: String(localized: "eet.departureAnywhere"), minutes, source) }
            return String(format: String(localized: "eet.departure"), minutes, aerodrome, source)
        }
        /// "arrival +8 at LSGN (default)"
        static func arrival(_ minutes: String, at aerodrome: String?, _ source: String) -> String {
            guard let aerodrome else { return String(format: String(localized: "eet.arrivalAnywhere"), minutes, source) }
            return String(format: String(localized: "eet.arrival"), minutes, aerodrome, source)
        }
        /// "cruise 97 KIAS (aircraft data)"
        static func cruise(_ kias: String, _ source: String) -> String {
            String(format: String(localized: "eet.cruise"), kias, source)
        }
        static func flights(_ count: Int) -> String {
            String(format: String(localized: "eet.flights"), count)
        }
        static func allAerodromes(_ count: Int) -> String {
            String(format: String(localized: "eet.allAerodromes"), count)
        }
        static let standard = String(localized: "eet.standard")
        static let cruiseManual = String(localized: "eet.cruiseManual")
        static func cruiseLearned(_ count: Int) -> String {
            String(format: String(localized: "eet.cruiseLearned"), count)
        }
        static let cruiseAircraftData = String(localized: "eet.cruiseAircraftData")

        // The Aircraft tab
        static let planningGroup = String(localized: "eet.planningGroup")
        static let cruiseRow = String(localized: "eet.cruiseRow")
        static let cruiseRowFooter = String(localized: "eet.cruiseRowFooter")
        static func sourceManual(_ registration: String) -> String {
            String(format: String(localized: "eet.sourceManual"), registration)
        }
        static func sourceLearned(_ count: Int) -> String {
            String(format: String(localized: "eet.sourceLearned"), count)
        }
        static let sourceAircraftData = String(localized: "eet.sourceAircraftData")
        static let sourceStandard = String(localized: "eet.sourceStandard")
        static let useAutomatic = String(localized: "eet.useAutomatic")
        static func trueAirspeedNote(_ knots: String) -> String {
            String(format: String(localized: "eet.trueAirspeedNote"), knots)
        }
    }

    enum FuelOnBoard {
        static let title = String(localized: "fuelOnBoard.title")
        static let required = String(localized: "fuelOnBoard.required")
        static let onBoard = String(localized: "fuelOnBoard.onBoard")
        static func breakdown(_ trip: String, _ alternate: String, _ finalReserve: String, _ extra: String) -> String {
            String(format: String(localized: "fuelOnBoard.breakdown"), trip, alternate, finalReserve, extra)
        }
        static let noRequired = String(localized: "fuelOnBoard.noRequired")
        static func fullTanks(_ litres: String) -> String {
            String(format: String(localized: "fuelOnBoard.fullTanks"), litres)
        }
        static let fromAircraftData = String(localized: "fuelOnBoard.fromAircraftData")
        static func yourFigure(_ registration: String) -> String {
            String(format: String(localized: "fuelOnBoard.yourFigure"), registration)
        }
        static let change = String(localized: "fuelOnBoard.change")
        static func fullTanksPrompt(_ registration: String) -> String {
            String(format: String(localized: "fuelOnBoard.fullTanksPrompt"), registration)
        }
        static let saveAndFill = String(localized: "fuelOnBoard.saveAndFill")
        static let notSet = String(localized: "fuelOnBoard.notSet")
        static func enough(_ margin: String, _ minutes: String, _ flow: String) -> String {
            String(format: String(localized: "fuelOnBoard.enough"), margin, minutes, flow)
        }
        static func short(_ litres: String) -> String {
            String(format: String(localized: "fuelOnBoard.short"), litres)
        }
        static func overFullTanks(_ litres: String) -> String {
            String(format: String(localized: "fuelOnBoard.overFullTanks"), litres)
        }
        static let moreFuelSettings = String(localized: "fuelOnBoard.moreFuelSettings")
        static func equalsRequired(_ litres: String) -> String {
            String(format: String(localized: "fuelOnBoard.equalsRequired"), litres)
        }
        static let fuelGroup = String(localized: "fuelOnBoard.fuelGroup")
        static let fullTanksRow = String(localized: "fuelOnBoard.fullTanksRow")
        static let fullTanksRowFooter = String(localized: "fuelOnBoard.fullTanksRowFooter")
    }

    enum Ground {
        static let today = String(localized: "ground.today")
        static let plan = String(localized: "ground.plan")
        static let logbook = String(localized: "ground.logbook")
        static let aircraft = String(localized: "ground.aircraft")
        static let settings = String(localized: "ground.settings")
        static let planFlights = String(localized: "ground.plan.flights")
        static let planRoutes = String(localized: "ground.plan.routes")
        static let planMap = String(localized: "ground.plan.map")
        static let nextFlight = String(localized: "ground.nextFlight")
        static let recent = String(localized: "ground.recent")
        // Switching aircraft (on-device review #1, G-06)
        static let yourAircraft = String(localized: "ground.yourAircraft")
        static let aircraftDetails = String(localized: "ground.aircraftDetails")
        static let switchAircraft = String(localized: "ground.switchAircraft")
        // The Aircraft tab's two links (on-device review #2, G-06)
        static let proUnlocksAll = String(localized: "ground.proUnlocksAll")
        static let visibilityInSettings = String(localized: "ground.visibilityInSettings")
        static let proNotActiveShort = String(localized: "ground.proNotActiveShort")
        static let proNotActiveRow = String(localized: "ground.proNotActiveRow")
        static func speedsNeedPro(_ registration: String) -> String {
            String(format: String(localized: "ground.speedsNeedPro"), registration)
        }
    }

    /// The Cockpit's V-SPEEDS table: its rows. (V-SPEEDS proposal, D1–D8)
    enum VSpeeds {
        static let stallGlide = String(localized: "vspeeds.stallGlide")
        static let takeoffClimb = String(localized: "vspeeds.takeoffClimb")
        static let approachLanding = String(localized: "vspeeds.approachLanding")
        static let limits = String(localized: "vspeeds.limits")
        static let other = String(localized: "vspeeds.other")
        static let crosswind = String(localized: "vspeeds.crosswind")
        static func crosswindTakeoffA11y(_ limit: String) -> String {
            String(format: String(localized: "vspeeds.crosswindTakeoffA11y"), limit)
        }
        static func crosswindLandingA11y(_ limit: String) -> String {
            String(format: String(localized: "vspeeds.crosswindLandingA11y"), limit)
        }
    }

    /// The question before a jump that leaves two checks or more undone. (v6.0 review, J2-J3)
    enum Jump {
        static func title(_ phase: String) -> String { String(format: String(localized: "jump.title"), phase) }
        static func checksLeft(_ count: Int, _ list: String) -> String {
            String(format: String(localized: "jump.checksLeft"), count, list)
        }
        static func itemsKept(_ count: Int, _ phase: String) -> String {
            String(format: String(localized: "jump.itemsKept"), String(localized: "\(count) items"), phase)
        }
        static func deferChecks(_ count: Int) -> String { String(format: String(localized: "jump.deferChecks"), count) }
        static let deferHint = String(localized: "jump.deferHint")
        static let alreadyDone = String(localized: "jump.alreadyDone")
        static let alreadyDoneHint = String(localized: "jump.alreadyDoneHint")
        static func stay(_ phase: String) -> String { String(format: String(localized: "jump.stay"), phase) }
    }

    /// Checklist items left unchecked by NEXT. (v6.0 · B2)
    enum Deferred {
        /// "2 items not checked"
        static func notChecked(_ count: Int) -> String { String(localized: "\(count) items not checked") }
        /// "2 deferred items"
        static func count(_ count: Int) -> String { String(localized: "\(count) deferred items") }
        /// "2 deferred checks · 3 deferred items", as the deferred row says it. (v6.0 review, J1)
        static func summary(checks: Int, items: Int) -> String {
            if checks == 0 { return count(items) }
            if items == 0 { return String(localized: "\(checks) deferred checks") }
            return String(format: String(localized: "deferred.both"),
                          String(localized: "\(checks) checks"), String(localized: "\(items) items"))
        }
        static let checksHeader = String(localized: "deferred.checksHeader")
        static func checkRemaining(_ remaining: Int, _ total: Int) -> String {
            String(format: String(localized: "deferred.checkRemaining"), remaining, total)
        }
        static let run = String(localized: "deferred.run")
        static let runLabel = String(localized: "deferred.runLabel")
        static let backToChecklist = String(localized: "deferred.back")
        static let continueLater = String(localized: "deferred.continue")
        static let continueNote = String(localized: "deferred.continueNote")
        static let title = String(localized: "deferred.title")
        static let hint = String(localized: "deferred.hint")
        static let check = String(localized: "deferred.check")
        /// A memory check left unconfirmed, reviewed before it is deferred whole. (6.1)
        static func notConfirmed(_ check: String) -> String {
            String(format: String(localized: "deferred.notConfirmed"), check)
        }
        static let memoryCheckNotConfirmed = String(localized: "deferred.memoryCheckNotConfirmed")
        static let continueNoteMemory = String(localized: "deferred.continueNoteMemory")
        /// DONE on a memory check in the deferred list: confirmed from memory. (6.1)
        static let done = String(localized: "deferred.done")
        static func doneFromMemoryA11y(_ check: String) -> String {
            String(format: String(localized: "deferred.doneFromMemoryA11y"), check)
        }
        static let review = String(localized: "deferred.review")
        static let deferredTag = String(localized: "deferred.tag")
    }

    /// The Cockpit's act band, the four slots under every page. (6.2)
    enum Act {
        /// The button: a verb ("Dérouter"), where the Divert sheet's title is the noun ("Déroutement").
        static let divert = String(localized: "act.divert")
    }

    /// The Cockpit's ROUTE page, and MAP showing a leg tapped there. (6.2)
    enum Route {
        /// Over the legs: "LEGS" / "BRANCHES".
        static let legs = String(localized: "route.legs")
        /// Over the frequencies: "RADIO".
        static let radio = String(localized: "route.radio")
        /// Over the CTRs around that the route doesn't enter, after its calls. (6.4.2)
        static let nearby = String(localized: "route.nearby")
        /// MAP showing a leg: back to the aircraft, followed again.
        static let backToAircraft = String(localized: "map.backToAircraft")
        /// "Direct LSGC": the leg's waypoint, flown to straight away.
        static func direct(_ waypoint: String) -> String {
            String(format: String(localized: "map.directTo"), waypoint)
        }
    }

    /// The in-flight Cockpit on iPad. (v6.0 · P2)
    enum Cockpit {
        static let checklist = String(localized: "cockpit.checklist")
        static let map = String(localized: "cockpit.map")
        /// The third page: the DEST line, the legs and the radio. (6.2)
        static let route = String(localized: "cockpit.route")
        static let check = String(localized: "cockpit.check")
        static let deferItem = String(localized: "cockpit.defer")
        static let deferHint = String(localized: "cockpit.deferHint")
        /// "NEXT: TAXI"
        static func next(_ phase: String) -> String { String(format: String(localized: "cockpit.next"), phase) }
        static func nextPhaseA11y(_ phase: String) -> String {
            String(format: String(localized: "cockpit.nextPhaseA11y"), phase)
        }
        /// The strip's column over the next waypoint, on the iPad: "NEXT". (6.2)
        static let nextColumn = String(localized: "cockpit.nextColumn")
        static let allChecked = String(localized: "cockpit.allChecked")
        static let afterTakeoff = String(localized: "cockpit.afterTakeoff")
        static let climbCheckOnceAirborne = String(localized: "cockpit.climbCheckOnceAirborne")
        /// Under READY FOR LINE UP: "then LINE UP CHECK". (6.2)
        static func thenCheck(_ check: String) -> String {
            String(format: String(localized: "cockpit.thenCheck"), check)
        }
        /// VoiceOver, on READY FOR LINE UP: what the tap does besides going on. (6.2)
        static let readyForLineUpHint = String(localized: "cockpit.readyForLineUpHint")
        /// In NEXT's place at the end of a circuits flight's after landing check: "NEW CIRCUIT"; the
        /// phone's one line, "↻ CIRCUIT"; what it does, for VoiceOver. (6.3.0)
        static let newCircuit = String(localized: "cockpit.newCircuit")
        static let newCircuitShort = String(localized: "cockpit.newCircuit.short")
        static let newCircuitHint = String(localized: "cockpit.newCircuitHint")
        /// "CLIMB CHECK DONE", beside a ✓, on a memory check to confirm. (6.1)
        static func memoryCheckDone(_ check: String) -> String {
            String(format: String(localized: "cockpit.memoryCheckDone"), check)
        }
        /// The same in the iPhone's act band, on one line: "DONE", "FAIT". (6.2.0)
        static let memoryCheckDoneShort = String(localized: "cockpit.memoryCheckDone.short")
        static let fromMemory = String(localized: "cockpit.fromMemory")
        /// Under "✓ CLIMB CHECK DONE" when the same tap goes on: "NEXT: CRUISE CHECK · from memory". (6.1)
        static func fromMemoryThenNext(_ next: String) -> String {
            String(format: String(localized: "cockpit.fromMemoryThenNext"), next)
        }
        /// "Go-around detected and recorded": taken with no card, UNDO for six seconds. A key per event, so the
        /// French agrees with it (« Remise de gaz détectée et enregistrée »). (6.4.0)
        static func eventTaken(_ type: FlightEventType) -> String {
            switch type {
            case .goAround: return String(localized: "cockpit.eventTaken.goAround")
            case .touchAndGo: return String(localized: "cockpit.eventTaken.touchAndGo")
            case .fullStop: return String(localized: "cockpit.eventTaken.fullStop")
            }
        }
        /// The undo toast after a confirmation: "CLIMB CHECK done from memory". (6.1)
        static func doneFromMemoryToast(_ check: String) -> String {
            String(format: String(localized: "cockpit.doneFromMemoryToast"), check)
        }
        /// A tap on a checked item opens it again, on its own (v6.0 review, K-C); on an open one, checks it.
        static let reopenHint = String(localized: "cockpit.stepBackHint")
        static let checkAgainHint = String(localized: "cockpit.checkAgainHint")
        static let menu = String(localized: "cockpit.menu")
        static let display = String(localized: "cockpit.display")
        static let options = String(localized: "cockpit.options")
        static let endFlightHint = String(localized: "cockpit.endFlightHint")
        /// Menu's running flight time, and its circuit counts. (6.2.0)
        static let flightTime = String(localized: "Flight time")
        static let circuits = String(localized: "cockpit.menu.circuits")
        static let fullStops = String(localized: "cockpit.menu.fullStops")
    }

    /// The check slot on the map, in flight. (6.1)
    enum CheckSlot {
        static let fromMemoryOneTap = String(localized: "checkSlot.fromMemoryOneTap")
        static let fromMemoryNothingToPress = String(localized: "checkSlot.fromMemoryNothingToPress")
        static let nothingToPress = String(localized: "checkSlot.nothingToPress")
        /// "5 items"
        static func items(_ count: Int) -> String { String(localized: "\(count) items") }
        static let nextCheck = String(localized: "checkSlot.nextCheck")
        /// "ENGINE START first"
        static func actionFirst(_ action: String) -> String {
            String(format: String(localized: "checkSlot.actionFirst"), action)
        }
        static let confirmHint = String(localized: "checkSlot.confirmHint")
        static let showChecklistHint = String(localized: "checkSlot.showChecklistHint")
        /// "2 items · nothing to press": the landing check as a list, from circuit height. (6.1)
        static func itemsNothingToPress(_ count: Int) -> String { String(localized: "\(count) items · nothing to press") }
        /// "owed · you levelled off with it open": the moment of the flight that passed the check. (6.1)
        static func owed(after cue: FlightCue?) -> String {
            switch cue {
            case .takeoff: return String(localized: "checkSlot.owed.takeoff")
            case .levelOff: return String(localized: "checkSlot.owed.levelOff")
            case .descent: return String(localized: "checkSlot.owed.descent")
            case .approach: return String(localized: "checkSlot.owed.approach")
            case .circuit: return String(localized: "checkSlot.owed.circuit")
            case nil: return owedShort
            }
        }
        /// "owed", where the slot is narrow (the phone's shared row).
        static let owedShort = String(localized: "checkSlot.owedShort")
        static let advanceAndConfirmHint = String(localized: "checkSlot.advanceAndConfirmHint")
        static let goToLandingHint = String(localized: "checkSlot.goToLandingHint")
    }

    /// The landed card, after a full-stop landing on a flight that isn't circuits. (6.1, M4)
    enum LandedCard {
        /// "LANDED · LSZQ · 14:44", or "LANDED · 14:44" when the aerodrome isn't known.
        static func title(aerodrome: String?, time: String) -> String {
            guard let aerodrome, !aerodrome.isEmpty else {
                return String(format: String(localized: "landedCard.titleNoAerodrome"), time)
            }
            return String(format: String(localized: "landedCard.title"), aerodrome, time)
        }
        static let question = String(localized: "landedCard.question")
        static let yes = String(localized: "landedCard.yes")
        static let notSure = String(localized: "landedCard.notSure")
        static let explanation = String(localized: "landedCard.explanation")
        static let landingCheckDone = String(localized: "landedCard.landingCheckDone")
        static let yesHint = String(localized: "landedCard.yesHint")
        static let notSureHint = String(localized: "landedCard.notSureHint")
    }

    /// The checks in the debrief: the flight's page in the Flight Log, and the trend in the Logbook. (6.1)
    enum Debrief {
        static let title = String(localized: "debrief.title")
        static let allDone = String(localized: "debrief.allDone")
        /// Under "All checks done": "LANDING CHECK confirmed after landing".
        static func confirmedAfterLanding(_ check: String) -> String {
            String(format: String(localized: "debrief.confirmedAfterLanding"), check)
        }
        static let showEach = String(localized: "debrief.showEach")
        static let hideEach = String(localized: "debrief.hideEach")
        /// "12 other checks done"
        static func othersDone(_ count: Int) -> String {
            count == 1 ? String(localized: "debrief.otherDone")
                : String(format: String(localized: "debrief.othersDone"), count)
        }

        static func status(_ status: CheckDebrief.Status) -> String {
            switch status {
            case .done: return String(localized: "debrief.status.done")
            case .doneFromMemory: return String(localized: "debrief.status.doneFromMemory")
            case .confirmedAfterLanding: return String(localized: "debrief.status.confirmedAfterLanding")
            case .doneLate: return String(localized: "debrief.status.doneLate")
            case .owed: return String(localized: "debrief.status.owed")
            case .notSure: return String(localized: "debrief.status.notSure")
            case .skipped: return String(localized: "debrief.status.skipped")
            case .actionMissing: return String(localized: "debrief.status.actionMissing")
            case .nothingToDo: return String(localized: "debrief.status.nothingToDo")
            case .open: return String(localized: "debrief.status.open")
            case .notReached: return String(localized: "debrief.status.notReached")
            }
        }

        /// The moment of the flight that passed a check open: "you levelled off with it open".
        static func cue(_ cue: FlightCue?) -> String {
            switch cue {
            case .takeoff: return String(localized: "debrief.cue.takeoff")
            case .levelOff: return String(localized: "debrief.cue.levelOff")
            case .descent: return String(localized: "debrief.cue.descent")
            case .approach: return String(localized: "debrief.cue.approach")
            case .circuit: return String(localized: "debrief.cue.circuit")
            case nil: return String(localized: "debrief.cue.unknown")
            }
        }
        /// Circuits: "owed 3 times"
        static func owedTimes(_ count: Int) -> String {
            String(format: String(localized: "debrief.owedTimes"), count)
        }
        /// "done 14:26"
        static func doneAt(_ time: String) -> String { String(format: String(localized: "debrief.doneAt"), time) }
        /// "skipped 14:30"
        static func skippedAt(_ time: String) -> String { String(format: String(localized: "debrief.skippedAt"), time) }
        /// "answered 14:45"
        static func answeredAt(_ time: String) -> String { String(format: String(localized: "debrief.answeredAt"), time) }

        /// FREDA: "done 3×", "missed 1×", and the same spoken: "done 3 times".
        static func fredaDone(_ count: Int) -> String { String(format: String(localized: "debrief.freda.done"), count) }
        static func fredaMissed(_ count: Int) -> String { String(format: String(localized: "debrief.freda.missed"), count) }
        static func fredaDoneSpoken(_ count: Int) -> String {
            String(format: String(localized: "debrief.freda.doneSpoken"), count)
        }
        static func fredaMissedSpoken(_ count: Int) -> String {
            String(format: String(localized: "debrief.freda.missedSpoken"), count)
        }
        /// A FREDA missed, by the time it came due: "✕ due 14:41".
        static func fredaMissedDue(_ time: String) -> String {
            String(format: String(localized: "debrief.freda.missedDue"), time)
        }
        static func fredaMissedDueSpoken(_ time: String) -> String {
            String(format: String(localized: "debrief.freda.missedDueSpoken"), time)
        }

        /// The Logbook's trend: "CHECKS · LAST 10 FLIGHTS".
        static func trendTitle(_ flights: Int) -> String {
            String(format: String(localized: "debrief.trend.title"), flights)
        }
        /// "owed on 4 of 10 flights"
        static func trend(_ kind: CheckTrend.Kind, _ count: Int, of flights: Int) -> String {
            let format: String
            switch kind {
            case .owed: format = String(localized: "debrief.trend.owed")
            case .skipped: format = String(localized: "debrief.trend.skipped")
            case .notSure: format = String(localized: "debrief.trend.notSure")
            }
            return String(format: format, count, flights)
        }
    }

    /// A trip on Today and in Plan › Flights: the card that says "Trip" and lists its legs. (6.1)
    enum TripCard {
        /// The card's kind, where a single flight's card has its date: "Trip".
        static let kind = String(localized: "tripCard.kind")
        /// "Next: Fuel plan for leg 1"
        static func nextForLeg(_ task: String, _ leg: Int) -> String {
            String(format: String(localized: "tripCard.nextForLeg"), task, leg)
        }
        /// "Next: Weather briefing for the trip"
        static func nextForTrip(_ task: String) -> String {
            String(format: String(localized: "tripCard.nextForTrip"), task)
        }
        /// "Leg 2: everything ticked"
        static func legAllTicked(_ leg: Int) -> String {
            String(format: String(localized: "tripCard.legAllTicked"), leg)
        }
        /// "1/6 trip checks done"
        static func tripChecks(_ done: Int, _ total: Int) -> String {
            String(format: String(localized: "tripCard.tripChecks"), done, total)
        }
        /// Under START FLIGHT: "Leg 1 · LSZQ → LSGE"
        static func startLeg(_ leg: Int, _ route: String) -> String {
            String(format: String(localized: "tripCard.startLeg"), leg, route)
        }
        /// Plan › Flights, the legs' heading: "Legs"
        static let legs = String(localized: "tripCard.legs")
        /// A leg row's tag for the leg the card is about: "Next"
        static let nextLeg = String(localized: "tripCard.nextLeg")
        /// A flown leg's tag: "Flown"
        static let flown = String(localized: "tripCard.flown")
    }

    /// FREDA in cruise (6.1, "Checks in flight" Q6). The acronym and its letters stay as they are in
    /// French, like the other aviation terms.
    enum Freda {
        static let name = "FREDA"
        static let flow = "F · R · E · D · A"
        /// The phone's narrow places.
        static let flowCompact = "F·R·E·D·A"
        /// "CRUISE CHECK ✓ 14:24", "FREDA ✓ 14:34": what the count runs from.
        static func ticked(_ what: String, _ time: String) -> String { "\(what) ✓ \(time)" }
        /// The same on two lines, where the slot is narrow: "CRUISE CHECK", "✓ 14:24".
        static func tickedStacked(_ what: String, _ time: String) -> String { "\(what)\n✓ \(time)" }
        /// "FREDA in 6 min"
        static func inMinutes(_ minutes: Int) -> String {
            String(format: String(localized: "freda.inMinutes"), minutes)
        }
        /// "LSGC passed"
        static func waypointPassed(_ waypoint: String) -> String {
            String(format: String(localized: "freda.waypointPassed"), waypoint)
        }
        /// "F · R · E · D · A — LSGC passed"
        static func flowAfterWaypoint(_ waypoint: String) -> String { "\(flow) — \(waypointPassed(waypoint))" }
        /// The flow spelled out, for VoiceOver.
        static let flowSpelledOut = String(localized: "freda.flowSpelledOut")
        static let afterCruiseCheck = String(localized: "freda.afterCruiseCheck")
        static let confirmHint = String(localized: "freda.confirmHint")
        /// The undo toast: "FREDA done at 14:34".
        static func doneToast(_ time: String) -> String {
            String(format: String(localized: "freda.doneToast"), time)
        }
    }

    /// The DEST line on ROUTE: what VoiceOver reads of it, and its one button. Each reads in `language`
    /// ("fr") when one is given, in the app's language otherwise: the line's French previews and tests
    /// ask for French whatever the simulator speaks. "DEST", "ETA", "ETO" and "NM" stay as they are
    /// (ICAO). (6.2)
    enum Dest {
        /// "Destination LSZB"
        static func destination(_ ident: String, language: String? = nil) -> String {
            String(format: text("dest.a11y.destination", "Destination %@", language), ident)
        }
        /// Once the destination is marked: "Destination LSZB reached".
        static func reached(_ ident: String, language: String? = nil) -> String {
            String(format: text("dest.a11y.reached", "Destination %@ reached", language), ident)
        }
        /// "Diverting to LSGC", as the trip's card says it.
        static func divertingTo(_ ident: String, language: String? = nil) -> String {
            String(format: text("trip.divertingTo", "Diverting to %@", language), ident)
        }
        /// The live ETA over the destination: "overhead at 11:58".
        static func overhead(_ time: String, language: String? = nil) -> String {
            String(format: text("dest.a11y.overhead", "overhead at %@", language), time)
        }
        /// The plan's, with no live ETA: "planned overhead at 11:55".
        static func plannedOverhead(_ time: String, language: String? = nil) -> String {
            String(format: text("dest.a11y.plannedOverhead", "planned overhead at %@", language), time)
        }
        /// Δ in words: "3 minutes ahead of the plan".
        static func ahead(_ duration: String, language: String? = nil) -> String {
            String(format: text("dest.a11y.ahead", "%@ ahead of the plan", language), duration)
        }
        static func behind(_ duration: String, language: String? = nil) -> String {
            String(format: text("dest.a11y.behind", "%@ behind the plan", language), duration)
        }
        static func onTime(language: String? = nil) -> String {
            text("dest.a11y.onTime", "on time", language)
        }
        /// Before the Flight Log's DEST ETO, the line's value (the UI tests read it): "Planned arrival".
        static func plannedArrival(language: String? = nil) -> String {
            text("dest.a11y.plannedArrival", "Planned arrival", language)
        }
        /// The route drawn to scale: "12 of 83 NM flown, next LSGC".
        static func trackFlown(_ flown: Int, of total: Int, next: String, language: String? = nil) -> String {
            String(format: text("dest.a11y.trackNext", "%1$lld of %2$lld NM flown, next %3$@", language),
                   flown, total, next)
        }
        /// The same once the destination is marked: "83 of 83 NM flown".
        static func trackFlown(_ flown: Int, of total: Int, language: String? = nil) -> String {
            String(format: text("dest.a11y.track", "%1$lld of %2$lld NM flown", language), flown, total)
        }
        /// Back to the route while diverting, as the map's card says it.
        static func resumeRoute(language: String? = nil) -> String {
            text("trip.resumeRoute", "Resume route", language)
        }

        private static func text(_ key: String, _ english: String, _ language: String?) -> String {
            guard let language else { return Bundle.main.localizedString(forKey: key, value: english, table: nil) }
            return localizedString(key: key, language: language, defaultValue: english)
        }
    }

    /// The MAP page's chrome: the status slot's states, the controls' names for VoiceOver, the edge
    /// arrow. In `language` ("fr") when one is given, as `Dest`. The map's own words (North up, Centre,
    /// Zoom in, Undo) are the map's keys. "GPS", "SIGMET", "BRIEFING", "TRK" and "NM" stay as they are
    /// (ICAO, and the chip's BRIEFING). (6.2)
    enum MapChrome {
        static func gpsDegraded(language: String? = nil) -> String {
            text("mapChrome.status.gpsDegraded", "GPS DEGRADED", language)
        }
        /// The GPS lost, or a flight not recording: the header's red.
        static func noGPS(language: String? = nil) -> String {
            text("mapChrome.status.noGPS", "NO GPS", language)
        }
        /// "OFF ROUTE 1.2 NM"
        static func offRoute(_ distance: String, language: String? = nil) -> String {
            String(format: text("mapChrome.status.offRoute", "OFF ROUTE %@ NM", language), distance)
        }
        static func chartOffline(language: String? = nil) -> String {
            text("mapChrome.status.chartOffline", "CHART OFFLINE", language)
        }
        /// Over "Diverting to LSGC" (`divertingTo`).
        static func tellFIS(language: String? = nil) -> String {
            text("mapChrome.status.tellFIS", "TELL FIS", language)
        }
        static func divertingTo(_ ident: String, language: String? = nil) -> String {
            String(format: text("trip.divertingTo", "Diverting to %@", language), ident)
        }

        // What a tap on each state does, for VoiceOver.
        static func gpsHint(language: String? = nil) -> String {
            text("mapChrome.hint.gps", "Shows the GPS status", language)
        }
        /// GPS DEGRADED in the slot: a tap tucks it by the map's buttons. (6.2.0)
        static func tuckHint(language: String? = nil) -> String {
            text("mapChrome.hint.tuck", "Makes it a small square by the map's buttons", language)
        }
        static func offRouteHint(language: String? = nil) -> String {
            text("mapChrome.hint.offRoute", "Shows the aircraft and the leg", language)
        }
        static func chartOfflineHint(language: String? = nil) -> String {
            text("mapChrome.hint.chartOffline", "Shows where the chart comes from", language)
        }
        static func tellFISHint(language: String? = nil) -> String {
            text("mapChrome.hint.tellFIS", "Opens Divert", language)
        }
        static func sigmetHint(language: String? = nil) -> String {
            text("nav.sigmet.hint", "Shows the hazards in range", language)
        }
        static func briefingHint(language: String? = nil) -> String {
            text("mapChrome.hint.briefing", "Opens the briefing", language)
        }

        // The controls, as the map's row names them.
        static func northUp(language: String? = nil) -> String { text("nav.northUp", "North up", language) }
        static func trackUp(language: String? = nil) -> String { text("nav.trackUp", "Track up", language) }
        static func layers(language: String? = nil) -> String { text("nav.mapSheet", "Map", language) }
        static func centre(language: String? = nil) -> String { text("nav.centre", "Centre", language) }
        static func zoomIn(language: String? = nil) -> String { text("nav.zoomIn", "Zoom in", language) }
        static func zoomOut(language: String? = nil) -> String { text("nav.zoomOut", "Zoom out", language) }
        static func undo(language: String? = nil) -> String { text("nav.undo", "Undo", language) }
        /// The layers button's triangle, as the map's says it.
        static func airspaceStale(language: String? = nil) -> String {
            text("Airspace data is out of date", "Airspace data is out of date", language)
        }
        /// The edge arrow: "Aircraft off screen, at 2 o’clock".
        static func aircraftOffScreen(clock: Int, language: String? = nil) -> String {
            String(format: text("mapChrome.a11y.edgeArrow", "Aircraft off screen, at %lld o’clock", language), clock)
        }

        // More's items for the chart, on MAP.
        /// The SIGMETs in range, whose chip left the chart: "Hazards (2)".
        static func hazards(_ count: Int, language: String? = nil) -> String {
            String(format: text("mapChrome.more.hazards", "Hazards (%lld)", language), count)
        }
        /// The whole route framed, as the off-screen route's pill did.
        static func wholeRoute(language: String? = nil) -> String {
            text("mapChrome.more.wholeRoute", "Show the whole route", language)
        }

        private static func text(_ key: String, _ english: String, _ language: String?) -> String {
            guard let language else { return Bundle.main.localizedString(forKey: key, value: english, table: nil) }
            return localizedString(key: key, language: language, defaultValue: english)
        }
    }

    /// The read band over every Cockpit page: the strip's NEXT cell, the phone's next line, NOW | NEXT.
    /// `language` for the French previews and tests, as `Dest`. (6.2)
    enum Read {
        /// Over the next waypoint: "NEXT" / "SUIVANT".
        static func nextColumn(language: String? = nil) -> String {
            text("cockpit.nextColumn", "NEXT", language)
        }
        /// In its place while diverting: "DIVERT" / "DÉROUTEMENT".
        static func divertTag(language: String? = nil) -> String {
            text("trip.divertTag", "DIVERT", language)
        }
        /// The frequencies' tags: "NOW" / "ACT", "NEXT" / "SUIV".
        static func now(language: String? = nil) -> String { text("nav.freqCurrent", "NOW", language) }
        static func next(language: String? = nil) -> String { text("nav.freqNext", "NEXT", language) }
        /// NEXT's tag for a listen-only station: the destination's ATIS, an aerodrome on the way. (6.4.2)
        static func listen(language: String? = nil) -> String { text("nav.freqListen", "LISTEN", language) }
        /// What VoiceOver calls the waypoint flown to: "Next".
        static func nextWaypoint(language: String? = nil) -> String { text("nav.next", "Next", language) }
        /// "bearing 206 degrees"
        static func bearing(_ degrees: Int, language: String? = nil) -> String {
            String(format: text("read.a11y.bearing", "bearing %lld degrees", language), degrees)
        }
        /// No route, or the destination marked: "no waypoint ahead".
        static func noTarget(language: String? = nil) -> String {
            text("read.a11y.noTarget", "no waypoint ahead", language)
        }
        /// A tap on the line or the frequencies: "Legs and frequencies" (ROUTE).
        static func routeHint(language: String? = nil) -> String {
            text("nav.legsAndFrequencies", "Legs and frequencies", language)
        }

        // The frequency handover (6.4.3)

        /// The pilot's switch, offered back: "LSZG TWR HX now".
        static func switched(_ station: String, language: String? = nil) -> String {
            String(format: text("read.switched", "%@ now", language), station)
        }
        /// The app's own switch at a latest point: "LSZG TWR HX now, automatically".
        static func switchedAutomatically(_ station: String, language: String? = nil) -> String {
            String(format: text("read.switchedAutomatically", "%@ now, automatically", language), station)
        }
        /// A LISTEN tapped: "LSZG ATIS heard".
        static func heard(_ station: String, language: String? = nil) -> String {
            String(format: text("read.heard", "%@ heard", language), station)
        }
        /// After a NEXT that is due, for VoiceOver: "NEXT, 120.105, LSZG TWR HX, due".
        static func due(language: String? = nil) -> String { text("read.a11y.due", "due", language) }
        /// What a tap on NEXT does: "Switches to this frequency", "Marks it heard".
        static func switchHint(language: String? = nil) -> String {
            text("read.a11y.switchHint", "Switches to this frequency", language)
        }
        static func heardHint(language: String? = nil) -> String {
            text("read.a11y.heardHint", "Marks it heard", language)
        }

        private static func text(_ key: String, _ english: String, _ language: String?) -> String {
            guard let language else { return Bundle.main.localizedString(forKey: key, value: english, table: nil) }
            return localizedString(key: key, language: language, defaultValue: english)
        }
    }

    enum Trip {
        static let addStop = String(localized: "trip.addStop")
        static let addStopTitle = String(localized: "trip.addStopTitle")
        static let addStopHint = String(localized: "trip.addStopHint")
        static let searchAerodrome = String(localized: "trip.searchAerodrome")
        static let onRoute = String(localized: "trip.onRoute")
        /// "3.6 NM off"
        static func offRoute(_ nm: String) -> String {
            String(format: String(localized: "trip.offRoute"), nm)
        }
        static let noFrequency = String(localized: "trip.noFrequency")
        static let noCandidates = String(localized: "trip.noCandidates")
        /// A searched aerodrome that is this flight's own end, so no stop (6.1).
        static let leavesHere = String(localized: "trip.leavesHere")
        static let landsHere = String(localized: "trip.landsHere")
        static let leavesAndLandsHere = String(localized: "trip.leavesAndLandsHere")
        static let refuelHint = String(localized: "trip.refuelHint")
        static let joinNextLeg = String(localized: "trip.joinNextLeg")

        // Cancel trip (6.1)
        static let cancelTrip = String(localized: "trip.cancel")
        /// At the foot of a trip's leg, beside the whole trip's cancel. (6.1.0)
        static let cancelThisLeg = String(localized: "trip.cancelThisLeg")
        /// The legs it takes: those not flown yet.
        static func cancelWholeTrip(legs: Int) -> String {
            legs == 1 ? String(localized: "trip.cancelWholeTripOneLeg")
                      : String(format: String(localized: "trip.cancelWholeTrip"), legs)
        }
        static let cancelConfirmTitle = String(localized: "trip.cancelConfirm.title")
        static let keepTrip = String(localized: "trip.cancelConfirm.keep")
        /// "Leg 2 · LSGE → LSGN"
        static func cancelConfirmLeg(_ number: Int, _ label: String) -> String {
            String(format: String(localized: "trip.cancelConfirm.leg"), number, label)
        }
        /// The legs that go, one a line, then what stays: the legs already flown, when there are any.
        static func cancelConfirmMessage(_ legs: String, keepsFlown: Bool) -> String {
            let format = keepsFlown
                ? String(localized: "trip.cancelConfirm.messageKeepsFlown")
                : String(localized: "trip.cancelConfirm.message")
            return String(format: format, legs)
        }
        /// "≈ 15:10 (est.)"
        static func estimated(_ time: String) -> String {
            String(format: String(localized: "trip.estimated"), time)
        }
        static let stops = String(localized: "trip.stops")
        /// "Create trip · 3 legs"
        static func createTrip(_ legs: Int) -> String {
            String(format: String(localized: "trip.createTrip"), legs)
        }

        // Divert
        static let divert = String(localized: "trip.divert")
        /// "DIVERT TO LSZE"
        static func divertTo(_ ident: String) -> String {
            String(format: String(localized: "trip.divertTo"), ident)
        }
        /// "DIRECT TO LSZQ"
        static func directTo(_ ident: String) -> String {
            String(format: String(localized: "trip.directTo"), ident)
        }
        /// "Diverting to LSZE"
        static func divertingTo(_ ident: String) -> String {
            String(format: String(localized: "trip.divertingTo"), ident)
        }
        static let resumeRoute = String(localized: "trip.resumeRoute")
        static let destination = String(localized: "trip.destination")
        static let alternate = String(localized: "trip.alternate")
        static let ahead = String(localized: "trip.ahead")
        static let behind = String(localized: "trip.behind")
        static let notListed = String(localized: "trip.notListed")
        /// "AT · border"
        static func border(_ country: String) -> String {
            String(format: String(localized: "trip.border"), country)
        }
        static let noAerodromes = String(localized: "trip.noAerodromes")
        static let checkChart = String(localized: "trip.checkChart")
        static let divertTag = String(localized: "trip.divertTag")
        /// "Flight plan filed: tell FIS you are diverting to LSZE"
        static func tellFIS(_ ident: String) -> String {
            String(format: String(localized: "trip.tellFIS"), ident)
        }
        static let directToWaypoint = String(localized: "trip.directToWaypoint")

        // Continue after landing elsewhere
        /// "Landed at LSZE"
        static func landedAt(_ ident: String) -> String {
            String(format: String(localized: "trip.landedAt"), ident)
        }
        /// "planned LSZQ"
        static func planned(_ ident: String) -> String {
            String(format: String(localized: "trip.planned"), ident)
        }
        /// "Continue to LSZQ"
        static func continueTo(_ ident: String) -> String {
            String(format: String(localized: "trip.continueTo"), ident)
        }
        static func continueExplainer(_ from: String, _ to: String) -> String {
            String(format: String(localized: "trip.continueExplainer"), from, to)
        }
        static let finishHere = String(localized: "trip.finishHere")
        /// "Tell Zurich FIC you landed at LSZE, not LSZQ."
        static func tellFICLanded(_ landed: String, _ planned: String) -> String {
            String(format: String(localized: "trip.tellFICLanded"), landed, planned)
        }

        // Nav log
        static let notFlown = String(localized: "trip.notFlown")
        /// "diverted at 14:36"
        static func divertedAt(_ time: String) -> String {
            String(format: String(localized: "trip.divertedAt"), time)
        }
        static let landedHereInstead = String(localized: "trip.landedHereInstead")
        /// "est.: previous leg + 30 min on the ground"
        static func estimatedDepartureRemark(_ minutes: Int) -> String {
            String(format: String(localized: "trip.estimatedDepartureRemark"), minutes)
        }
    }

    /// The builder's "Set altitudes" sheet.
    enum Altitudes {
        static let title = String(localized: "altitudes.title")
        static let modeTerrain = String(localized: "altitudes.mode.terrain")
        static let modeFixed = String(localized: "altitudes.mode.fixed")
        static let clearance = String(localized: "altitudes.clearance")
        static let roundUp = String(localized: "altitudes.roundUp")
        static let basis = String(localized: "altitudes.basis")
        static let basisLegs = String(localized: "altitudes.basis.legs")
        static let basisGround = String(localized: "altitudes.basis.ground")
        static let altitudeField = String(localized: "altitudes.altitudeField")
        static let columnWaypoint = String(localized: "altitudes.col.waypoint")
        static let columnNow = String(localized: "altitudes.col.now")
        static let columnNew = String(localized: "altitudes.col.new")
        static let columnClearance = String(localized: "altitudes.col.clearance")
        static func lowest(_ feet: String, _ from: String, _ to: String) -> String {
            String(format: String(localized: "altitudes.summary.lowest"), feet, from, to)
        }
        static func busts(_ count: Int) -> String {
            String(format: String(localized: "altitudes.summary.busts"), count)
        }
        static let allClear = String(localized: "altitudes.summary.clear")
        static func enters(_ names: String) -> String {
            String(format: String(localized: "altitudes.summary.enters"), names)
        }
        static func apply(_ count: Int) -> String {
            String(format: String(localized: "altitudes.apply"), count)
        }
        static let loading = String(localized: "altitudes.loading")
        static let terrainUnavailable = String(localized: "altitudes.terrainUnavailable")
        static let footnote = String(localized: "altitudes.footnote")
        static let climbOut = String(localized: "altitudes.climbOut")
        static let descent = String(localized: "altitudes.descent")
        static let banner = String(localized: "altitudes.banner")
        static let bannerAction = String(localized: "altitudes.bannerAction")
        static let selectAll = String(localized: "altitudes.selectAll")
    }

    enum PDF {
        static let title = String(localized: "pdf.title")
        static let pilot = String(localized: "pdf.pilot")
        static let aircraft = String(localized: "pdf.aircraft")
        static let totalEET = String(localized: "pdf.totalEET")
        /// What the total EET is made of: the allowances and the cruise speed, and where they come from. (6.1)
        static let eetBasis = String(localized: "pdf.eetBasis")
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
        static let sectionRadio = String(localized: "pdf.sectionRadio")
        static let radioStations = String(localized: "pdf.radioStations")
        static let radioSource = String(localized: "pdf.radioSource")
        static let continued = String(localized: "pdf.continued")
        static let routeContinues = String(localized: "pdf.routeContinues")
        static func page(_ number: Int, _ count: Int) -> String {
            String(format: String(localized: "pdf.page"), number, count)
        }
    }

    /// Aerodrome procedures from open flightmaps on the maps: the switches, the labels, the callout and
    /// the credit. (6.2.0)
    enum VFRMap {
        // A US field's traffic pattern, from the FAA's NASR (6.5.0)
        static let patternRight = String(localized: "vfrMap.pattern.right")
        static let patternLeft = String(localized: "vfrMap.pattern.left")
        /// "right-hand traffic", for VoiceOver after the runway.
        static func patternTraffic(_ side: NASRPatterns.Side) -> String {
            String(localized: side == .right ? "vfrMap.pattern.rightTraffic" : "vfrMap.pattern.leftTraffic")
        }
        /// "TPA 806 ft".
        static func patternAltitude(_ feet: Int) -> String {
            String(format: String(localized: "vfrMap.pattern.altitude"), feet)
        }
        static let aerodromeProcedures = String(localized: "Aerodrome procedures")
        static let showCircuits = String(localized: "Traffic circuits")
        static let showRoutes = String(localized: "Arrival & departure routes (with sectors)")
        /// The third switch: the glider, UL, gyro and helicopter circuits (with the routes, the helicopter
        /// routes), and open flightmaps' helicopter and glider reporting points. (6.2.0)
        static let showNonPowered = String(localized: "Glider, UL & helicopter")
        /// Navigation & Maps, under the three switches.
        static let settingsFooter = String(localized: "From open flightmaps, for the countries in Data & Storage. Indicative only: always check the official chart.")
        /// The Map sheet, when a switch is on and the country under the map has none downloaded.
        static func downloadHint(_ country: String) -> String {
            String(localized: "Download VFR procedures for \(country) in Data & Storage")
        }
        static let credit = String(localized: "Circuits & VFR routes © open flightmaps · indicative")
        static func creditWithCycle(_ airac: String) -> String {
            String(localized: "Circuits & VFR routes © open flightmaps · AIRAC \(airac) · indicative")
        }
        static let trafficCircuit = String(localized: "Traffic circuit")
        static let arrival = String(localized: "VFR arrival")
        static let departure = String(localized: "VFR departure")
        static let sector = String(localized: "Sector")
        static let noiseArea = String(localized: "Noise abatement area")
        /// A circuit's label when open flightmaps has no usable altitude for it.
        static let altitudeSeeChart = String(localized: "Alt: see chart")
        static let approximateShape = String(localized: "Approximate shape")
        static let source = String(localized: "open flightmaps · indicative, check the official chart")
        static func sourceWithCycle(_ airac: String) -> String {
            String(localized: "open flightmaps · AIRAC \(airac) · indicative, check the official chart")
        }
        /// The same on one line, where the official chart's button is right under it (the phone's Cockpit).
        static let sourceShort = String(localized: "open flightmaps · indicative")
        static func sourceShortWithCycle(_ airac: String) -> String {
            String(localized: "open flightmaps · AIRAC \(airac) · indicative")
        }
        static let reportError = String(localized: "Report an error")
        /// Report an error, where the phone's Cockpit puts it beside the official chart.
        static let reportShort = String(localized: "Report")
        /// The approach view's runway numbers, for VoiceOver. (6.2.0)
        static func runway(_ ident: String) -> String {
            String(localized: "Runway \(ident)")
        }
        static func runwayInUse(_ ident: String) -> String {
            String(localized: "Runway \(ident), in use")
        }
        /// The approach view's parachute, where OpenAIP says there is parachuting. (6.2.0)
        static let parachuting = String(localized: "Parachuting")
    }

    /// An aerodrome's official chart, opened in the browser: DFS BasicVFR, the SIA VAC, SkyBriefing's
    /// VFR Manual, Austro Control's eAIP, and 14 more countries' AIPs and VFR manuals. (6.2.0)
    enum OfficialChart {
        static let title = String(localized: "Official chart")
        /// A publisher behind a login: "SkyBriefing (subscription)".
        static func subscription(_ publisher: String) -> String {
            String(localized: "\(publisher) (subscription)")
        }
        /// Under the symbol of an airport callout's accessory, where "Official chart" doesn't fit.
        static let short = String(localized: "Chart")
        /// Under "Chart" on the phone's Cockpit, where "SkyBriefing (subscription)" doesn't fit.
        static let subscriptionShort = String(localized: "Subscription")
        /// A publisher behind a free sign-in, no subscription: "BULATSA (sign-in)".
        static func signIn(_ publisher: String) -> String {
            String(localized: "\(publisher) (sign-in)")
        }
        /// The short form, under "Chart" on the phone's Cockpit.
        static let signInShort = String(localized: "Sign-in")
        /// VoiceOver's hint: "Opens SkyBriefing in the browser".
        static func opens(_ publisher: String) -> String {
            String(localized: "Opens \(publisher) in the browser")
        }
    }

    enum Nav {
        static let sigmetOverhead = String(localized: "nav.sigmet.overhead")
        static let sigmetOnRoute = String(localized: "nav.sigmet.onRoute")
        static let sigmetUntil = String(localized: "nav.sigmet.until")
        static let sigmetUnknownHazard = String(localized: "nav.sigmet.unknownHazard")
        static let sigmetDisclaimer = String(localized: "nav.sigmet.disclaimer")
        static let sigmetHint = String(localized: "nav.sigmet.hint")
        static func sigmetAccessibility(_ count: Int) -> String {
            String(format: String(localized: "nav.sigmet.accessibility"), count)
        }
        // Waypoint validation (SEC-C20)
        static let invalidValueTitle = String(localized: "nav.invalidValueTitle")
        static let invalidCoordinatesMessage = String(localized: "nav.invalidCoordinatesMessage")
        static let invalidAltitudeMessage = String(localized: "nav.invalidAltitudeMessage")
        static let invalidGroundSpeedMessage = String(localized: "nav.invalidGroundSpeedMessage")
        static let invalidWindMessage = String(localized: "nav.invalidWindMessage")

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
        static let activate = String(localized: "Show on map")
        static let flightPlanDetails = String(localized: "Flight details")
        static let deactivate = String(localized: "Clear from map")
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
        // Route profile: the route may be inside an airspace whose limit could not be pinned down (APP-11)
        static let airspaceMaybeAGL = String(localized: "nav.airspaceMaybeAGL")
        static let airspaceMaybeFL = String(localized: "nav.airspaceMaybeFL")
        static let exportGPX = String(localized: "nav.exportGPX")
        static let routeProfileTitle = String(localized: "nav.routeProfileTitle")
        static let editRoute = String(localized: "nav.editRoute")
        static let logbookTimes = String(localized: "nav.logbookTimes")
        static let navLog = String(localized: "nav.navLog")
        static let expandProfile = String(localized: "nav.expandProfile")
        static let shrinkProfile = String(localized: "nav.shrinkProfile")
        static let collapseProfile = String(localized: "nav.collapseProfile")
        static let showProfile = String(localized: "nav.showProfile")
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
        static let departureTime = String(localized: "nav.departureTime")
        static let runway = String(localized: "nav.runway")
        static let instructor = String(localized: "nav.instructor")
        static let totalEET = String(localized: "nav.totalEET")
        static let distance = String(localized: "nav.distance")
        static let endurance = String(localized: "nav.endurance")
        static let freq = String(localized: "nav.freq")
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
        static let fuelOnBoard = String(localized: "Fuel on board (L)")

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
        /// Take-off to landing: Time OFF to Time ON on the nav log.
        static let airTime = String(localized: "nav.airTime")

        // Notes
        static let notes = String(localized: "nav.notes")
        static let remarks = String(localized: "nav.remarks")
        static let debriefing = String(localized: "nav.debriefing")

        // Actions
        static let activateFlightPlan = String(localized: "Show this route on the map")
        static let deactivateFlightPlan = String(localized: "Clear this route from the map")
        /// Only shown when the plan has recorded progress — re-activating clears every ATO and
        /// resets the leg index, so an accidental tap mid-flight destroys logged times. (v4.4.0)
        static let deactivateConfirmTitle = String(localized: "nav.deactivateConfirmTitle")
        static let deactivateConfirmMessage = String(localized: "nav.deactivateConfirmMessage")
        /// Nav map: an armed route with no part of it on screen. "096 NM · 264°".
        static func routeOffScreen(_ distanceNm: Int, _ bearing: String) -> String {
            String(format: String(localized: "nav.routeOffScreen"), distanceNm, bearing)
        }
        static let showRoute = String(localized: "nav.showRoute")
        static let activationExpiredTitle = String(localized: "nav.activationExpiredTitle")
        static func activationExpiredMessage(_ route: String) -> String {
            String(format: String(localized: "nav.activationExpiredMessage"), route)
        }
        static let rearm = String(localized: "nav.rearm")

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
        static let trackVector = String(localized: "nav.trackVector")
        static let trackVectorDesc = String(localized: "nav.trackVectorDesc")
        static let freqCurrent = String(localized: "nav.freqCurrent")
        static let freqNext = String(localized: "nav.freqNext")
        /// Listen-only, in NEXT's place: an ATIS, an aerodrome on the way. (6.4.2)
        static let freqListen = String(localized: "nav.freqListen")
        /// 121.500, last in the FREQ panel. (6.2)
        static let freqEmergency = String(localized: "nav.freqEmergency")
        static let mark = String(localized: "nav.mark")
        static let overlays = String(localized: "nav.overlays")
        static let airspace = String(localized: "nav.airspace")
        static let airspaceNoData = String(localized: "nav.airspaceNoData")
        static let downloadAirspaceData = String(localized: "nav.downloadAirspaceData")
        /// Deliberately "near your route", not "for this trip". The country list includes anything
        /// within the inclusion buffer — a route along the Jura reports France, and one to Samedan
        /// reports Italy — because that is the airspace you can see and enter. Saying "for this trip"
        /// read as "you are flying to these countries", which is why it looked wrong on a Swiss
        /// domestic flight. (device pass)
        static let tripDataMissing = String(localized: "Airspace data missing near your route")
        static func tripDataProgress(_ done: Int, _ total: Int) -> String {
            String(localized: "\(done)/\(total) layers")
        }
        /// Shown in the same banner when the download ran but some layers came back empty — so the
        /// banner stops silently re-offering a button that cannot succeed. (v4.4.0)
        static let tripDataFailed = String(localized: "Some data could not be downloaded")
        static let tripDataFailedDetail = String(localized: "The provider is not serving these layers right now. Try again later.")
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
        static let pauseChronometer = String(localized: "nav.pauseChronometer")
        static let startChronometer = String(localized: "nav.startChronometer")
        static let resetChronometer = String(localized: "nav.resetChronometer")
        static let legTimerReset = String(localized: "nav.legTimerReset")
        static let undo = String(localized: "nav.undo")
        /// "LSGC passed at 13:07"
        // Map chrome, iPad (v6.0 · P3)
        static let mapSheet = String(localized: "nav.mapSheet")
        static let northUp = String(localized: "nav.northUp")
        static let trackUp = String(localized: "nav.trackUp")
        static let centre = String(localized: "nav.centre")
        static let more = String(localized: "nav.more")
        static let leg = String(localized: "nav.leg")
        static let startLegTimer = String(localized: "nav.startLegTimer")
        static let legsAndFrequencies = String(localized: "nav.legsAndFrequencies")
        /// VoiceOver's action on the map left above the open legs panel, which a tap closes. (6.1)
        static let closeLegsAndFrequencies = String(localized: "nav.closeLegsAndFrequencies")
        static let baseChart = String(localized: "nav.baseChart")
        static let presets = String(localized: "nav.presets")
        static let presetCruise = String(localized: "nav.presetCruise")
        static let presetApproach = String(localized: "nav.presetApproach")
        static let presetEverything = String(localized: "nav.presetEverything")
        static let presetsHint = String(localized: "nav.presetsHint")
        static func markedAt(_ waypoint: String, _ time: String) -> String {
            String(format: String(localized: "nav.markedAt"), waypoint, time)
        }
        /// "LSGC marked automatically at 14:37": passed, from the GPS track. (v6.0.1)
        static func markedAutomaticallyAt(_ waypoint: String, _ time: String) -> String {
            String(format: String(localized: "nav.markedAutomaticallyAt"), waypoint, time)
        }
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
        /// The "+" in a map callout: the aerodrome, navaid or reporting point goes into the route. (6.0.1)
        static let addToRoute = String(localized: "nav.addToRoute")
        /// The reporting point's ident from an OpenAIP remark ("ELESE"): not an official designator,
        /// so it is labelled as such wherever it shows. (6.0.1)
        static let pointIdent = String(localized: "nav.pointIdent")
        /// What an open flightmaps helicopter or glider reporting point is for, on its own line in the
        /// callout and the briefing (shown only with the "Glider, UL & helicopter" switch). (6.2.0)
        static let helicopterReportingPoint = String(localized: "Helicopter reporting point")
        static let gliderReportingPoint = String(localized: "Glider reporting point")
        /// The builder's search for a reporting point or navaid to put in the route, under From and To.
        static let via = String(localized: "nav.via")
        static let viaPlaceholder = String(localized: "nav.viaPlaceholder")
        static func viaNoMatch(_ query: String) -> String {
            String(format: String(localized: "nav.viaNoMatch"), query)
        }
        /// Plan › Map's magnifying glass, and the search it opens. (6.2.0)
        static let searchAerodromes = String(localized: "nav.searchAerodromes")
        static func searchNoMatch(_ query: String) -> String {
            String(format: String(localized: "nav.searchNoMatch"), query)
        }
        static let searchNoAirportData = String(localized: "nav.searchNoAirportData")
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
        /// Under the true airspeed of a waypoint: what an empty field means. (6.1)
        static let airspeedFromAircraft = String(localized: "nav.airspeedFromAircraft")
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
        static let icaoFlightPlanCopied = String(localized: "nav.icaoFlightPlanCopied")
    }

    // MARK: - Companion Mode
    enum Companion {
        // Companion command authorisation (SEC-C40)
        static let allowControlTitle = String(localized: "companion.allowControlTitle")
        /// For a peer Wi-Fi Aware did not identify: this connection only.
        static let allowControl = String(localized: "companion.allowControl")
        static let allowControlForFlight = String(localized: "companion.allowControlForFlight")
        static let alwaysAllowControl = String(localized: "companion.alwaysAllowControl")
        static let denyControl = String(localized: "companion.denyControl")
        /// `device` nil when Wi-Fi Aware did not name the peer: the prompt then says "a paired device"
        /// rather than guess one from the paired list (S9-28). `canRemember` false for a peer it did not
        /// identify, which is asked about this connection only. (6.1.0)
        static func allowControlMessage(_ device: String?, canRemember: Bool) -> String {
            guard canRemember else { return String(localized: "companion.allowControlMessageUnnamed") }
            guard let device else { return String(localized: "companion.allowControlMessageUnnamedDevice") }
            return String(format: String(localized: "companion.allowControlMessage"), device)
        }

        // Always Allow (6.1.0)
        static let deviceAlwaysAllowed = String(localized: "companion.deviceAlwaysAllowed")
        static let askEachFlight = String(localized: "companion.askEachFlight")
        static func askEachFlightAccessibility(_ device: String) -> String {
            String(format: String(localized: "companion.askEachFlightAccessibility"), device)
        }

        // Forget device (S9-09)
        static let forgetDevice = String(localized: "companion.forgetDevice")
        static let allowDeviceAgain = String(localized: "companion.allowDeviceAgain")
        static let deviceForgotten = String(localized: "companion.deviceForgotten")
        static func forgetDeviceAccessibility(_ device: String) -> String {
            String(format: String(localized: "companion.forgetDeviceAccessibility"), device)
        }
        static func allowDeviceAgainAccessibility(_ device: String) -> String {
            String(format: String(localized: "companion.allowDeviceAgainAccessibility"), device)
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
        static let pairWithiPad = String(localized: "companion.pairWithiPad")
        static let pairWithiPhone = String(localized: "companion.pairWithiPhone")
        static let scanForDevices = String(localized: "companion.scanForDevices")
        static let makeDiscoverable = String(localized: "companion.makeDiscoverable")
        // The pairing screen's steps, per role: the iPad taps Make discoverable FIRST and keeps that
        // sheet up while the iPhone scans. Both buttons have to be tapped, in that order. (6.1.0)
        static let pairingMasterDescription = String(localized: "companion.pairingMasterDescription")
        static let pairingViewerDescription = String(localized: "companion.pairingViewerDescription")
        /// The link is paused while the pairing screen is up, which closes by itself once paired. (6.1.0)
        static let pairingPausesLink = String(localized: "companion.pairingPausesLink")

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
        static let noFlightPlan = String(localized: "companion.noFlightPlan")
        static let holdToReveal = String(localized: "companion.holdToReveal")
        static let exitConfirmTitle = String(localized: "companion.exitConfirmTitle")
        static let exitConfirmMessage = String(localized: "companion.exitConfirmMessage")
        static let exitConfirmLeave = String(localized: "companion.exitConfirmLeave")
        static let pairInSettings = String(localized: "companion.pairInSettings")

        // Divert from the phone (6.2.0). The rest of its words are the iPad's Divert sheet's (`Trip`).
        static let divertHint = String(localized: "companion.divertHint")
        static let divertNearest = String(localized: "companion.divertNearest")
        static let divertWaiting = String(localized: "companion.divertWaiting")
        static let divertAllowOnIPad = String(localized: "companion.divertAllowOnIPad")
        static let divertNotTaken = String(localized: "companion.divertNotTaken")
        static let divertNoPosition = String(localized: "companion.divertNoPosition")
        static let divertNoAirportData = String(localized: "companion.divertNoAirportData")
        static let divertNoMatch = String(localized: "companion.divertNoMatch")
    }

    // MARK: - Aircraft requests (6.3.0)

    /// The request sheet, its entry points: the website's form and wording (aerocheck.app/send/).
    enum AircraftRequests {
        static let title = String(localized: "aircraftRequest.title")
        static let intro = String(localized: "aircraftRequest.intro")
        static let registrationSection = String(localized: "aircraftRequest.registrationSection")
        static let registrationLabel = String(localized: "aircraftRequest.registrationLabel")
        static let registrationHint = String(localized: "aircraftRequest.registrationHint")
        static let lookUp = String(localized: "aircraftRequest.lookUp")
        static let lookingUp = String(localized: "aircraftRequest.lookingUp")
        static func knownTitle(_ a0: String) -> String { String(format: String(localized: "aircraftRequest.knownTitle"), a0) }
        static let knownBody = String(localized: "aircraftRequest.knownBody")
        static let knownModel = String(localized: "aircraftRequest.knownModel")
        static let knownClub = String(localized: "aircraftRequest.knownClub")
        static let knownVersion = String(localized: "aircraftRequest.knownVersion")
        static let knownLanguages = String(localized: "aircraftRequest.knownLanguages")
        static func unknownTitle(_ a0: String) -> String { String(format: String(localized: "aircraftRequest.unknownTitle"), a0) }
        static let unknownBody = String(localized: "aircraftRequest.unknownBody")
        static let aircraftSection = String(localized: "aircraftRequest.aircraftSection")
        static let otherRegistrationsLabel = String(localized: "aircraftRequest.otherRegistrationsLabel")
        static let otherRegistrationsHint = String(localized: "aircraftRequest.otherRegistrationsHint")
        static let typeLabel = String(localized: "aircraftRequest.typeLabel")
        static let typeHint = String(localized: "aircraftRequest.typeHint")
        static let clubLabel = String(localized: "aircraftRequest.clubLabel")
        static let clubHint = String(localized: "aircraftRequest.clubHint")
        static let senderSection = String(localized: "aircraftRequest.senderSection")
        static let forClub = String(localized: "aircraftRequest.forClub")
        static let forClubHint = String(localized: "aircraftRequest.forClubHint")
        static let asPilot = String(localized: "aircraftRequest.asPilot")
        static let asPilotHint = String(localized: "aircraftRequest.asPilotHint")
        static let contactLabel = String(localized: "aircraftRequest.contactLabel")
        static let contactHint = String(localized: "aircraftRequest.contactHint")
        static let contactUnknown = String(localized: "aircraftRequest.contactUnknown")
        static let contactUnknownHint = String(localized: "aircraftRequest.contactUnknownHint")
        static let checklistSection = String(localized: "aircraftRequest.checklistSection")
        static let filesHintNew = String(localized: "aircraftRequest.filesHintNew")
        static let filesHintUpdate = String(localized: "aircraftRequest.filesHintUpdate")
        static let scan = String(localized: "aircraftRequest.scan")
        static let photos = String(localized: "aircraftRequest.photos")
        static let files = String(localized: "aircraftRequest.files")
        static let scanHint = String(localized: "aircraftRequest.scanHint")
        static func filesTotal(_ a0: Int, _ a1: String) -> String { String(format: String(localized: "aircraftRequest.filesTotal"), a0, a1) }
        static func remove(_ a0: String) -> String { String(format: String(localized: "aircraftRequest.remove"), a0) }
        static func fileUnreadable(_ a0: String) -> String { String(format: String(localized: "aircraftRequest.fileUnreadable"), a0) }
        static let languagesLabel = String(localized: "aircraftRequest.languagesLabel")
        static let languagesHint = String(localized: "aircraftRequest.languagesHint")
        static let otherLanguageLabel = String(localized: "aircraftRequest.otherLanguageLabel")
        static let otherLanguageHint = String(localized: "aircraftRequest.otherLanguageHint")
        static let youSection = String(localized: "aircraftRequest.youSection")
        static let nameLabel = String(localized: "aircraftRequest.nameLabel")
        static let nameHint = String(localized: "aircraftRequest.nameHint")
        static let emailLabel = String(localized: "aircraftRequest.emailLabel")
        static let emailHint = String(localized: "aircraftRequest.emailHint")
        static let notesLabel = String(localized: "aircraftRequest.notesLabel")
        static let notesHint = String(localized: "aircraftRequest.notesHint")
        static func counter(_ a0: Int, _ a1: Int) -> String { String(format: String(localized: "aircraftRequest.counter"), a0, a1) }
        static let rightsClub = String(localized: "aircraftRequest.rightsClub")
        static let rightsSelf = String(localized: "aircraftRequest.rightsSelf")
        static let rightsPrivate = String(localized: "aircraftRequest.rightsPrivate")
        static let privacyLabel = String(localized: "aircraftRequest.privacyLabel")
        static let termsLink = String(localized: "aircraftRequest.termsLink")
        static let privacyLink = String(localized: "aircraftRequest.privacyLink")
        static let checkLabel = String(localized: "aircraftRequest.checkLabel")
        static let checkLoading = String(localized: "aircraftRequest.checkLoading")
        static let checkWorking = String(localized: "aircraftRequest.checkWorking")
        static let checkPassed = String(localized: "aircraftRequest.checkPassed")
        static let checkFailed = String(localized: "aircraftRequest.checkFailed")
        static let checkMissing = String(localized: "aircraftRequest.checkMissing")
        static let submit = String(localized: "aircraftRequest.submit")
        static let progressSending = String(localized: "aircraftRequest.progressSending")
        static func progressUpload(_ a0: Int, _ a1: Int, _ a2: String) -> String { String(format: String(localized: "aircraftRequest.progressUpload"), a0, a1, a2) }
        static let progressFinishing = String(localized: "aircraftRequest.progressFinishing")
        static func uploadStopped(_ a0: String) -> String { String(format: String(localized: "aircraftRequest.uploadStopped"), a0) }
        static let summary = String(localized: "aircraftRequest.summary")
        static let problemRegistrationLookup = String(localized: "aircraftRequest.problem.registrationLookup")
        static func problemOtherRegistrationsInvalid(_ a0: String) -> String { String(format: String(localized: "aircraftRequest.problem.otherRegistrationsInvalid"), a0) }
        static let problemTooManyRegistrations = String(localized: "aircraftRequest.problem.tooManyRegistrations")
        static let problemTypeRequired = String(localized: "aircraftRequest.problem.typeRequired")
        static let problemSendingForRequired = String(localized: "aircraftRequest.problem.sendingForRequired")
        static let problemContactRequired = String(localized: "aircraftRequest.problem.contactRequired")
        static let problemContactInvalid = String(localized: "aircraftRequest.problem.contactInvalid")
        static let problemContactIsSender = String(localized: "aircraftRequest.problem.contactIsSender")
        static let problemEmailRequired = String(localized: "aircraftRequest.problem.emailRequired")
        static let problemEmailInvalid = String(localized: "aircraftRequest.problem.emailInvalid")
        static let problemLanguagesRequired = String(localized: "aircraftRequest.problem.languagesRequired")
        static func problemLanguageInvalid(_ a0: String) -> String { String(format: String(localized: "aircraftRequest.problem.languageInvalid"), a0) }
        static let problemLanguagesTooMany = String(localized: "aircraftRequest.problem.languagesTooMany")
        static let problemFilesRequired = String(localized: "aircraftRequest.problem.filesRequired")
        static let problemTooManyFiles = String(localized: "aircraftRequest.problem.tooManyFiles")
        static func problemFileTooBig(_ a0: String, _ a1: String) -> String { String(format: String(localized: "aircraftRequest.problem.fileTooBig"), a0, a1) }
        static func problemTotalTooBig(_ a0: String) -> String { String(format: String(localized: "aircraftRequest.problem.totalTooBig"), a0) }
        static let problemNotesTooLong = String(localized: "aircraftRequest.problem.notesTooLong")
        static let problemRightsRequired = String(localized: "aircraftRequest.problem.rightsRequired")
        static let problemPrivacyRequired = String(localized: "aircraftRequest.problem.privacyRequired")
        static let errorNetwork = String(localized: "aircraftRequest.error.network")
        static let errorInvalidRegistration = String(localized: "aircraftRequest.error.invalidRegistration")
        static let errorInvalidEmail = String(localized: "aircraftRequest.error.invalidEmail")
        static let errorClubContactIsSender = String(localized: "aircraftRequest.error.clubContactIsSender")
        static let errorFiles = String(localized: "aircraftRequest.error.files")
        static let errorUnknownRegistration = String(localized: "aircraftRequest.error.unknownRegistration")
        static let errorKnownRegistration = String(localized: "aircraftRequest.error.knownRegistration")
        static func errorKnownOthers(_ a0: String) -> String { String(format: String(localized: "aircraftRequest.error.knownOthers"), a0) }
        static let errorListChanged = String(localized: "aircraftRequest.error.listChanged")
        static let errorSizeMismatch = String(localized: "aircraftRequest.error.sizeMismatch")
        static let errorTurnstileFailed = String(localized: "aircraftRequest.error.turnstileFailed")
        static let errorUploadGone = String(localized: "aircraftRequest.error.uploadGone")
        static func errorAlreadySent(_ a0: String) -> String { String(format: String(localized: "aircraftRequest.error.alreadySent"), a0) }
        static let errorPayloadTooLarge = String(localized: "aircraftRequest.error.payloadTooLarge")
        static let errorRateLimited = String(localized: "aircraftRequest.error.rateLimited")
        static let errorInternal = String(localized: "aircraftRequest.error.internal")
        static let errorUnavailable = String(localized: "aircraftRequest.error.unavailable")
        static let errorDailyCap = String(localized: "aircraftRequest.error.dailyCap")
        static let errorLookupUnavailable = String(localized: "aircraftRequest.error.lookupUnavailable")
        static let errorField = String(localized: "aircraftRequest.error.field")
        static let errorUnknown = String(localized: "aircraftRequest.error.unknown")
        static func resultTitle(_ a0: String) -> String { String(format: String(localized: "aircraftRequest.resultTitle"), a0) }
        static func resultBody(_ a0: String) -> String { String(format: String(localized: "aircraftRequest.resultBody"), a0) }
        static let nextTitle = String(localized: "aircraftRequest.nextTitle")
        static let nextBody = String(localized: "aircraftRequest.nextBody")
        static let nextClub = String(localized: "aircraftRequest.nextClub")
        static let nextClubNoContact = String(localized: "aircraftRequest.nextClubNoContact")
        static let openPage = String(localized: "aircraftRequest.openPage")
        static let entryTitle = String(localized: "aircraftRequest.entryTitle")
        static let entrySubtitle = String(localized: "aircraftRequest.entrySubtitle")
        static let menuItem = String(localized: "aircraftRequest.menuItem")
        static let proLine = String(localized: "aircraftRequest.proLine")
        static let onboardingLine = String(localized: "aircraftRequest.onboardingLine")
        static let requestsSection = String(localized: "aircraftRequest.requestsSection")
        static let requestsFooter = String(localized: "aircraftRequest.requestsFooter")
        static let removeFromList = String(localized: "aircraftRequest.removeFromList")
        static func liveTitle(_ registrations: String) -> String { String(format: String(localized: "aircraftRequest.liveTitle"), registrations) }
        static func liveBody(_ aircraftType: String) -> String { String(format: String(localized: "aircraftRequest.liveBody"), aircraftType) }

        /// A request's status as the website's status page names it, and its line.
        static func status(_ status: AircraftRequestStatus) -> (label: String, line: String) {
            switch status {
            case .uploading, .received:
                return (String(localized: "aircraftRequest.status.received"), String(localized: "aircraftRequest.status.receivedLine"))
            case .accepted:
                return (String(localized: "aircraftRequest.status.accepted"), String(localized: "aircraftRequest.status.acceptedLine"))
            case .converting:
                return (String(localized: "aircraftRequest.status.converting"), String(localized: "aircraftRequest.status.convertingLine"))
            case .proofreading:
                return (String(localized: "aircraftRequest.status.proofreading"), String(localized: "aircraftRequest.status.proofreadingLine"))
            case .testflight:
                return (String(localized: "aircraftRequest.status.testflight"), String(localized: "aircraftRequest.status.testflightLine"))
            case .live:
                return (String(localized: "aircraftRequest.status.live"), String(localized: "aircraftRequest.status.liveLine"))
            case .needInfo:
                return (String(localized: "aircraftRequest.status.needInfo"), String(localized: "aircraftRequest.status.needInfoLine"))
            case .declined:
                return (String(localized: "aircraftRequest.status.declined"), String(localized: "aircraftRequest.status.declinedLine"))
            case .duplicate:
                return (String(localized: "aircraftRequest.status.duplicate"), String(localized: "aircraftRequest.status.duplicateLine"))
            }
        }
    }

    /// Dry run (6.4.0): the app flown on the ground through the real Cockpit.
    enum DryRun {
        static let band = String(localized: "dryRun.band")
        static let paused = String(localized: "dryRun.paused")
        static let waiting = String(localized: "dryRun.waiting")
        static let waitingShort = String(localized: "dryRun.waitingShort")
        static let skipping = String(localized: "dryRun.skipping")
        static let over = String(localized: "dryRun.over")
        static let overTitle = String(localized: "dryRun.overTitle")
        static let pause = String(localized: "dryRun.pause")
        static let resume = String(localized: "dryRun.resume")
        static func paceAccessibility(_ a0: String) -> String { String(format: String(localized: "dryRun.paceAccessibility"), a0) }
        static let nextCheck = String(localized: "dryRun.nextCheck")
        static let onThisFinal = String(localized: "dryRun.onThisFinal")
        static let onThisFinalShort = String(localized: "dryRun.onThisFinalShort")
        static let finalCardOnly = String(localized: "dryRun.finalCardOnly")
        static let pausedTitle = String(localized: "dryRun.pausedTitle")
        static let fullStop = String(localized: "dryRun.fullStop")
        static let endDryRun = String(localized: "dryRun.endDryRun")
        static let checks = String(localized: "dryRun.checks")
        static let landings = String(localized: "dryRun.landings")
        static let circuitsFigure = String(localized: "dryRun.circuitsFigure")
        static let time = String(localized: "dryRun.time")
        static let nothingSaved = String(localized: "dryRun.nothingSaved")
        static let again = String(localized: "dryRun.again")
        static let done = String(localized: "dryRun.done")
        static let nextGoAround = String(localized: "dryRun.nextGoAround")
        static let nextTouchAndGo = String(localized: "dryRun.nextTouchAndGo")
        static let nextRoute = String(localized: "dryRun.nextRoute")
        static let nextCircuits = String(localized: "dryRun.nextCircuits")
        static let nextDivert = String(localized: "dryRun.nextDivert")
        static func takeoffAt(_ a0: String) -> String { String(format: String(localized: "dryRun.takeoffAt"), a0) }
        static func touchAndGoAt(_ a0: String) -> String { String(format: String(localized: "dryRun.touchAndGoAt"), a0) }
        static func goAroundAt(_ a0: String) -> String { String(format: String(localized: "dryRun.goAroundAt"), a0) }
        static func fullStopAt(_ a0: String) -> String { String(format: String(localized: "dryRun.fullStopAt"), a0) }
        static func circuitsAt(_ a0: String) -> String { String(format: String(localized: "dryRun.circuitsAt"), a0) }
        static let startTitle = String(localized: "dryRun.startTitle")
        static let startIntro = String(localized: "dryRun.startIntro")
        static let what = String(localized: "dryRun.what")
        static let theRoute = String(localized: "dryRun.theRoute")
        static let circuits = String(localized: "dryRun.circuits")
        static let aerodrome = String(localized: "dryRun.aerodrome")
        static let looking = String(localized: "dryRun.looking")
        static func noRunway(_ a0: String) -> String { String(format: String(localized: "dryRun.noRunway"), a0) }
        static let typeCode = String(localized: "dryRun.typeCode")
        static let routeTooShort = String(localized: "dryRun.routeTooShort")
        static let noAirportData = String(localized: "dryRun.noAirportData")
        static let aircraft = String(localized: "dryRun.aircraft")
        static let pace = String(localized: "dryRun.pace")
        static let startFooter = String(localized: "dryRun.startFooter")
        static let fly = String(localized: "dryRun.fly")
        static func leftHand(_ a0: String) -> String { String(format: String(localized: "dryRun.leftHand"), a0) }
        static func rightHand(_ a0: String) -> String { String(format: String(localized: "dryRun.rightHand"), a0) }
        static func runway(_ a0: String) -> String { String(format: String(localized: "dryRun.runway"), a0) }
        static let checklistUnavailable = String(localized: "dryRun.checklistUnavailable")
        static let busy = String(localized: "dryRun.busy")
        static let refused = String(localized: "dryRun.refused")
        static let settingsRow = String(localized: "dryRun.settingsRow")
        static let settingsRowSubtitle = String(localized: "dryRun.settingsRowSubtitle")
        static let flyRoute = String(localized: "dryRun.flyRoute")
    }

    /// Dry run (6.4.0): the guided flight and its coach.
    enum DryRunCoach {
        static let chapter1 = String(localized: "dryRunCoach.chapter1")
        static let chapter2 = String(localized: "dryRunCoach.chapter2")
        static let chapter3 = String(localized: "dryRunCoach.chapter3")
        static let chapter4 = String(localized: "dryRunCoach.chapter4")
        static let chapter5 = String(localized: "dryRunCoach.chapter5")
        static let chapter6 = String(localized: "dryRunCoach.chapter6")
        static let chapter7 = String(localized: "dryRunCoach.chapter7")
        static let habit1 = String(localized: "dryRunCoach.habit1")
        static let habit2 = String(localized: "dryRunCoach.habit2")
        static let habit3 = String(localized: "dryRunCoach.habit3")
        static let habit4 = String(localized: "dryRunCoach.habit4")
        static let habit5 = String(localized: "dryRunCoach.habit5")
        static let habit6 = String(localized: "dryRunCoach.habit6")
        static let habit7 = String(localized: "dryRunCoach.habit7")
        static func turningPointNumber(_ a0: Int) -> String { String(format: String(localized: "dryRunCoach.turningPointNumber"), a0) }
        static let flightName = String(localized: "dryRunCoach.flightName")
        static func chapterOf(_ a0: Int, _ a1: Int) -> String { String(format: String(localized: "dryRunCoach.chapterOf"), a0, a1) }
        static let next = String(localized: "dryRunCoach.next")
        static let pause = String(localized: "dryRunCoach.pause")
        static let goOn = String(localized: "dryRunCoach.goOn")
        static let showAgain = String(localized: "dryRunCoach.showAgain")
        static let habitsTitle = String(localized: "dryRunCoach.habitsTitle")
        static let nextFree = String(localized: "dryRunCoach.nextFree")
        static let todayTitle = String(localized: "dryRunCoach.todayTitle")
        static let todayBody = String(localized: "dryRunCoach.todayBody")
        static let todayStart = String(localized: "dryRunCoach.todayStart")
        static let todayNotNow = String(localized: "dryRunCoach.todayNotNow")
        static let onboardingFly = String(localized: "dryRunCoach.onboardingFly")
        static let chaptersFooter = String(localized: "dryRunCoach.chaptersFooter")

        /// The steps' words, by the step's id (`DryRunChapters.steps`).
        enum Step {
            static let todayTitle = String(localized: "dryRunCoach.step.today.title")
            static let todayBody = String(localized: "dryRunCoach.step.today.body")
            static let planSheetTitle = String(localized: "dryRunCoach.step.planSheet.title")
            static let planSheetBody = String(localized: "dryRunCoach.step.planSheet.body")
            static let flightPageTitle = String(localized: "dryRunCoach.step.flightPage.title")
            static let flightPageBody = String(localized: "dryRunCoach.step.flightPage.body")
            static let nextCardTitle = String(localized: "dryRunCoach.step.nextCard.title")
            static let nextCardBody = String(localized: "dryRunCoach.step.nextCard.body")
            static let fuelRowTitle = String(localized: "dryRunCoach.step.fuelRow.title")
            static let fuelRowBody = String(localized: "dryRunCoach.step.fuelRow.body")
            static let fuelSheetTitle = String(localized: "dryRunCoach.step.fuelSheet.title")
            static let fuelSheetBody = String(localized: "dryRunCoach.step.fuelSheet.body")
            static let fuelDoneTitle = String(localized: "dryRunCoach.step.fuelDone.title")
            static let fuelDoneBody = String(localized: "dryRunCoach.step.fuelDone.body")
            static let linkTitle = String(localized: "dryRunCoach.step.link.title")
            static let linkBody = String(localized: "dryRunCoach.step.link.body")
            static let notApplicableTitle = String(localized: "dryRunCoach.step.notApplicable.title")
            static let notApplicableBody = String(localized: "dryRunCoach.step.notApplicable.body")
            static let startFlightTitle = String(localized: "dryRunCoach.step.startFlight.title")
            static let startFlightBody = String(localized: "dryRunCoach.step.startFlight.body")
            static let cockpitAfterPlanTitle = String(localized: "dryRunCoach.step.cockpitAfterPlan.title")
            static let cockpitAfterPlanBody = String(localized: "dryRunCoach.step.cockpitAfterPlan.body")
            static let closeOutTitle = String(localized: "dryRunCoach.step.closeOut.title")
            static let closeOutBody = String(localized: "dryRunCoach.step.closeOut.body")
            static let logbookLineTitle = String(localized: "dryRunCoach.step.logbookLine.title")
            static let logbookLineBody = String(localized: "dryRunCoach.step.logbookLine.body")
            static let numbersTitle = String(localized: "dryRunCoach.step.numbers.title")
            static let numbersBody = String(localized: "dryRunCoach.step.numbers.body")
            static let tickLogbookTitle = String(localized: "dryRunCoach.step.tickLogbook.title")
            static let tickLogbookBody = String(localized: "dryRunCoach.step.tickLogbook.body")
            static let debriefTitle = String(localized: "dryRunCoach.step.debrief.title")
            static let debriefBody = String(localized: "dryRunCoach.step.debrief.body")
            static let finishTitle = String(localized: "dryRunCoach.step.finish.title")
            static let finishBody = String(localized: "dryRunCoach.step.finish.body")
            static let logbookTabTitle = String(localized: "dryRunCoach.step.logbookTab.title")
            static let logbookTabBody = String(localized: "dryRunCoach.step.logbookTab.body")
            static let dashboardTitle = String(localized: "dryRunCoach.step.dashboard.title")
            static let dashboardBody = String(localized: "dryRunCoach.step.dashboard.body")
            static let trackTitle = String(localized: "dryRunCoach.step.track.title")
            static let trackBody = String(localized: "dryRunCoach.step.track.body")
            static let exportsTitle = String(localized: "dryRunCoach.step.exports.title")
            static let exportsBody = String(localized: "dryRunCoach.step.exports.body")
            static let tickNotamTitle = String(localized: "dryRunCoach.step.tickNotam.title")
            static let tickNotamBody = String(localized: "dryRunCoach.step.tickNotam.body")
            static let openLoggedFlightTitle = String(localized: "dryRunCoach.step.openLoggedFlight.title")
            static let openLoggedFlightBody = String(localized: "dryRunCoach.step.openLoggedFlight.body")
            static let openFlightPageTitle = String(localized: "dryRunCoach.step.openFlightPage.title")
            static let openFlightPageBody = String(localized: "dryRunCoach.step.openFlightPage.body")
            static let cockpitTitle = String(localized: "dryRunCoach.step.cockpit.title")
            static let cockpitBody = String(localized: "dryRunCoach.step.cockpit.body")
            static let checkOnceTitle = String(localized: "dryRunCoach.step.checkOnce.title")
            static let checkOnceBody = String(localized: "dryRunCoach.step.checkOnce.body")
            static let memoryTestTitle = String(localized: "dryRunCoach.step.memoryTest.title")
            static let memoryTestBody = String(localized: "dryRunCoach.step.memoryTest.body")
            static let toEngineStartTitle = String(localized: "dryRunCoach.step.toEngineStart.title")
            static let toEngineStartBody = String(localized: "dryRunCoach.step.toEngineStart.body")
            static let hoursBeforeTitle = String(localized: "dryRunCoach.step.hoursBefore.title")
            static let hoursBeforeBody = String(localized: "dryRunCoach.step.hoursBefore.body")
            static let engineStartTitle = String(localized: "dryRunCoach.step.engineStart.title")
            static let engineStartBody = String(localized: "dryRunCoach.step.engineStart.body")
            static let deferTitle = String(localized: "dryRunCoach.step.defer.title")
            static let deferBody = String(localized: "dryRunCoach.step.defer.body")
            static let deferredChipTitle = String(localized: "dryRunCoach.step.deferredChip.title")
            static let deferredChipBody = String(localized: "dryRunCoach.step.deferredChip.body")
            static let toBeforeDepartureTitle = String(localized: "dryRunCoach.step.toBeforeDeparture.title")
            static let toBeforeDepartureBody = String(localized: "dryRunCoach.step.toBeforeDeparture.body")
            static let toBeforeDepartureUpcoming = String(localized: "dryRunCoach.step.toBeforeDeparture.upcoming")
            static let readyForLineUpTitle = String(localized: "dryRunCoach.step.readyForLineUp.title")
            static let readyForLineUpBody = String(localized: "dryRunCoach.step.readyForLineUp.body")
            static let lineUpCheckTitle = String(localized: "dryRunCoach.step.lineUpCheck.title")
            static let lineUpCheckBody = String(localized: "dryRunCoach.step.lineUpCheck.body")
            static let mapTakeoffTitle = String(localized: "dryRunCoach.step.mapTakeoff.title")
            static let mapTakeoffBody = String(localized: "dryRunCoach.step.mapTakeoff.body")
            static let airborneTitle = String(localized: "dryRunCoach.step.airborne.title")
            static let airborneBody = String(localized: "dryRunCoach.step.airborne.body")
            static let climbCheckTitle = String(localized: "dryRunCoach.step.climbCheck.title")
            static let climbCheckBody = String(localized: "dryRunCoach.step.climbCheck.body")
            static let climbCheckUpcoming = String(localized: "dryRunCoach.step.climbCheck.upcoming")
            static let readBandTitle = String(localized: "dryRunCoach.step.readBand.title")
            static let readBandBody = String(localized: "dryRunCoach.step.readBand.body")
            static let cruiseCheckTitle = String(localized: "dryRunCoach.step.cruiseCheck.title")
            static let cruiseCheckBody = String(localized: "dryRunCoach.step.cruiseCheck.body")
            static let cruiseCheckUpcoming = String(localized: "dryRunCoach.step.cruiseCheck.upcoming")
            static let radioDueTitle = String(localized: "dryRunCoach.step.radioDue.title")
            static let radioDueBody = String(localized: "dryRunCoach.step.radioDue.body")
            static let radioDueFold = String(localized: "dryRunCoach.step.radioDue.fold")
            static let routePageTitle = String(localized: "dryRunCoach.step.routePage.title")
            static let routePageBody = String(localized: "dryRunCoach.step.routePage.body")
            static let timeOverTitle = String(localized: "dryRunCoach.step.timeOver.title")
            static let timeOverBody = String(localized: "dryRunCoach.step.timeOver.body")
            static let legControlsTitle = String(localized: "dryRunCoach.step.legControls.title")
            static let legControlsBody = String(localized: "dryRunCoach.step.legControls.body")
            static let mapAgainTitle = String(localized: "dryRunCoach.step.mapAgain.title")
            static let mapAgainBody = String(localized: "dryRunCoach.step.mapAgain.body")
            static let descentCheckTitle = String(localized: "dryRunCoach.step.descentCheck.title")
            static let descentCheckBody = String(localized: "dryRunCoach.step.descentCheck.body")
            static let descentCheckUpcoming = String(localized: "dryRunCoach.step.descentCheck.upcoming")
            static let approachCheckTitle = String(localized: "dryRunCoach.step.approachCheck.title")
            static let approachCheckBody = String(localized: "dryRunCoach.step.approachCheck.body")
            static let approachCheckUpcoming = String(localized: "dryRunCoach.step.approachCheck.upcoming")
            static let landingShownTitle = String(localized: "dryRunCoach.step.landingShown.title")
            static let landingShownBody = String(localized: "dryRunCoach.step.landingShown.body")
            static let landingShownMemoryBody = String(localized: "dryRunCoach.step.landingShown.memoryBody")
            static let goAroundTitle = String(localized: "dryRunCoach.step.goAround.title")
            static let goAroundBody = String(localized: "dryRunCoach.step.goAround.body")
            static let goAroundUpcoming = String(localized: "dryRunCoach.step.goAround.upcoming")
            static let goAroundCardTitle = String(localized: "dryRunCoach.step.goAroundCard.title")
            static let goAroundCardBody = String(localized: "dryRunCoach.step.goAroundCard.body")
            static let climbAgainTitle = String(localized: "dryRunCoach.step.climbAgain.title")
            static let climbAgainBody = String(localized: "dryRunCoach.step.climbAgain.body")
            static let climbAgainUpcoming = String(localized: "dryRunCoach.step.climbAgain.upcoming")
            static let memorySwitchTitle = String(localized: "dryRunCoach.step.memorySwitch.title")
            static let memorySwitchBody = String(localized: "dryRunCoach.step.memorySwitch.body")
            static let toAfterStartTitle = String(localized: "dryRunCoach.step.toAfterStart.title")
            static let toAfterStartBody = String(localized: "dryRunCoach.step.toAfterStart.body")
            static let toEngineStartFold = String(localized: "dryRunCoach.step.toEngineStart.fold")
            static let engineStartCheckFold = String(localized: "dryRunCoach.step.engineStartCheck.fold")
            static let afterStartFold = String(localized: "dryRunCoach.step.afterStart.fold")
            static let toBeforeDepartureFold = String(localized: "dryRunCoach.step.toBeforeDeparture.fold")
            static let lineUpCheckFold = String(localized: "dryRunCoach.step.lineUpCheck.fold")
            static let climbCheckFold = String(localized: "dryRunCoach.step.climbCheck.fold")
            static let cruiseCheckFold = String(localized: "dryRunCoach.step.cruiseCheck.fold")
            static let descentCheckFold = String(localized: "dryRunCoach.step.descentCheck.fold")
            static let approachCheckFold = String(localized: "dryRunCoach.step.approachCheck.fold")
            static let climbAgainFold = String(localized: "dryRunCoach.step.climbAgain.fold")
            static let approachAgainFold = String(localized: "dryRunCoach.step.approachAgain.fold")
            static let fullStopFold = String(localized: "dryRunCoach.step.fullStop.fold")
            static let fullStopMemoryFold = String(localized: "dryRunCoach.step.fullStop.memoryFold")
            static let toShutdownFold = String(localized: "dryRunCoach.step.toShutdown.fold")
            static let shutdownCheckFold = String(localized: "dryRunCoach.step.shutdownCheck.fold")
            static let toEndFlightFold = String(localized: "dryRunCoach.step.toEndFlight.fold")
            static let engineStartCheckTitle = String(localized: "dryRunCoach.step.engineStartCheck.title")
            static let engineStartCheckBody = String(localized: "dryRunCoach.step.engineStartCheck.body")
            static let afterStartTitle = String(localized: "dryRunCoach.step.afterStart.title")
            static let afterStartBody = String(localized: "dryRunCoach.step.afterStart.body")
            static let shutdownCheckTitle = String(localized: "dryRunCoach.step.shutdownCheck.title")
            static let shutdownCheckBody = String(localized: "dryRunCoach.step.shutdownCheck.body")
            static let approachAgainTitle = String(localized: "dryRunCoach.step.approachAgain.title")
            static let approachAgainBody = String(localized: "dryRunCoach.step.approachAgain.body")
            static let approachAgainUpcoming = String(localized: "dryRunCoach.step.approachAgain.upcoming")
            static let fullStopTitle = String(localized: "dryRunCoach.step.fullStop.title")
            static let fullStopBody = String(localized: "dryRunCoach.step.fullStop.body")
            static let fullStopMemoryBody = String(localized: "dryRunCoach.step.fullStop.memoryBody")
            static let toShutdownTitle = String(localized: "dryRunCoach.step.toShutdown.title")
            static let toShutdownBody = String(localized: "dryRunCoach.step.toShutdown.body")
            static let engineShutdownTitle = String(localized: "dryRunCoach.step.engineShutdown.title")
            static let engineShutdownBody = String(localized: "dryRunCoach.step.engineShutdown.body")
            static let engineShutdownUpcoming = String(localized: "dryRunCoach.step.engineShutdown.upcoming")
            static let hoursAfterTitle = String(localized: "dryRunCoach.step.hoursAfter.title")
            static let hoursAfterBody = String(localized: "dryRunCoach.step.hoursAfter.body")
            static let toEndFlightTitle = String(localized: "dryRunCoach.step.toEndFlight.title")
            static let toEndFlightBody = String(localized: "dryRunCoach.step.toEndFlight.body")
            static let endFlightTitle = String(localized: "dryRunCoach.step.endFlight.title")
            static let endFlightBody = String(localized: "dryRunCoach.step.endFlight.body")
        }

        /// The folded card: what the aircraft does.
        enum Doing {
            static let parked = String(localized: "dryRunCoach.doing.parked")
            static let taxiing = String(localized: "dryRunCoach.doing.taxiing")
            static let holding = String(localized: "dryRunCoach.doing.holding")
            static let liningUp = String(localized: "dryRunCoach.doing.liningUp")
            static let takeoffRoll = String(localized: "dryRunCoach.doing.takeoffRoll")
            static let climbingOut = String(localized: "dryRunCoach.doing.climbingOut")
            static let climbing = String(localized: "dryRunCoach.doing.climbing")
            static func cruising(_ a0: String) -> String { String(format: String(localized: "dryRunCoach.doing.cruising"), a0) }
            static let descending = String(localized: "dryRunCoach.doing.descending")
            static let joining = String(localized: "dryRunCoach.doing.joining")
            static let upwind = String(localized: "dryRunCoach.doing.upwind")
            static let crosswind = String(localized: "dryRunCoach.doing.crosswind")
            static let downwind = String(localized: "dryRunCoach.doing.downwind")
            static let base = String(localized: "dryRunCoach.doing.base")
            static let final = String(localized: "dryRunCoach.doing.final")
            static let goingAround = String(localized: "dryRunCoach.doing.goingAround")
            static let landing = String(localized: "dryRunCoach.doing.landing")
            static let stopped = String(localized: "dryRunCoach.doing.stopped")
            static let taxiingIn = String(localized: "dryRunCoach.doing.taxiingIn")
            static let parkedEnd = String(localized: "dryRunCoach.doing.parkedEnd")
        }
        static func nextForYou(_ a0: String) -> String { String(format: String(localized: "dryRunCoach.nextForYou"), a0) }
        static func coverTitle(_ a0: Int) -> String { String(format: String(localized: "dryRunCoach.coverTitle"), a0) }
        static let coverBody = String(localized: "dryRunCoach.coverBody")
        static let learnGroup = String(localized: "dryRunCoach.learnGroup")
        static let part1 = String(localized: "dryRunCoach.part1")
        static let part2 = String(localized: "dryRunCoach.part2")
        static let part3 = String(localized: "dryRunCoach.part3")
        static let part4 = String(localized: "dryRunCoach.part4")
        static let habitPlan = String(localized: "dryRunCoach.habitPlan")
        static let habitClose = String(localized: "dryRunCoach.habitClose")
        static let habitLogbook = String(localized: "dryRunCoach.habitLogbook")
        static func partDone(_ a0: String) -> String { String(format: String(localized: "dryRunCoach.partDone"), a0) }
        static let nextFly = String(localized: "dryRunCoach.nextFly")
        static let nextClose = String(localized: "dryRunCoach.nextClose")
        static let nextLogbook = String(localized: "dryRunCoach.nextLogbook")
        static func onTo(_ a0: String) -> String { String(format: String(localized: "dryRunCoach.onTo"), a0) }
        static let stopHere = String(localized: "dryRunCoach.stopHere")
        static let stopHereNote = String(localized: "dryRunCoach.stopHereNote")
        static let linkKeptTitle = String(localized: "dryRunCoach.linkKeptTitle")
        static func linkKept(_ a0: String) -> String { String(format: String(localized: "dryRunCoach.linkKept"), a0) }
        static let end = String(localized: "dryRunCoach.end")
        static let coverTitlePart = String(localized: "dryRunCoach.coverTitlePart")
        static let storyNothingKept = String(localized: "dryRunCoach.storyNothingKept")
        static let storyRow = String(localized: "dryRunCoach.storyRow")
        static let storyRowSubtitle = String(localized: "dryRunCoach.storyRowSubtitle")
        static let partsRow = String(localized: "dryRunCoach.partsRow")
        static let partsFooter = String(localized: "dryRunCoach.partsFooter")
        static let flyChapters = String(localized: "dryRunCoach.flyChapters")
        static func partOf(_ part: Int, _ count: Int) -> String {
            String(format: String(localized: "dryRunCoach.partOf"), part, count)
        }
        static let fold = String(localized: "dryRunCoach.fold")
        static let memoryCheckNote = String(localized: "dryRunCoach.memoryCheckNote")
        static let unfold = String(localized: "dryRunCoach.unfold")
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
