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

    // MARK: - Initialization

    init(apiBaseURL: String = "https://api.aerocheck.app") {
        self.apiBaseURL = apiBaseURL

        // Start listening for transactions
        updateListenerTask = listenForTransactions()

        // Load products and check current status
        Task {
            await loadProducts()
            await updateSubscriptionStatus()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Public Methods

    /// Loads available subscription products from App Store
    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let storeProducts = try await Product.products(for: productIdentifiers)

            // Sort by price (monthly first, yearly second)
            products = storeProducts.sorted { $0.price < $1.price }
        } catch {
            errorMessage = "Failed to load products: \(error.localizedDescription)"
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
                // Verify the transaction
                let transaction = try checkVerified(verification)

                // Verify with our server - pass the VerificationResult
                await verifyWithServer(verificationResult: verification)

                // Finish the transaction
                await transaction.finish()

                // Update status
                await updateSubscriptionStatus()

            case .userCancelled:
                // User cancelled, no error needed
                break

            case .pending:
                // Transaction is pending (e.g., Ask to Buy)
                errorMessage = "Purchase is pending approval"

            @unknown default:
                errorMessage = "Unknown purchase result"
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
            throw error
        }
    }

    /// Restores previous purchases
    func restorePurchases() async {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            // Sync with App Store
            try await AppStore.sync()

            // Update subscription status
            await updateSubscriptionStatus()

        } catch {
            errorMessage = "Failed to restore purchases: \(error.localizedDescription)"
            print("Failed to restore purchases: \(error)")
        }
    }

    /// Updates the subscription status by checking current entitlements
    func updateSubscriptionStatus() async {
        // Check debug flag first
        if debugForceNotSubscribed {
            subscriptionStatus = .notSubscribed
            print("[SubscriptionManager] Debug mode: Forcing not subscribed state")
            return
        }

        // Check for active subscription
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                if productIdentifiers.contains(transaction.productID) {
                    // Found an active subscription
                    if let expirationDate = transaction.expirationDate {
                        if expirationDate > Date() {
                            subscriptionStatus = .subscribed(
                                expiresAt: expirationDate,
                                productID: transaction.productID
                            )

                            // Verify with server in background - pass the VerificationResult
                            Task {
                                await verifyWithServer(verificationResult: result)
                            }

                            return
                        }
                    }
                }
            }
        }

        // No active subscription found
        subscriptionStatus = .notSubscribed
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

    /// Gets the user ID for API authentication
    func getUserID() async -> String? {
        if let cached = cachedUserID {
            return cached
        }

        // Try to get user ID from a recent transaction
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                cachedUserID = String(transaction.originalID)
                return cachedUserID
            }
        }

        // Fall back to device identifier
        if let deviceID = UIDevice.current.identifierForVendor?.uuidString {
            cachedUserID = deviceID
            return deviceID
        }

        return nil
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

    /// Listens for transaction updates
    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(result)

                    // Handle the transaction - pass the VerificationResult, not just the Transaction
                    await self.verifyWithServer(verificationResult: result)
                    await transaction.finish()

                    // Update status on main actor
                    await MainActor.run {
                        _ = Task {
                            await self.updateSubscriptionStatus()
                        }
                    }
                } catch {
                    print("Transaction verification failed: \(error)")
                }
            }
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

        debugLogger.log("User ID: \(userID)", level: .info)

        // Get the JWS representation from the VerificationResult
        // This is the signed JWT string that the server can verify
        let jwsToken = verificationResult.jwsRepresentation
        debugLogger.log("JWS token extracted (length: \(jwsToken.count) chars)", level: .success)

        // Send to server
        let url = URL(string: "\(apiBaseURL)/api/v1/subscription/verify")!
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

            // Parse response (for debugging)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                debugLogger.log("Verification successful: \(json)", level: .success)
            }

        } catch {
            debugLogger.log("Network error: \(error.localizedDescription)", level: .error)
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
