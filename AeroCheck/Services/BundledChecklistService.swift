import Foundation

/// Service for loading and managing bundled aircraft checklists.
/// Bundled checklists are included with the app and serve as fallback when offline
/// or when the API returns an older version.
enum BundledChecklistService {

    // MARK: - Bundled Aircraft Configuration

    /// Configuration for bundled aircraft including available languages
    struct BundledAircraftConfig {
        let aircraftId: String
        let defaultLanguage: String
        let availableLanguages: [String]
        let resourceNames: [String: String] // language -> resource name mapping
    }

    /// Aircraft IDs that are bundled with the app
    static let bundledAircraftIds: Set<String> = ["wt9-dynamic"]

    /// Configuration for each bundled aircraft
    private static let bundledAircraftConfigs: [String: BundledAircraftConfig] = [
        "wt9-dynamic": BundledAircraftConfig(
            aircraftId: "wt9-dynamic",
            defaultLanguage: "en",
            availableLanguages: ["en", "fr"],
            resourceNames: [
                "en": "wt9-dynamic-bundled",
                "fr": "wt9-dynamic-bundled-fr"
            ]
        )
    ]

    /// Check if an aircraft ID is bundled
    static func isBundled(aircraftId: String) -> Bool {
        bundledAircraftIds.contains(aircraftId)
    }

    /// Get available languages for a bundled aircraft
    static func availableLanguages(for aircraftId: String) -> [String] {
        bundledAircraftConfigs[aircraftId]?.availableLanguages ?? []
    }

    /// Check if a specific language is bundled for an aircraft
    static func isLanguageBundled(aircraftId: String, language: String) -> Bool {
        bundledAircraftConfigs[aircraftId]?.availableLanguages.contains(language) ?? false
    }

    // MARK: - Loading Bundled Checklists

    /// Load a bundled checklist from the app bundle
    /// - Parameters:
    ///   - aircraftId: The aircraft identifier (e.g., "wt9-dynamic")
    ///   - language: The language code (e.g., "en", "fr"). If nil or not available, uses default language.
    /// - Returns: The checklist if found and valid, nil otherwise
    static func loadBundledChecklist(for aircraftId: String, language: String? = nil) -> RemoteAircraftChecklist? {
        guard let config = bundledAircraftConfigs[aircraftId] else {
            print("[BundledChecklistService] No bundled config for aircraft: \(aircraftId)")
            return nil
        }

        // Determine which language to use
        let effectiveLanguage: String
        if let lang = language, config.availableLanguages.contains(lang) {
            effectiveLanguage = lang
        } else {
            effectiveLanguage = config.defaultLanguage
        }

        // Get resource name for the language
        guard let resourceName = config.resourceNames[effectiveLanguage] else {
            print("[BundledChecklistService] No resource name for language \(effectiveLanguage) on aircraft: \(aircraftId)")
            return nil
        }

        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json") else {
            print("[BundledChecklistService] Bundled resource not found: \(resourceName).json")
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let checklist = try decoder.decode(RemoteAircraftChecklist.self, from: data)
            print("[BundledChecklistService] Loaded bundled checklist: \(aircraftId) (\(effectiveLanguage)) v\(checklist.version)")
            return checklist
        } catch {
            print("[BundledChecklistService] Failed to decode bundled checklist: \(error)")
            return nil
        }
    }

    // MARK: - Version Comparison

    /// Compare two version strings to determine which is newer
    /// Returns true if version1 is newer than version2
    static func isNewer(_ version1: String, than version2: String) -> Bool {
        // Split versions by common separators
        let v1Parts = version1.components(separatedBy: CharacterSet(charactersIn: ".e-"))
        let v2Parts = version2.components(separatedBy: CharacterSet(charactersIn: ".e-"))

        // Compare numeric parts first, then alphanumeric
        for i in 0..<max(v1Parts.count, v2Parts.count) {
            let part1 = i < v1Parts.count ? v1Parts[i] : "0"
            let part2 = i < v2Parts.count ? v2Parts[i] : "0"

            // Try numeric comparison first
            if let num1 = Int(part1), let num2 = Int(part2) {
                if num1 != num2 {
                    return num1 > num2
                }
            } else {
                // Fall back to string comparison
                let comparison = part1.compare(part2)
                if comparison != .orderedSame {
                    return comparison == .orderedDescending
                }
            }
        }

        return false // Versions are equal
    }
}
