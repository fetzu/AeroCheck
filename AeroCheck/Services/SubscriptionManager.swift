import Foundation
import StoreKit

/// Debug logger for subscription operations
@MainActor
class SubscriptionDebugLogger: ObservableObject {
    @Published var logs: [DebugLogEntry] = []
    private let maxLogs = 100

    func log(_ message: String, level: LogLevel = .info) {
        let entry = DebugLogEntry(message: message, level: level, timestamp: Date())
        logs.insert(entry, at: 0)

        // Keep only the most recent logs
        if logs.count > maxLogs {
            logs = Array(logs.prefix(maxLogs))
        }

        // Also print to console
        print("[SubscriptionManager] \(message)")
    }

    func clear() {
        logs.removeAll()
    }
}

struct DebugLogEntry: Identifiable {
    let id = UUID()
    let message: String
    let level: LogLevel
    let timestamp: Date
}

enum LogLevel {
    case info
    case warning
    case error
    case success

    var emoji: String {
        switch self {
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        case .success: return "✅"
        }
    }
}

/// Manages subscription purchases and status using StoreKit 2
/// Integrates with the AeroCheck API for receipt verification
@MainActor
class SubscriptionManager: ObservableObject {

    // MARK: - Published Properties

    /// Current subscription status
    @Published var subscriptionStatus: SubscriptionStatus = .unknown

    /// Available subscription products
    @Published var products: [Product] = []

    /// Whether a purchase is in progress
    @Published var isPurchasing = false

    /// Error message to display
    @Published var errorMessage: String?

    /// Whether products are loading
    @Published var isLoading = false

    /// Debug logger
    let debugLogger = SubscriptionDebugLogger()

    // MARK: - Private Properties

    /// Product identifiers for subscriptions
    private let productIdentifiers: Set<String> = [
        "aerocheck.pro.monthly",
        "aerocheck.pro.yearly"
    ]

    /// API base URL
    private let apiBaseURL: String

    /// Task for listening to transaction updates
    private var updateListenerTask: Task<Void, Error>?

    /// Cached user ID from StoreKit
    private var cachedUserID: String?

    /// Debug flag to force "not subscribed" state (for testing)
    @Published var debugForceNotSubscribed: Bool = false

    /// DEV-ONLY (Marketing Mode): force a subscribed state for marketing screenshots. When set,
    /// `subscriptionStatus` reports `.subscribed` and `shouldAllowPremiumAccess()` returns true,
    /// regardless of the real StoreKit entitlement. Not persisted; resets on relaunch. Gated by the
    /// caller behind `appState.settings.marketingMode`.
    @Published var forceSubscribed: Bool = false

    /// Apply (or clear) the DEV-ONLY marketing subscription override. Setting it true flips
    /// `subscriptionStatus` to a far-future `.subscribed` so every `subscriptionStatus.isSubscribed`
    /// read site (Home, Settings, paywall) reports premium. Clearing it returns to `.unknown` so the
    /// next real periodic check re-resolves the true entitlement.
    func setMarketingForceSubscribed(_ on: Bool) {
        forceSubscribed = on
        if on {
            subscriptionStatus = .subscribed(
                expiresAt: Date().addingTimeInterval(365 * 24 * 60 * 60),
                productID: "aerocheck.pro.yearly"
            )
        } else {
            subscriptionStatus = .unknown
        }
    }

    /// Whether the subscription is in grace period (lapsed but within 48h)
    @Published var isInGracePeriod: Bool = false

    /// Date when grace period ends (nil if not in grace period)
    @Published var gracePeriodEndsAt: Date?

    // MARK: - Subscription Verification Constants

    /// How often to verify subscription status (24 hours)
    private let subscriptionVerificationInterval: TimeInterval = 24 * 60 * 60

    /// Grace period duration after subscription lapses (48 hours)
    private let gracePeriodDuration: TimeInterval = 48 * 60 * 60

    /// Maximum time a user can be offline before subscription must be re-verified (7 days)
    /// This prevents indefinite offline usage without verification
    private let maxOfflineDuration: TimeInterval = 7 * 24 * 60 * 60

    /// Key for storing last verification date
    private let lastVerificationDateKey = "subscriptionLastVerificationDate"

    /// Key for storing grace period start date
    private let gracePeriodStartKey = "subscriptionGracePeriodStart"

    // MARK: - Initialization

