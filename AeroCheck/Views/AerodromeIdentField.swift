import SwiftUI

// MARK: - Aerodrome field (v6.1)
//
// One aerodrome, typed by code or by name and completed from the airport data the way Plan new
// flight completes its stops: five fixed-wing suggestions from the second character, the aerodrome's
// name beside the code once it resolves. Used for the home aerodrome, in Settings › Flight Planning
// and in onboarding.

struct AerodromeIdentField: View {
    /// The aerodrome's ident, nil when the field is empty. Only a code the airport data knows gets here
    /// (or, with no airport data to check it against, one that could be a code).
    @Binding var ident: String?
    /// Offered under the empty field, one tap to take it: the logbook's best guess
    /// (`HomeAerodrome.suggestion(from:)`), nil for none.
    var suggestion: String? = nil

    @EnvironmentObject private var airports: AirportDataService
    @State private var text = ""
    @State private var suggestions: [Airport] = []
    @State private var isLoading = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField(L10n.Flights.identPlaceholder, text: $text)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.aero(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(.primaryText)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { commit() }
                    .accessibilityLabel(L10n.HomeAerodrome.title)
                resolvedName
                if !text.isEmpty {
                    Button {
                        text = ""
                        ident = nil
                        suggestions = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.dimText)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.HomeAerodrome.clear)
                }
            }
            .padding(.leading, 12)
            .frame(minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            )

            if isFocused, !suggestions.isEmpty {
                completionList
            } else if ident == nil, text.isEmpty, let suggestion {
                suggestionButton(suggestion)
            }

            if !isLoading, !airports.isDataAvailable {
                Text(L10n.HomeAerodrome.noAirportData)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { text = ident ?? "" }
        // Set from elsewhere (the suggestion, a synced change) while the pilot isn't typing
        .onChange(of: ident) { _, updated in
            if !isFocused { text = updated ?? "" }
        }
        .onChange(of: text) { _, typed in
            search()
            // An empty field clears it; a code the airport data knows is taken as soon as it's typed
            let trimmed = typed.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                ident = nil
            } else if let code = HomeAerodrome.normalized(trimmed), airports.findAirport(byIdent: code) != nil {
                ident = code
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
        .task {
            // Loaded on demand, like Plan new flight: without it the field silently offers nothing
            isLoading = true
            await airports.prepareSearch()
            isLoading = false
            // Typed while it was loading: that search had nothing to search.
            search()
        }
    }

    // MARK: - Pieces

    /// The aerodrome the code names (the check that LSZQ is Bressaucourt), or that the list is loading.
    @ViewBuilder
    private var resolvedName: some View {
        if let code = HomeAerodrome.normalized(text), let airport = airports.findAirport(byIdent: code) {
            Text(airport.name)
                .scaledFont(size: 14, relativeTo: .subheadline)
                .foregroundColor(.secondaryText)
                .lineLimit(1)
        } else if isLoading, !text.isEmpty {
            Text(L10n.PlanFlight.loadingAerodromes)
                .scaledFont(size: 14, relativeTo: .subheadline)
                .foregroundColor(.secondaryText)
                .lineLimit(1)
        }
    }

    private var completionList: some View {
        VStack(spacing: 0) {
            ForEach(suggestions, id: \.ident) { airport in
                Button { accept(airport) } label: {
                    HStack(spacing: 8) {
                        Text(airport.ident)
                            .font(.aero(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.aviationGold)
                            .frame(width: 64, alignment: .leading)
                        Text(airport.name)
                            .scaledFont(size: 14, relativeTo: .footnote)
                            .foregroundColor(.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(airport.ident), \(airport.name)")
                if airport.ident != suggestions.last?.ident {
                    Divider().overlay(Color.white.opacity(0.06))
                }
            }
        }
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground))
    }

    /// The logbook's guess, never set on its own: the pilot takes it with one tap, or types another.
    private func suggestionButton(_ code: String) -> some View {
        Button { take(code) } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .scaledFont(size: 15, relativeTo: .subheadline)
                    .foregroundColor(.aviationGold)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.HomeAerodrome.use(code))
                        .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundColor(.primaryText)
                    Text(airports.findAirport(byIdent: code).map { "\($0.name) · \(L10n.HomeAerodrome.suggestionReason)" }
                         ?? L10n.HomeAerodrome.suggestionReason)
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.aviationGold.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Behaviour

    private func search() {
        guard isFocused else { suggestions = []; return }
        let typed = text.trimmingCharacters(in: .whitespaces)
        // One character matches half of Europe; the list is noise until the second
        guard typed.count >= 2 else { suggestions = []; return }
        // A code typed in full needs no menu under it
        if let code = HomeAerodrome.normalized(typed), airports.findAirport(byIdent: code) != nil {
            suggestions = []
            return
        }
        suggestions = airports.searchAirports(query: typed, limit: 5, types: AirportType.fixedWing)
    }

    private func accept(_ airport: Airport) {
        take(airport.ident)
        isFocused = false
    }

    private func take(_ code: String) {
        text = code
        ident = code
        suggestions = []
    }

    /// Leaving the field: a code or a name that names one aerodrome is taken; anything else goes back to
    /// the aerodrome that was set, rather than keeping text that sets nothing.
    private func commit() {
        suggestions = []
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { ident = nil; return }

        if let code = HomeAerodrome.normalized(typed), airports.findAirport(byIdent: code) != nil {
            take(code)
            return
        }
        // Nothing to check against (not downloaded, or still loading): a code is taken as typed
        if !airports.isDataAvailable || isLoading, let code = HomeAerodrome.normalized(typed) {
            take(code)
            return
        }
        // A name: only when it names one aerodrome, or one exactly
        let hits = airports.searchAirports(query: typed, limit: 5, types: AirportType.fixedWing)
        if let hit = AirportDataService.aerodrome(named: typed, among: hits) {
            take(hit.ident)
        } else {
            text = ident ?? ""
        }
    }
}
