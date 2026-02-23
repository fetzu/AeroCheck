import SwiftUI

/// Peer discovery and connection sheet for iPhone companion mode
struct CompanionPairingView: View {
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if companionConnectivityManager.connectionState == .connected {
                    connectedContent
                } else if companionConnectivityManager.discoveredPeers.isEmpty {
                    searchingContent
                } else {
                    peerListContent
                }
            }
            .navigationTitle(L10n.Companion.connectToiPad)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) {
                        companionConnectivityManager.stopBrowsing()
                        dismiss()
                    }
                }
            }
            .onAppear {
                companionConnectivityManager.startBrowsing()
            }
            .onChange(of: companionConnectivityManager.connectionState) {
                if companionConnectivityManager.connectionState == .connected {
                    // Auto-dismiss after brief delay on successful connection
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Searching Content

    private var searchingContent: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 60))
                .foregroundColor(.aviationGold)
                .symbolEffect(.variableColor.iterative, options: .repeating)

            Text(L10n.Companion.searchingForDevices)
                .font(.headline)
                .foregroundColor(.primaryText)

            Text(L10n.Companion.searchingDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            ProgressView()
                .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Peer List Content

    private var peerListContent: some View {
        List {
            Section {
                ForEach(companionConnectivityManager.discoveredPeers) { peer in
                    Button(action: {
                        companionConnectivityManager.connectToPeer(peer)
                    }) {
                        HStack {
                            Image(systemName: "ipad")
                                .foregroundColor(.aviationGold)
                                .frame(width: 30)

                            VStack(alignment: .leading) {
                                Text(peer.name)
                                    .foregroundColor(.primary)
                            }

                            Spacer()

                            if companionConnectivityManager.connectionState == .connecting {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                    .disabled(companionConnectivityManager.connectionState == .connecting)
                }
            } header: {
                Text(L10n.Companion.availableDevices)
            } footer: {
                Text(L10n.Companion.tapToConnect)
            }
        }
    }

    // MARK: - Connected Content

    private var connectedContent: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.aviationGreen)

            Text(L10n.Companion.connected)
                .font(.headline)
                .foregroundColor(.aviationGreen)

            if let deviceName = companionConnectivityManager.connectedDeviceName {
                Text(String(format: L10n.Companion.connectedTo, deviceName))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}