    /// Initialize the subscription manager
    /// - Parameters:
    ///   - apiBaseURL: The API base URL for receipt verification
    ///   - deferLoadProducts: If true, products won't be loaded automatically (call loadProducts() manually)
    init(apiBaseURL: String = "https://api.aerocheck.app", deferLoadProducts: Bool = false) {
        self.apiBaseURL = apiBaseURL

        // PR-05: honor a persisted grace window synchronously from the first frame. Otherwise
        // isInGracePeriod stays false until the async status resolution calls this later, and a
        // cold-launch premium fetch in that window would treat a grace-period user as lapsed.
        updateGracePeriodStatus()

        // Start listening for transaction updates (renewals, refunds, external purchases)
        updateListenerTask = listenForTransactions()

        // Finish any unfinished transactions from prior sessions and check status
        Task { [weak self] in
            guard let self = self else { return }
            await self.finishUnfinishedTransactions()

            if !deferLoadProducts {
                await self.loadProducts()
            }
            await self.updateSubscriptionStatus()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Public Methods

    /// Loads available subscription products from App Store
    func loadProducts() async {
        do {
            let storeProducts = try await Product.products(for: productIdentifiers)

            // Sort by price (monthly first, yearly second)
            products = storeProducts.sorted { $0.price < $1.price }
            debugLogger.log("Loaded \(storeProducts.count) products", level: .success)
        } catch {
            debugLogger.log("Failed to load products: \(error.localizedDescription)", level: .error)
            print("Failed to load products: \(error)")
        }
    }

    /// Purchases a subscription product
    func purchase(_ product: Product) async throws {
        isPurchasing = true
        errorMessage = nil

        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)

                // Verify with our server
                await verifyWithServer(verificationResult: verification)

                // Finish the transaction - critical to avoid blocking future purchases
                await transaction.finish()
                debugLogger.log("Purchase transaction finished: \(transaction.productID)", level: .success)

                // Update status immediately
                await updateSubscriptionStatus()

            case .userCancelled:
                break

            case .pending:
                errorMessage = "Purchase is pending approval"

            @unknown default:
                errorMessage = "Unknown purchase result"
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
            throw error
        }
    }

    /// Restores previous purchases by syncing with App Store and re-checking entitlements
    func restorePurchases() async {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        debugLogger.log("Starting restore purchases", level: .info)

        do {
            // AppStore.sync() forces a refresh of transaction data from the App Store
            // This may prompt the user for App Store credentials
            try await AppStore.sync()
            debugLogger.log("AppStore.sync() completed", level: .success)

            // Drop any cached identity (possibly a stale device-id fallback) so getUserID()
            // re-derives from the freshly synced entitlements before we re-check and sync
            // with the server. Without this, a restore rebinds to the wrong id. (ARCH-03)
            cachedUserID = nil

            // Finish any unfinished transactions that sync may have surfaced
            await finishUnfinishedTransactions()

            // Re-check subscription status with fresh data
            await updateSubscriptionStatus()

            // If we found a subscription, verify with server. Otherwise the restore is a definitive
            // "no entitlement" signal — reconcile downward (close grace, clear verification) instead
            // of only logging, so a lapsed subscription can't keep premium alive offline. (ARCH-11)
            if subscriptionStatus.isSubscribed {
                await syncWithServer()
                debugLogger.log("Restore successful - subscription active", level: .success)
            } else {
                confirmNoActiveSubscription()
                debugLogger.log("Restore completed - no active subscription; downgraded locally", level: .warning)
            }
        } catch {
            errorMessage = "Failed to restore purchases: \(error.localizedDescription)"
            debugLogger.log("Restore failed: \(error.localizedDescription)", level: .error)
        }
    }

    /// Updates the subscription status by checking current entitlements and subscription info
    func updateSubscriptionStatus() async {
        // Check debug flag first
        if debugForceNotSubscribed {
            subscriptionStatus = .notSubscribed
            debugLogger.log("Debug mode: Forcing not subscribed state", level: .info)
            return
        }

        // First, check Transaction.currentEntitlements for active subscriptions
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard productIdentifiers.contains(transaction.productID) else { continue }

            // Skip revoked transactions
            if transaction.revocationDate != nil { continue }

            if let expirationDate = transaction.expirationDate, expirationDate > Date() {
                subscriptionStatus = .subscribed(
                    expiresAt: expirationDate,
                    productID: transaction.productID
                )
                debugLogger.log("Active subscription found: \(transaction.productID), expires \(expirationDate)", level: .success)
                return
            }
        }

