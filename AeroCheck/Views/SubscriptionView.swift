import SwiftUI
import StoreKit

/// The AéroCheck Pro paywall. Shows a contextual header (naming the aircraft the pilot tried to unlock,
/// when provided), the available plans (yearly with its free trial, monthly, and the one-time lifetime),
/// the benefits, and restore/legal links.
struct SubscriptionView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) var dismiss

    /// When the paywall is opened from a specific locked aircraft (e.g. trying to start a flight on it),
    /// its name personalises the header. Nil → the generic header.
    var contextAircraftName: String? = nil

    /// `true` (default) when shown as a sheet (flight-start, onboarding) — wraps itself in a
    /// NavigationStack with a Done button. `false` when pushed into an existing stack (the iPad
    /// settings detail column / iPhone settings push) — renders bare so the parent supplies the
    /// navigation bar + back button and it fills the detail column instead of a popup.
    var presentedAsSheet: Bool = true

    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isLoadingProducts = false
    /// Free-trial length (days) of the yearly plan, set only when this account is actually eligible.
    @State private var yearlyTrialDays: Int? = nil

    private let yearlyID = "aerocheck.pro.yearly"

    var body: some View {
        Group {
            if presentedAsSheet {
                NavigationStack {
                    scrollContent
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L10n.Button.done) { dismiss() }
                                    .foregroundColor(Color.aviationGold)
                            }
                        }
                }
            } else {
                // Pushed into the settings stack — the parent provides the bar + back button, so it
                // fills the iPad detail column rather than presenting as a sheet.
                scrollContent
            }
        }
        .onAppear {
            Task {
                if subscriptionManager.products.isEmpty {
                    isLoadingProducts = true
                    await subscriptionManager.loadProducts()
                    isLoadingProducts = false
                }
                await subscriptionManager.updateSubscriptionStatus()
                await refreshTrialEligibility()
            }
        }
        .onChange(of: subscriptionManager.products) { _, _ in
            Task { await refreshTrialEligibility() }
        }
        .alert(L10n.Subscription.error, isPresented: $showingError) {
            Button(L10n.Subscription.ok, role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .onChange(of: subscriptionManager.errorMessage) { _, newValue in
            if let error = newValue {
                errorMessage = error
                showingError = true
            }
        }
    }

    /// The paywall body, shared by the sheet and pushed presentations.
    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 22) {
                headerSection

                if !subscriptionManager.subscriptionStatus.isSubscribed, let days = yearlyTrialDays {
                    trialBanner(days: days)
                }

                // Lifetime owners can't buy anything more; everyone else sees the purchasable plans —
                // active subscribers see only the one-time lifetime upgrade (they can't re-subscribe but
                // can convert to lifetime). (v4.1.1 device-test fix) [[next-pr-followups]]
                if !subscriptionManager.subscriptionStatus.isLifetime {
                    productsSection
                }

                benefitsSection
                statusSection
                restoreSection
                termsSection
            }
            .padding()
        }
        .background(Color.cockpitBackground)
        .navigationTitle(L10n.Settings.aeroCheckPro)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Resolve whether THIS account is eligible for the yearly free trial (Apple only grants it once),
    /// so we don't promise a trial a returning subscriber won't actually get.
    private func refreshTrialEligibility() async {
        guard let yearly = subscriptionManager.products.first(where: { $0.id == yearlyID }),
              let days = yearly.freeTrialDays,
              let sub = yearly.subscription else {
            yearlyTrialDays = nil
            return
        }
        let eligible = await sub.isEligibleForIntroOffer
        yearlyTrialDays = eligible ? days : nil
    }

    /// Products in paywall order: yearly (recommended) first, then monthly, then the one-time lifetime.
    private var orderedProducts: [Product] {
        let rank: [String: Int] = [yearlyID: 0, "aerocheck.pro.monthly": 1, "aerocheck.pro.lifetime": 2]
        return subscriptionManager.products.sorted { (rank[$0.id] ?? 99) < (rank[$1.id] ?? 99) }
    }

    /// Products the user can still purchase from this paywall: a lifetime owner can buy nothing more; an
    /// active subscriber sees only the one-time lifetime upgrade; everyone else sees all plans. (v4.1.1)
    private var purchasableProducts: [Product] {
        if subscriptionManager.subscriptionStatus.isLifetime { return [] }
        if subscriptionManager.subscriptionStatus.isSubscribed {
            return orderedProducts.filter { $0.isLifetime }
        }
        return orderedProducts
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 14) {
            Image(systemName: "airplane")
                .scaledFont(size: 30, relativeTo: .largeTitle)
                .foregroundColor(Color.aviationGold)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.aviationGold.opacity(0.16)))
                .accessibilityHidden(true)

            Text(headerTitle)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(Color.primaryText)
                .multilineTextAlignment(.center)

            Text(L10n.Subscription.accessDescription)
                .font(.subheadline)
                .foregroundColor(Color.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical)
    }

    private var headerTitle: String {
        if let name = contextAircraftName, !name.isEmpty {
            return L10n.Subscription.unlockAircraft(name)
        }
        return L10n.Subscription.unlockPremiumAircraft
    }

    // MARK: - Free-trial banner

    private func trialBanner(days: Int) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "gift.fill")
                .scaledFont(size: 18, relativeTo: .title3)
                .foregroundColor(Color.aviationGreen)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Subscription.freeTrialDays(days))
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(Color.aviationGreen)
                Text(L10n.Subscription.freeTrialNoteDays(days))
                    .font(.caption)
                    .foregroundColor(Color.secondaryText)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.aviationGreen.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.aviationGreen.opacity(0.35), lineWidth: 1))
        )
    }

    // MARK: - Products

    private var productsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Hide the "Choose a plan" header for subscribers, who only see the single lifetime-upgrade card.
            if !subscriptionManager.subscriptionStatus.isSubscribed {
                Text(L10n.Subscription.choosePlan)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(Color.secondaryText)
            }

            if subscriptionManager.products.isEmpty {
                if isLoadingProducts {
                    ProgressView().frame(maxWidth: .infinity).padding()
                } else {
                    Text(L10n.Subscription.unableToLoad)
                        .font(.subheadline)
                        .foregroundColor(Color.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding()
                    Button(L10n.Subscription.retry) {
                        isLoadingProducts = true
                        Task {
                            await subscriptionManager.loadProducts()
                            isLoadingProducts = false
                            await refreshTrialEligibility()
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                ForEach(purchasableProducts) { product in
                    ProductCard(
                        product: product,
                        trialDays: product.id == yearlyID ? yearlyTrialDays : nil
                    )
                }
            }
        }
    }

    // MARK: - Benefits

    private var benefitsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            benefitRow(icon: "airplane", tint: .aviationGold, text: L10n.Subscription.benefitAllChecklists, isLast: false)
            benefitRow(icon: "arrow.triangle.2.circlepath", tint: .altimeterBlue, text: L10n.Subscription.benefitAutoUpdates, isLast: false)
            benefitRow(icon: "icloud.and.arrow.down", tint: .aviationGreen, text: L10n.Subscription.benefitOfflineAccess, isLast: false)
            benefitRow(icon: "heart.fill", tint: .orange, text: L10n.Subscription.benefitSupportDev, isLast: true)
        }
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.subtleOverlay(0.06), lineWidth: 1))
        )
    }

    private func benefitRow(icon: String, tint: Color, text: String, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .scaledFont(size: 16, relativeTo: .body)
                    .foregroundColor(tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tint.opacity(0.16)))
                    .accessibilityHidden(true)
                Text(text)
                    .font(.subheadline)
                    .foregroundColor(Color.primaryText)
                Spacer()
            }
            .padding(.vertical, 9)
            if !isLast {
                Rectangle().fill(Color.subtleOverlay(0.06)).frame(height: 1).padding(.leading, 41)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Subscription.currentStatus)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(Color.secondaryText)

            HStack {
                Image(systemName: subscriptionManager.subscriptionStatus.isSubscribed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(subscriptionManager.subscriptionStatus.isSubscribed ? Color.aviationGreen : Color.secondaryText)
                Text(subscriptionManager.subscriptionStatus.displayText)
                    .font(.subheadline)
                    .foregroundColor(Color.primaryText)
                Spacer()
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
        }
    }

    // MARK: - Restore & terms

    private var restoreSection: some View {
        VStack(spacing: 8) {
            Button {
                Task { await subscriptionManager.restorePurchases() }
            } label: {
                if subscriptionManager.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().tint(Color.aviationBlue)
                        Text(L10n.Subscription.restorePurchases)
                            .font(.subheadline)
                            .foregroundColor(Color.aviationBlue.opacity(0.5))
                    }
                } else {
                    Text(L10n.Subscription.restorePurchases)
                        .font(.subheadline)
                        .foregroundColor(Color.altimeterBlue)
                }
            }
            .disabled(subscriptionManager.isLoading || subscriptionManager.isPurchasing)
        }
        .padding(.top)
    }

    private var termsSection: some View {
        VStack(spacing: 8) {
            Text(L10n.Subscription.termsDescription)
                .font(.caption2)
                .foregroundColor(Color.dimText)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link(L10n.Subscription.termsOfService, destination: URL(string: "https://aerocheck.app/terms")!)
                    .font(.caption2)
                    .foregroundColor(Color.altimeterBlue)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())

                Link(L10n.Subscription.privacyPolicy, destination: URL(string: "https://aerocheck.app/privacy")!)
                    .font(.caption2)
                    .foregroundColor(Color.altimeterBlue)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.top)
    }
}

