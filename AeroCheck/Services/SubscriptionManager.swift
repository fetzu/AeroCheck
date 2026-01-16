import Foundation
import StoreKit

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

                // Verify with our server
                await verifyWithServer(transaction: transaction)

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

                            // Verify with server in background
                            Task {
                                await verifyWithServer(transaction: transaction)
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
        print("[SubscriptionManager] Manually syncing subscription with server")

        // Get current active transaction
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                if productIdentifiers.contains(transaction.productID) {
                    if let expirationDate = transaction.expirationDate, expirationDate > Date() {
                        print("[SubscriptionManager] Found active subscription, verifying with server")
                        await verifyWithServer(transaction: transaction)
                        return
                    }
                }
            }
        }

        print("[SubscriptionManager] No active subscription found to sync")
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
        if let deviceID = await UIDevice.current.identifierForVendor?.uuidString {
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

                    // Handle the transaction
                    await self.verifyWithServer(transaction: transaction)
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

    /// Verifies a transaction with the AeroCheck API server
    private func verifyWithServer(transaction: Transaction) async {
        print("[SubscriptionManager] Starting server verification for transaction: \(transaction.productID)")

        guard let userID = await getUserID() else {
            print("[SubscriptionManager] ❌ No user ID available for server verification")
            return
        }

        print("[SubscriptionManager] User ID: \(userID)")

        // Get the app receipt
        guard let receiptURL = Bundle.main.appStoreReceiptURL else {
            print("[SubscriptionManager] ❌ No receipt URL found")
            print("[SubscriptionManager] This usually means you're testing with StoreKit Configuration file")
            print("[SubscriptionManager] Real App Store receipts are only available on physical devices with real/sandbox subscriptions")
            return
        }

        print("[SubscriptionManager] Receipt URL: \(receiptURL.path)")

        guard let receiptData = try? Data(contentsOf: receiptURL) else {
            print("[SubscriptionManager] ❌ Could not read receipt data from \(receiptURL.path)")
            return
        }

        print("[SubscriptionManager] Receipt size: \(receiptData.count) bytes")

        let receiptString = receiptData.base64EncodedString()

        // Send to server
        let url = URL(string: "\(apiBaseURL)/api/v1/subscription/verify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "receiptData": receiptString,
            "userId": userID
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            print("[SubscriptionManager] Sending verification request to \(url.absoluteString)")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[SubscriptionManager] ❌ Invalid response type")
                return
            }

            print("[SubscriptionManager] Server response status: \(httpResponse.statusCode)")

            guard httpResponse.statusCode == 200 else {
                print("[SubscriptionManager] ❌ Server verification failed with status: \(httpResponse.statusCode)")
                if let responseString = String(data: data, encoding: .utf8) {
                    print("[SubscriptionManager] Response body: \(responseString)")
                }
                return
            }

            // Parse response (for debugging)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("[SubscriptionManager] ✅ Server verification successful: \(json)")
            }

        } catch {
            print("[SubscriptionManager] ❌ Server verification error: \(error)")
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