        // If no active entitlement found, check Product.SubscriptionInfo for grace period / billing retry
        // This catches cases where Transaction.currentEntitlements doesn't report the subscription
        // but Apple's subscription system still considers it in grace period
        if !products.isEmpty {
            for product in products {
                guard let subscription = product.subscription else { continue }
                if let statuses = try? await subscription.status, !statuses.isEmpty {
                    for status in statuses {
                        switch status.state {
                        case .subscribed:
                            if case .verified(let renewalInfo) = status.renewalInfo,
                               case .verified(let transaction) = status.transaction {
                                let expiresAt = transaction.expirationDate ?? Date().addingTimeInterval(30 * 24 * 60 * 60)
                                subscriptionStatus = .subscribed(
                                    expiresAt: expiresAt,
                                    productID: transaction.productID
                                )
                                debugLogger.log("Subscription active via SubscriptionInfo: \(transaction.productID)", level: .success)
                                _ = renewalInfo // Silence unused warning
                                return
                            }
                        case .inGracePeriod:
                            if case .verified(let transaction) = status.transaction {
                                let expiresAt = transaction.expirationDate ?? Date().addingTimeInterval(gracePeriodDuration)
                                subscriptionStatus = .subscribed(
                                    expiresAt: expiresAt,
                                    productID: transaction.productID
                                )
                                debugLogger.log("Subscription in Apple grace period: \(transaction.productID)", level: .warning)
                                return
                            }
                        case .inBillingRetryPeriod:
                            debugLogger.log("Subscription in billing retry period", level: .warning)
                        case .expired:
                            debugLogger.log("Subscription expired", level: .info)
                        case .revoked:
                            debugLogger.log("Subscription revoked", level: .warning)
                        default:
                            break
                        }
                    }
                }
            }
        }

