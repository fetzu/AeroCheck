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
/// build-driven now because the production worker refuses Sandbox StoreKit transactions — a
/// TestFlight purchase is free and unlimited, so honouring it in production handed out the whole
/// premium catalogue. Debug/TestFlight builds therefore talk to the sandbox worker, which is the
/// only way the paid flow stays testable.
///
/// Value flows: `Config.xcconfig` (`API_BASE_URL`) → `Info.plist` (`APIBaseURL`) → here.
enum APIConfig {

    /// Fallback used only if the Info.plist key is missing or unusable (e.g. a stale build).
    /// Production is the safe default: a Debug build that silently pointed at production would be
    /// noticed immediately (sandbox purchases stop verifying), whereas the reverse would not.
    private static let fallback = "https://api.aerocheck.app"

    /// The API base URL, without a trailing slash.
    static let baseURL: String = {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String,
            case let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            // An unexpanded build setting ("$(API_BASE_URL)") must not be treated as a URL.
            !trimmed.hasPrefix("$"),
            let url = URL(string: trimmed),
            url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1"
        else {
            AppLog.general.publicLine("APIBaseURL missing or invalid; using production endpoint")
            return fallback
        }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }()
}
