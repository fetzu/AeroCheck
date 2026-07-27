//
//  APIConfig.swift
//  AeroCheck
//
//  Build-configuration-driven API endpoint. (SEC-C2 / SUB-2)
//

import Foundation

/// Resolves the AeroCheck API base URL for this build.
///
/// The endpoint used to be a hardcoded default argument on two service initialisers. It has to be
/// resolved dynamically now because the production worker refuses Sandbox StoreKit transactions — a
/// TestFlight purchase is free and unlimited, so honouring it in production handed out the whole
/// premium catalogue. Sandbox builds therefore talk to the sandbox worker, which is the only way
/// the paid flow stays testable.
///
/// **Why this is a runtime check and not `[config=Debug]` in the xcconfig.** TestFlight distributes
/// the *Release* configuration, byte-identical in build settings to an App Store build — there is no
/// build setting that separates them. Selecting the endpoint by configuration therefore sent every
/// TestFlight build to production, which rejected its Sandbox JWS with `SANDBOX_IN_PRODUCTION`
/// (HTTP 400). The visible symptom was the worst kind: StoreKit reported a valid local entitlement
/// so the UI claimed "Lifetime access", while the server never minted a session token, so every
/// premium checklist stayed locked and only the bundled WT9 was usable.
///
/// The receipt environment is the same signal the server keys on, so client and server now agree by
/// construction: a Sandbox receipt goes to the worker that accepts Sandbox transactions.
///
/// Value flows: `Config.xcconfig` (`API_BASE_URL`, `API_BASE_URL_SANDBOX`) → `Info.plist`
/// (`APIBaseURL`, `APIBaseURLSandbox`) → here.
enum APIConfig {

    /// Fallback used only if the Info.plist key is missing or unusable (e.g. a stale build).
    /// Production is the safe default: a sandbox build that silently pointed at production shows up
    /// immediately (purchases stop verifying), whereas the reverse would quietly widen access.
    private static let fallback = "https://api.aerocheck.app"

    /// Whether this build should talk to the sandbox worker rather than production.
    ///
    /// Two independent signals, because neither covers both cases:
    ///
    /// - `#if DEBUG` covers local development. A simulator or `xcodebuild` install has no App Store
    ///   receipt at all, so the receipt check below cannot see it, and a dev build must never be
    ///   pointed at production. This preserves the behaviour the old `API_BASE_URL[config=Debug]`
    ///   xcconfig line provided.
    /// - The receipt filename covers TestFlight, which ships the *Release* configuration and is
    ///   therefore invisible to any compile-time check. This is the case the xcconfig approach
    ///   could not express, and the reason premium content silently stayed locked in TestFlight.
    ///
    /// The receipt *URL* is used rather than the receipt contents: the filename is set by the
    /// installer and is readable synchronously with no StoreKit call and no network, which matters
    /// because `baseURL` is resolved eagerly by services at startup. `AppTransaction.shared` is the
    /// StoreKit 2 equivalent but it is async and can fail while offline — unacceptable for a value
    /// every API call depends on, in an app routinely flown without a network.
    static let usesSandboxEndpoint: Bool = {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }()

    /// Reads and validates one Info.plist endpoint key, returning nil if absent or unusable.
    private static func endpoint(forKey key: String) -> String? {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
            case let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            // An unexpanded build setting ("$(API_BASE_URL)") must not be treated as a URL.
            !trimmed.hasPrefix("$"),
            let url = URL(string: trimmed),
            url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1"
        else {
            return nil
        }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    /// The API base URL, without a trailing slash.
    static let baseURL: String = {
        if usesSandboxEndpoint, let sandbox = endpoint(forKey: "APIBaseURLSandbox") {
            AppLog.general.publicLine("Sandbox build detected; using sandbox API endpoint")
            return sandbox
        }
        guard let production = endpoint(forKey: "APIBaseURL") else {
            AppLog.general.publicLine("APIBaseURL missing or invalid; using production endpoint")
            return fallback
        }
        return production
    }()

    /// Weather proxy base URL, without a trailing slash.
    ///
    /// A DIFFERENT worker from `baseURL`, deliberately. `api.aerocheck.app` is the entitlement
    /// authority; this is a public, unauthenticated cache in front of Open-Meteo. Keeping them apart
    /// means weather traffic cannot consume the entitlement worker's request budget or attack
    /// surface. There is no sandbox twin — a forecast is the same forecast in every build, and it
    /// carries no entitlement.
    static let weatherBaseURL: String = {
        endpoint(forKey: "WeatherBaseURL") ?? "https://wx.aerocheck.app"
    }()

    /// Shared secret sent as `X-AeroCheck-Client` to the weather proxy, or nil when not configured.
    ///
    /// A SPEED BUMP, not a credential. It stops someone reading the public repository from pointing
    /// their own app or site at wx.aerocheck.app; it stops nobody willing to run `strings` on the
    /// IPA. Nothing behind it is worth protecting — it fronts free public weather data. Treat a
    /// leak as a reason to rotate (add a value to the worker's list, ship an update, retire the
    /// old one), not as an incident.
    ///
    /// Absent is fine and must stay fine: the worker fails open when its own list is unset, so a
    /// checkout without Secrets.xcconfig still gets working weather.
    static let weatherClientSecret: String? = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "WeatherClientSecret") as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded build setting ("$(WEATHER_CLIENT_SECRET)") must never be sent as a header —
        // it would be a guaranteed mismatch that looks like a configured client. Same guard the
        // endpoint reader applies. (Happens when the setting is undefined rather than empty.)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$") else { return nil }
        return trimmed
    }()
}
