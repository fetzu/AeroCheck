//
//  KeychainStore.swift
//  AeroCheck
//
//  Minimal Keychain wrapper for the one genuine secret this app holds: the server-minted
//  API session token. (SEC-C3)
//

import Foundation
import Security

/// Small, dependency-free Keychain accessor for short string secrets.
///
/// Until the session token existed the app stored no long-lived secret at all — the API credential
/// was the Apple `originalTransactionId`, re-derived from StoreKit on every launch. That value was
/// not a secret in the first place, which was the finding: it is user-visible, unrotatable, and
/// possession of it was never proven, so sharing the string handed over the whole premium
/// catalogue. The replacement genuinely is a secret, so it belongs here rather than in
/// `UserDefaults` (readable from a backup, and shared with the widget through the App Group).
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` matches how the app actually works: the token
/// is used by background refreshes while the device is locked (so `WhenUnlocked` would break them),
/// and `ThisDeviceOnly` keeps it out of encrypted backups and off other devices — a restored backup
/// re-verifies with StoreKit and mints a fresh token, which is cheap and strictly safer.
enum KeychainStore {

    /// Keys used by the app. Namespaced by bundle id at the account level.
    enum Key: String {
        /// Opaque session token minted by `POST /subscription/verify`.
        case apiSessionToken = "api.session.token"
    }

    private static let service = "app.aerocheck.credentials"

    /// Stores (or replaces) a secret. Returns false if the Keychain refused the write.
    @discardableResult
    static func set(_ value: String, for key: Key) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete-then-add rather than SecItemUpdate: it is one round trip fewer to reason about,
        // and it guarantees the accessibility attribute is re-applied rather than inherited from
        // whatever a previous build wrote.
        remove(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Reads a secret, or nil when absent (or unreadable, e.g. before first unlock).
    static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    /// Removes a secret. Succeeds silently when nothing is stored.
    static func remove(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
