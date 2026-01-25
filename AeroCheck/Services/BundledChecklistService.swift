import Foundation

/// Service for loading and managing bundled aircraft checklists.
/// Bundled checklists are included with the app and serve as fallback when offline
/// or when the API returns an older version.
enum BundledChecklistService {

    // MARK: - Bundled Aircraft IDs

    /// Aircraft IDs that are bundled with the app
    static let bundledAircraftIds: Set<String> = ["wt9-dynamic"]

    /// Check if an aircraft ID is bundled
    static func isBundled(aircraftId: String) -> Bool {
        bundledAircraftIds.contains(aircraftId)
    }

    // MARK: - Loading Bundled Checklists

    /// Load a bundled checklist from the app bundle
    /// - Parameter aircraftId: The aircraft identifier (e.g., "wt9-dynamic")
    /// - Returns: The checklist if found and valid, nil otherwise
    static func loadBundledChecklist(for aircraftId: String) -> RemoteAircraftChecklist? {
        // Map aircraft ID to bundled resource name
        guard let resourceName = bundledResourceName(for: aircraftId) else {
            print("[BundledChecklistService] No bundled resource for aircraft: \(aircraftId)")
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
            print("[BundledChecklistService] Loaded bundled checklist: \(aircraftId) v\(checklist.version)")
            return checklist
        } catch {
            print("[BundledChecklistService] Failed to decode bundled checklist: \(error)")
            return nil
        }
    }

    /// Get the bundled resource name for an aircraft ID
    private static func bundledResourceName(for aircraftId: String) -> String? {
        switch aircraftId {
        case "wt9-dynamic":
            return "wt9-dynamic-bundled"
        default:
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

    /// Get the version of a bundled checklist
    static func bundledVersion(for aircraftId: String) -> String? {
        loadBundledChecklist(for: aircraftId)?.version
    }
}
