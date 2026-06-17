import SwiftUI
import StoreKit

/// View for managing subscriptions
struct SubscriptionView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) var dismiss

    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isLoadingProducts = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    headerSection

                    // Benefits
                    benefitsSection

                    // Current Status
                    statusSection

                    // Products
                    if !subscriptionManager.subscriptionStatus.isSubscribed {
                        productsSection
                    }

                    // Restore Purchases
                    restoreSection

                    // Terms
                    termsSection
                }
                .padding()
            }
            .background(Color.cockpitBackground)
            .navigationTitle(L10n.Settings.aeroCheckPro)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.done) {
                        dismiss()
                    }
                    .foregroundColor(Color.aviationGold)
                }
            }
        }
        .onAppear {
            // Ensure products are loaded when the view appears
            if subscriptionManager.products.isEmpty {
                isLoadingProducts = true
                Task {
                    await subscriptionManager.loadProducts()
                    isLoadingProducts = false
                }
            }
            // Refresh subscription status
            Task {
                await subscriptionManager.updateSubscriptionStatus()
            }
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

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 14) {
            Image(systemName: "airplane")
                .font(.system(size: 30))
                .foregroundColor(Color.aviationGold)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.aviationGold.opacity(0.16)))
                .accessibilityHidden(true)

            Text(L10n.Subscription.unlockPremiumAircraft)
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
                    .font(.system(size: 16))
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
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Subscription.currentStatus)
                .font(.caption)
                .fontWeight(.semibold)
                .tracking(1.2)
                .textCase(.uppercase)
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

    private var productsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Subscription.choosePlan)
                .font(.caption)
                .fontWeight(.semibold)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundColor(Color.secondaryText)

            if subscriptionManager.products.isEmpty {
                if isLoadingProducts {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
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
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                ForEach(subscriptionManager.products) { product in
                    ProductCard(product: product)
                }
            }
        }
    }

    private var restoreSection: some View {
        VStack(spacing: 8) {
            Button(action: {
                Task {
                    await subscriptionManager.restorePurchases()
                }
            }) {
                if subscriptionManager.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(Color.aviationBlue)
                        Text(L10n.Subscription.restorePurchases)
                            .font(.subheadline)
                            .foregroundColor(Color.aviationBlue.opacity(0.5))
                    }
                } else {
                    Text(L10n.Subscription.restorePurchases)
                        .font(.subheadline)
                        .foregroundColor(Color.aviationBlue)
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
                // altimeterBlue (light) instead of aviationBlue (very dark, ~1.5:1 on the dark
                // background); plus a 44pt touch target for the legal links. (v4.0.0 review P2)
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
    @EnvironmentObject var subscriptionManager: SubscriptionManager

    var body: some View {
        Button(action: {
            Task {
                try? await subscriptionManager.purchase(product)
            }
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(product.displayName)
                            .font(.headline)
                            .foregroundColor(Color.primaryText)

                        if product.isYearly {
                            Text(L10n.Subscription.bestValue)
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.onAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.aviationGold))
                        }
                    }

                    Text(product.description)
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundColor(Color.aviationGold)

                    Text(product.subscriptionPeriodText)
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(product.isYearly ? Color.aviationGold : Color.subtleOverlay(0.08), lineWidth: product.isYearly ? 2 : 1))
            )
        }
        .disabled(subscriptionManager.isPurchasing)
        .opacity(subscriptionManager.isPurchasing ? 0.6 : 1.0)
    }
}

// MARK: - Preview

#Preview {
    SubscriptionView()
        .environmentObject(SubscriptionManager())
}
