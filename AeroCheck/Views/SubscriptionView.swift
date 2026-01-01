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
            .background(DesignSystem.Colors.cockpitBackground)
            .navigationTitle("AeroCheck Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.aviationGold)
                }
            }
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
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
                .foregroundColor(DesignSystem.Colors.aviationGold)

            Text("Unlock Premium Aircraft")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(DesignSystem.Colors.primaryText)

            Text("Access additional aircraft checklists with an AeroCheck Pro subscription")
                .font(.subheadline)
                .foregroundColor(DesignSystem.Colors.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical)
    }

    private var benefitsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("BENEFITS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(DesignSystem.Colors.secondaryText)

            benefitRow(icon: "airplane", text: "Access to all premium aircraft checklists")
            benefitRow(icon: "arrow.triangle.2.circlepath", text: "Automatic updates when checklists change")
            benefitRow(icon: "icloud.and.arrow.down", text: "Offline access after download")
            benefitRow(icon: "star.fill", text: "Support continued development")
        }
        .padding()
        .background(DesignSystem.Colors.panelBackground)
        .cornerRadius(12)
    }

    private func benefitRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(DesignSystem.Colors.aviationGold)
                .frame(width: 30)

            Text(text)
                .font(.subheadline)
                .foregroundColor(DesignSystem.Colors.primaryText)

            Spacer()
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CURRENT STATUS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(DesignSystem.Colors.secondaryText)

            HStack {
                Image(systemName: subscriptionManager.subscriptionStatus.isSubscribed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(subscriptionManager.subscriptionStatus.isSubscribed ? DesignSystem.Colors.aviationGreen : DesignSystem.Colors.secondaryText)

                Text(subscriptionManager.subscriptionStatus.displayText)
                    .font(.subheadline)
                    .foregroundColor(DesignSystem.Colors.primaryText)

                Spacer()
            }
            .padding()
            .background(DesignSystem.Colors.panelBackground)
            .cornerRadius(8)
        }
    }

    private var productsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CHOOSE A PLAN")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(DesignSystem.Colors.secondaryText)

            if subscriptionManager.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            } else if subscriptionManager.products.isEmpty {
                Text("Unable to load subscription options")
                    .font(.subheadline)
                    .foregroundColor(DesignSystem.Colors.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding()

                Button("Retry") {
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
                        .tint(DesignSystem.Colors.aviationBlue)
                } else {
                    Text("Restore Purchases")
                        .font(.subheadline)
                        .foregroundColor(DesignSystem.Colors.aviationBlue)
                }
            }
            .disabled(subscriptionManager.isLoading)
        }
        .padding(.top)
    }

    private var termsSection: some View {
        VStack(spacing: 8) {
            Text("Subscriptions automatically renew unless cancelled at least 24 hours before the end of the current period. You can manage your subscription in your device's Settings app.")
                .font(.caption2)
                .foregroundColor(DesignSystem.Colors.dimText)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("Terms of Service", destination: URL(string: "https://aerocheck.app/terms")!)
                    .font(.caption2)
                    .foregroundColor(DesignSystem.Colors.aviationBlue)

                Link("Privacy Policy", destination: URL(string: "https://aerocheck.app/privacy")!)
                    .font(.caption2)
                    .foregroundColor(DesignSystem.Colors.aviationBlue)
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
                            .foregroundColor(DesignSystem.Colors.primaryText)

                        if product.isYearly {
                            Text("Best Value")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(DesignSystem.Colors.aviationGreen)
                                .cornerRadius(4)
                        }
                    }

                    Text(product.description)
                        .font(.caption)
                        .foregroundColor(DesignSystem.Colors.secondaryText)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(DesignSystem.Colors.aviationGold)

                    Text(product.subscriptionPeriodText)
                        .font(.caption2)
                        .foregroundColor(DesignSystem.Colors.secondaryText)
                }
            }
            .padding()
            .background(DesignSystem.Colors.panelBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(product.isYearly ? DesignSystem.Colors.aviationGold : Color.clear, lineWidth: 2)
            )
        }
        .disabled(subscriptionManager.isPurchasing)
        .opacity(subscriptionManager.isPurchasing ? 0.6 : 1.0)
    }
}

// MARK: - Button Styles

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(DesignSystem.Colors.aviationBlue)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(DesignSystem.Colors.aviationBlue, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}

// MARK: - Preview

#Preview {
    SubscriptionView()
        .environmentObject(SubscriptionManager())
}