        // No active subscription found
        subscriptionStatus = .notSubscribed
        debugLogger.log("No active subscription found", level: .info)
    }

    /// Resets the subscription state (for debugging/testing)
    func resetSubscriptionState() async {
        // Clear cached user ID
        cachedUserID = nil

        // Reset subscription status
        subscriptionStatus = .unknown

        // Re-check subscription status
        await updateSubscriptionStatus()

        print("[SubscriptionManager] Subscription state reset")
    }

    /// Manually syncs subscription with server
    func syncWithServer() async {
        debugLogger.log("Manually syncing subscription with server", level: .info)

        var transactionCount = 0
        var foundActiveSubscription = false

        // Get current active transaction
        for await result in Transaction.currentEntitlements {
            transactionCount += 1
            debugLogger.log("Checking transaction #\(transactionCount)", level: .info)

            if case .verified(let transaction) = result {
                debugLogger.log("Transaction verified: \(transaction.productID)", level: .info)

                if productIdentifiers.contains(transaction.productID) {
                    debugLogger.log("Transaction is for our product: \(transaction.productID)", level: .info)

                    if let expirationDate = transaction.expirationDate {
                        let isActive = expirationDate > Date()
                        debugLogger.log("Expiration: \(expirationDate), Active: \(isActive)", level: .info)

                        if isActive {
                            debugLogger.log("Found active subscription, verifying with server", level: .success)
                            foundActiveSubscription = true
                            await verifyWithServer(verificationResult: result)
                            return
                        } else {
                            debugLogger.log("Transaction expired", level: .warning)
                        }
                    } else {
                        debugLogger.log("Transaction has no expiration date", level: .warning)
                    }
                } else {
                    debugLogger.log("Transaction is not for our product (found: \(transaction.productID))", level: .warning)
                }
            } else if case .unverified(let transaction, let error) = result {
                debugLogger.log("Unverified transaction: \(transaction.productID) - Error: \(error.localizedDescription)", level: .error)
            }
        }

        if !foundActiveSubscription {
            debugLogger.log("No active subscription found to sync (checked \(transactionCount) transactions)", level: .warning)
        }
    }

    // MARK: - Subscription Verification & Grace Period

    /// Gets the last time the subscription was successfully verified
    func getLastVerificationDate() -> Date? {
        return UserDefaults.standard.object(forKey: lastVerificationDateKey) as? Date
    }

    /// Records a successful subscription verification
    func recordSuccessfulVerification() {
        UserDefaults.standard.set(Date(), forKey: lastVerificationDateKey)
        // Clear any grace period since subscription is verified
        clearGracePeriod()
        debugLogger.log("Recorded successful subscription verification", level: .success)
    }

    /// Authoritatively downgrade when a *definitive* check (e.g. a manual restore) confirms there is
    /// no active entitlement. Unlike a transient verify failure — which legitimately keeps premium
    /// alive during the offline grace window — a confirmed "no subscription" closes the grace window
    /// and clears the last-verification timestamp, so premium content is denied immediately rather
    /// than served offline on the strength of a stale prior verification. (ARCH-11)
    func confirmNoActiveSubscription() {
        subscriptionStatus = .notSubscribed
        clearGracePeriod()
        UserDefaults.standard.removeObject(forKey: lastVerificationDateKey)
        debugLogger.log("Confirmed no active subscription — closed grace period, cleared verification", level: .info)
    }

    /// Checks if subscription verification is needed (every 24 hours)
    func needsVerification() -> Bool {
        guard let lastVerification = getLastVerificationDate() else {
            return true // Never verified, needs verification
        }

        let timeSinceVerification = Date().timeIntervalSince(lastVerification)
        return timeSinceVerification >= subscriptionVerificationInterval
    }

    /// Checks if the maximum offline duration has been exceeded
    /// Returns true if subscription should be considered invalid due to being offline too long
    func hasExceededMaxOfflineDuration() -> Bool {
        guard let lastVerification = getLastVerificationDate() else {
            // Never verified - check when app was first used
            return true
        }

        let timeSinceVerification = Date().timeIntervalSince(lastVerification)
        return timeSinceVerification > maxOfflineDuration
    }

    /// Starts the grace period (called when subscription lapses or cannot be verified)
    func startGracePeriod() {
        // Only start if not already in grace period
        guard UserDefaults.standard.object(forKey: gracePeriodStartKey) == nil else {
            return
        }

        let now = Date()
        UserDefaults.standard.set(now, forKey: gracePeriodStartKey)
        isInGracePeriod = true
        gracePeriodEndsAt = now.addingTimeInterval(gracePeriodDuration)
        debugLogger.log("Grace period started, ends at \(gracePeriodEndsAt?.description ?? "unknown")", level: .warning)
    }

    /// Clears the grace period (called when subscription is verified)
    func clearGracePeriod() {
        UserDefaults.standard.removeObject(forKey: gracePeriodStartKey)
        isInGracePeriod = false
        gracePeriodEndsAt = nil
    }

    /// Checks if the grace period has expired
    func hasGracePeriodExpired() -> Bool {
        guard let gracePeriodStart = UserDefaults.standard.object(forKey: gracePeriodStartKey) as? Date else {
            return false // Not in grace period
        }

        let gracePeriodEnd = gracePeriodStart.addingTimeInterval(gracePeriodDuration)
        return Date() > gracePeriodEnd
    }

    /// Updates the grace period status from stored values
    func updateGracePeriodStatus() {
        if let gracePeriodStart = UserDefaults.standard.object(forKey: gracePeriodStartKey) as? Date {
            let gracePeriodEnd = gracePeriodStart.addingTimeInterval(gracePeriodDuration)
            if Date() > gracePeriodEnd {
                // Grace period expired
                isInGracePeriod = false
                gracePeriodEndsAt = nil
            } else {
                // Still in grace period
                isInGracePeriod = true
                gracePeriodEndsAt = gracePeriodEnd
            }
        } else {
            isInGracePeriod = false
            gracePeriodEndsAt = nil
        }
    }

    /// Performs a periodic subscription check (call this from app lifecycle)
    /// Returns true if subscription is valid (active or in grace period)
    func performPeriodicCheck() async -> Bool {
        debugLogger.log("Performing periodic subscription check", level: .info)

        // Update grace period status from stored values
        updateGracePeriodStatus()

        // Check if verification is needed
        if needsVerification() {
            debugLogger.log("Subscription verification needed (24h elapsed)", level: .info)

            // Try to verify with StoreKit
            await updateSubscriptionStatus()

            if subscriptionStatus.isSubscribed {
                // Subscription is active - verify with server
                await syncWithServer()
                recordSuccessfulVerification()
                return true
            } else {
                // Subscription not active
                if !isInGracePeriod && !hasGracePeriodExpired() {
                    // Start grace period
                    startGracePeriod()
                    debugLogger.log("Subscription lapsed, starting 48h grace period", level: .warning)
                    return true // Still valid during grace period
                } else if isInGracePeriod && !hasGracePeriodExpired() {
                    debugLogger.log("In grace period, subscription access continues", level: .warning)
                    return true
                } else {
                    // Grace period expired
                    debugLogger.log("Grace period expired, subscription invalid", level: .error)
                    return false
                }
            }
        } else {
            // No verification needed yet
            if subscriptionStatus.isSubscribed {
                return true
            } else if isInGracePeriod && !hasGracePeriodExpired() {
                return true
            } else {
                return false
            }
        }
    }

    /// Checks if premium content should be accessible
    /// Takes into account subscription status, grace period, and offline duration
    func shouldAllowPremiumAccess() -> Bool {
        // DEV-ONLY marketing override wins over everything else.
        if forceSubscribed {
            return true
        }
        // Debug mode check
        if debugForceNotSubscribed {
            return false
        }

        // Active subscription
        if subscriptionStatus.isSubscribed {
            // Check if offline too long (prevents indefinite offline usage)
            if hasExceededMaxOfflineDuration() {
                debugLogger.log("Offline duration exceeded, premium access denied until online", level: .warning)
                return false
            }
            return true
        }

        // In grace period
        if isInGracePeriod && !hasGracePeriodExpired() {
            return true
        }

        return false
    }

    /// True ONLY when premium access is definitively denied — used for the cache-DESTROYING decision
    /// in `AircraftDataService.fetchChecklist`, which must never run on a transient state. Differs
    /// from `shouldAllowPremiumAccess()` in two safety-critical ways (PR-05):
    ///  • `.unknown` (StoreKit/server status still resolving at cold launch) → NOT denied (keep cache).
    ///  • StoreKit reports an active entitlement but the last *server* verification is stale
    ///    (offline too long) → NOT denied (keep cache); the local entitlement is authoritative.
    /// So the only way to reach `true` is a resolved, not-subscribed status with no valid grace window.
    func isPremiumAccessDefinitivelyDenied() -> Bool {
        if forceSubscribed { return false } // DEV-ONLY marketing override
        if debugForceNotSubscribed { return true }
        if subscriptionStatus == .unknown { return false }
        if subscriptionStatus.isSubscribed { return false }
        if isInGracePeriod && !hasGracePeriodExpired() { return false }
        return true
    }

    /// Redacts an identifier for logging — keeps only a short suffix so support can correlate
    /// without the full id (a server auth principal) ever landing in the debug log. (SEC-19)
    static func redactedIdentifier(_ id: String) -> String {
        id.count <= 4 ? "****" : "****\(id.suffix(4))"
    }

    /// Gets the user ID for API authentication
    func getUserID() async -> String? {
        if let cached = cachedUserID {
            return cached
        }

        // Derive the durable identity from the StoreKit transaction (originalID is stable
        // per Apple ID for the subscription). This is what the server binds to. (ARCH-03)
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                cachedUserID = String(transaction.originalID)
                return cachedUserID
            }
        }

        // Last-resort, non-durable fallback. Deliberately NOT cached, so that once a real
        // transaction is available (e.g. after a restore or first launch with entitlements)
        // getUserID() re-derives the durable id instead of pinning to this device id. (ARCH-03)
        return UIDevice.current.identifierForVendor?.uuidString
    }

    /// Gets all transactions for debugging
    func getAllTransactions() async -> [TransactionDebugInfo] {
        var transactions: [TransactionDebugInfo] = []

        // Get all current entitlements
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                transactions.append(TransactionDebugInfo(
                    id: String(transaction.id),
                    originalID: String(transaction.originalID),
                    productID: transaction.productID,
                    purchaseDate: transaction.purchaseDate,
                    expirationDate: transaction.expirationDate,
                    isUpgraded: transaction.isUpgraded,
                    revocationDate: transaction.revocationDate,
                    revocationReason: transaction.revocationReason,
                    ownershipType: transaction.ownershipType,
                    environmentRaw: String(describing: transaction.environment),
                    isVerified: true
                ))
            case .unverified(let transaction, let error):
                transactions.append(TransactionDebugInfo(
                    id: String(transaction.id),
                    originalID: String(transaction.originalID),
                    productID: transaction.productID,
                    purchaseDate: transaction.purchaseDate,
                    expirationDate: transaction.expirationDate,
                    isUpgraded: transaction.isUpgraded,
                    revocationDate: transaction.revocationDate,
                    revocationReason: transaction.revocationReason,
                    ownershipType: transaction.ownershipType,
                    environmentRaw: String(describing: transaction.environment),
                    isVerified: false,
                    verificationError: error.localizedDescription
                ))
            }
        }

        return transactions
    }

    // MARK: - Private Methods

    /// Listens for transaction updates (renewals, refunds, external purchases)
    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self = self else { return }
                do {
                    let transaction = try self.checkVerified(result)
                    await self.debugLogger.log("Transaction update received: \(transaction.productID)", level: .info)

                    // Verify with server and finish the transaction
                    await self.verifyWithServer(verificationResult: result)
                    await transaction.finish()

                    // Update subscription status
                    await self.updateSubscriptionStatus()
                } catch {
                    // Even unverified transactions should be finished to avoid blocking
                    if case .unverified(let transaction, _) = result {
                        await transaction.finish()
                    }
                    await self.debugLogger.log("Transaction update failed: \(error.localizedDescription)", level: .error)
                }
            }
        }
    }

    /// Finishes any unfinished transactions from prior sessions
    /// Apple recommends doing this at launch to prevent stuck purchases
    private func finishUnfinishedTransactions() async {
        var count = 0
        for await result in Transaction.unfinished {
            count += 1
            switch result {
            case .verified(let transaction):
                // Verify with server before finishing
                await verifyWithServer(verificationResult: result)
                await transaction.finish()
                debugLogger.log("Finished unfinished transaction: \(transaction.productID)", level: .success)
            case .unverified(let transaction, let error):
                // Finish even unverified transactions to unblock the queue
                await transaction.finish()
                debugLogger.log("Finished unverified transaction: \(transaction.productID) (\(error.localizedDescription))", level: .warning)
            }
        }
        if count > 0 {
            debugLogger.log("Cleared \(count) unfinished transaction(s)", level: .info)
        }
    }

    /// Verifies a transaction result
    nonisolated private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw SubscriptionError.verificationFailed
        case .verified(let item):
            return item
        }
    }

    /// Verifies a transaction with the AeroCheck API server using StoreKit 2 JWS token
    private func verifyWithServer(verificationResult: VerificationResult<Transaction>) async {
        // Extract the transaction for logging
        let transaction: Transaction
        switch verificationResult {
        case .verified(let t):
            transaction = t
        case .unverified(let t, _):
            transaction = t
        }

        debugLogger.log("Starting server verification for: \(transaction.productID)", level: .info)

        guard let userID = await getUserID() else {
            debugLogger.log("No user ID available for server verification", level: .error)
            return
        }

        // Redact the identity in logs — only a short suffix, never the full id. (SEC-19)
        debugLogger.log("User ID: \(Self.redactedIdentifier(userID))", level: .info)

        // Get the JWS representation from the VerificationResult
        // This is the signed JWT string that the server can verify
        let jwsToken = verificationResult.jwsRepresentation
        debugLogger.log("JWS token extracted (length: \(jwsToken.count) chars)", level: .success)

        // Send to server (fail safe instead of force-unwrapping — PERF-14)
        guard let url = URL(string: "\(apiBaseURL)/api/v3/subscription/verify") else {
            debugLogger.log("Invalid verify URL", level: .error)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Convert environment to a simple string (avoiding complex enum serialization)
        let environmentString = "\(transaction.environment)"

        debugLogger.log("Environment: \(environmentString)", level: .info)

        struct VerifyRequest: Codable {
            let jwsToken: String
            let userId: String
            let environment: String
        }

        let requestBody = VerifyRequest(
            jwsToken: jwsToken,
            userId: userID,
            environment: environmentString
        )

        do {
            let jsonData = try JSONEncoder().encode(requestBody)
            request.httpBody = jsonData
            request.timeoutInterval = 15 // Set timeout for poor network conditions

            debugLogger.log("Sending JWS verification request to server", level: .info)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                debugLogger.log("Invalid response type", level: .error)
                return
            }

            debugLogger.log("Server response: HTTP \(httpResponse.statusCode)", level: httpResponse.statusCode == 200 ? .success : .error)

            guard httpResponse.statusCode == 200 else {
                if let responseString = String(data: data, encoding: .utf8) {
                    debugLogger.log("Error response: \(responseString)", level: .error)
                }
                return
            }

            // A 200 means the request was processed — NOT that the user is entitled. Only an
            // "active" status (with a future expiry, if provided) counts as a successful
            // verification; a 200 carrying status none/expired/cancelled must NOT reset the
            // grace/offline timers. (SEC-10)
            struct VerifyResponse: Decodable {
                struct Payload: Decodable {
                    let status: String?
                    let expiresAt: String?
                    let sku: String?
                }
                let success: Bool?
                let data: Payload?
            }
            let decoded = try? JSONDecoder().decode(VerifyResponse.self, from: data)
            let status = decoded?.data?.status ?? "unknown"
            let expiresAtOK: Bool = {
                guard let iso = decoded?.data?.expiresAt else { return true } // none provided
                let withFractional = ISO8601DateFormatter()
                withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = withFractional.date(from: iso) { return d > Date() }
                if let d = ISO8601DateFormatter().date(from: iso) { return d > Date() }
                return true // unparseable expiry → don't reject on expiry alone
            }()

            if decoded?.success == true && status == "active" && expiresAtOK {
                recordSuccessfulVerification()
                debugLogger.log("Server verification: active", level: .success)
            } else {
                debugLogger.log("Server verification did not confirm entitlement (status=\(status)); not recording success", level: .warning)
            }

        } catch {
            debugLogger.log("Network error during server verification: \(error.localizedDescription)", level: .error)
        }
    }
}