// MARK: - Product Card

struct ProductCard: View {
    let product: Product
    /// When non-nil (the eligible yearly plan), shows a "N-day free trial" badge.
    var trialDays: Int? = nil
    @EnvironmentObject var subscriptionManager: SubscriptionManager

    private var isRecommended: Bool { product.isYearly }

    var body: some View {
        Button {
            Task { try? await subscriptionManager.purchase(product) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(product.displayName)
                            .font(.headline)
                            .foregroundColor(Color.primaryText)
                        if isRecommended {
                            tag(L10n.Subscription.bestValue, color: .aviationGold)
                        }
                    }

                    if let days = trialDays {
                        Text(L10n.Subscription.freeTrialDays(days))
                            .font(.caption).fontWeight(.semibold)
                            .foregroundColor(Color.aviationGreen)
                    } else if product.isLifetime {
                        Text(L10n.Subscription.lifetimeTagline)
                            .font(.caption)
                            .foregroundColor(Color.secondaryText)
                    } else {
                        Text(product.description)
                            .font(.caption)
                            .foregroundColor(Color.secondaryText)
                            .lineLimit(2)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundColor(Color.aviationGold)
                        // Scale the price down rather than truncate/wrap at large Dynamic Type. (v4.1.0)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(product.isLifetime ? L10n.Subscription.oneTime : product.subscriptionPeriodText)
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .layoutPriority(1)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isRecommended ? Color.aviationGold : Color.subtleOverlay(0.08), lineWidth: isRecommended ? 2 : 1))
            )
        }
        .disabled(subscriptionManager.isPurchasing)
        .opacity(subscriptionManager.isPurchasing ? 0.6 : 1.0)
        .accessibilityElement(children: .combine)
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2).fontWeight(.bold)
            .foregroundColor(.onAccent)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
    }
}

// MARK: - Preview

#Preview {
    SubscriptionView()
        .environmentObject(SubscriptionManager())
}
