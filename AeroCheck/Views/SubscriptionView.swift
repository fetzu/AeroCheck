import SwiftUI
import StoreKit

/// View for managing subscriptions
struct SubscriptionView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) var dismiss

    @State private var showingError = false
    @State private var errorMessage = ""

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Button.done) {
                        dismiss()
                    }
                    .foregroundColor(Color.aviationGold)
                }
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
        VStack(spacing: 12) {
            Image(systemName: "airplane.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(Color.aviationGold)

            Text(L10n.Subscription.unlockPremiumAircraft)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(Color.primaryText)

            Text(L10n.Subscription.accessDescription)
                .font(.subheadline)
                .foregroundColor(Color.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical)
    }

    private var benefitsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Subscription.benefits)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(Color.secondaryText)

            benefitRow(icon: "airplane", text: L10n.Subscription.benefitAllChecklists)
            benefitRow(icon: "arrow.triangle.2.circlepath", text: L10n.Subscription.benefitAutoUpdates)
            benefitRow(icon: "icloud.and.arrow.down", text: L10n.Subscription.benefitOfflineAccess)
            benefitRow(icon: "star.fill", text: L10n.Subscription.benefitSupportDev)
        }
        .padding()
        .background(Color.panelBackground)
        .cornerRadius(12)
    }

    private func benefitRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(Color.aviationGold)
                .frame(width: 30)

            Text(text)
                .font(.subheadline)
                .foregroundColor(Color.primaryText)

            Spacer()
        }
    }

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
            .background(Color.panelBackground)
            .cornerRadius(8)
        }
    }

    private var productsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Subscription.choosePlan)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(Color.secondaryText)

            if subscriptionManager.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            } else if subscriptionManager.products.isEmpty {
                Text(L10n.Subscription.unableToLoad)
                    .font(.subheadline)
                    .foregroundColor(Color.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding()

                Button(L10n.Subscription.retry) {
                    Task {
                        await subscriptionManager.loadProducts()
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
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
                    ProgressView()
                        .tint(Color.aviationBlue)
                } else {
                    Text(L10n.Subscription.restorePurchases)
                        .font(.subheadline)
                        .foregroundColor(Color.aviationBlue)
                }
            }
            .disabled(subscriptionManager.isLoading)
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
                    .foregroundColor(Color.aviationBlue)

                Link(L10n.Subscription.privacyPolicy, destination: URL(string: "https://aerocheck.app/privacy")!)
                    .font(.caption2)
                    .foregroundColor(Color.aviationBlue)
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
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.aviationGreen)
                                .cornerRadius(4)
                        }
                    }

                    Text(product.description)
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(Color.aviationGold)

                    Text(product.subscriptionPeriodText)
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)
                }
            }
            .padding()
            .background(Color.panelBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(product.isYearly ? Color.aviationGold : Color.clear, lineWidth: 2)
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