// MARK: - Subscription Status

enum SubscriptionStatus: Equatable {
    case unknown
    case notSubscribed
    case subscribed(expiresAt: Date, productID: String)

    var isSubscribed: Bool {
        if case .subscribed = self {
            return true
        }
        return false
    }

    var displayText: String {
        switch self {
        case .unknown:
            return "Checking subscription..."
        case .notSubscribed:
            return "Not subscribed"
        case .subscribed(let expiresAt, _):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return "Subscribed until \(formatter.string(from: expiresAt))"
        }
    }

    var productID: String? {
        if case .subscribed(_, let productID) = self {
            return productID
        }
        return nil
    }
}

// MARK: - Subscription Error

enum SubscriptionError: LocalizedError {
    case verificationFailed
    case purchaseFailed(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .verificationFailed:
            return "Transaction verification failed"
        case .purchaseFailed(let message):
            return "Purchase failed: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Transaction Debug Info

struct TransactionDebugInfo: Identifiable {
    let id: String
    let originalID: String
    let productID: String
    let purchaseDate: Date
    let expirationDate: Date?
    let isUpgraded: Bool
    let revocationDate: Date?
    let revocationReason: Transaction.RevocationReason?
    let ownershipType: Transaction.OwnershipType
    let environmentRaw: String
    let isVerified: Bool
    var verificationError: String?

    var isActive: Bool {
        guard let expirationDate = expirationDate else { return false }
        return expirationDate > Date()
    }

    var statusText: String {
        if !isVerified {
            return "⚠️ UNVERIFIED"
        }
        if revocationDate != nil {
            return "🚫 REVOKED"
        }
        if isUpgraded {
            return "⬆️ UPGRADED"
        }
        if isActive {
            return "✅ ACTIVE"
        }
        return "⏱️ EXPIRED"
    }

    var environmentText: String {
        return environmentRaw
    }
}

// MARK: - Product Extensions

extension Product {
    /// Formatted subscription period (e.g., "per month", "per year")
    var subscriptionPeriodText: String {
        guard let subscription = self.subscription else {
            return ""
        }

        let unit = subscription.subscriptionPeriod.unit
        let value = subscription.subscriptionPeriod.value

        switch unit {
        case .day:
            return value == 1 ? "per day" : "every \(value) days"
        case .week:
            return value == 1 ? "per week" : "every \(value) weeks"
        case .month:
            return value == 1 ? "per month" : "every \(value) months"
        case .year:
            return value == 1 ? "per year" : "every \(value) years"
        @unknown default:
            return ""
        }
    }

    /// Whether this is the yearly subscription (for showing discount)
    var isYearly: Bool {
        return id == "aerocheck.pro.yearly"
    }
}
