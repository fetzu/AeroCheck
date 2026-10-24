import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit
import WebKit

// MARK: - Sending an aircraft's checklist (6.3.0)
//
// The website's form (aerocheck.app/send/), field for field and in its words, as a sheet: from the
// Aircraft tab, Today's aircraft menu and the Pro sheet. The registration first: one the app has makes
// it an update. The checklist comes as a scan (one PDF), photos or files. Above Send, the Turnstile check
// the website runs, in a web view (`TurnstileCheck`). The protocol and the rules are in
// AircraftRequests.swift.

struct AircraftRequestSheet: View {
    /// A registration to start from (an aircraft whose checklist is outdated, say).
    var registration: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var store = AircraftRequestStore.shared
    @StateObject private var check = TurnstileCheck(locale: AircraftRequestIntake.locale)

    /// The sender's name and e-mail, remembered on this device for the next request.
    @AppStorage("aircraftRequest.senderEmail") private var rememberedEmail = ""
    @AppStorage("aircraftRequest.senderName") private var rememberedName = ""

    @State private var form = AircraftRequestForm()
    @State private var lookingUp = false
    @State private var lookupMessage: String?
    @State private var showsProblems = false
    @State private var message: String?
    @State private var stage: Stage = .editing
    /// A request created on the worker whose files are on their way, and the next file to send.
    @State private var pending: AircraftRequestUpload?
    @State private var nextFile = 0
    @State private var uploadFraction: Double = 0
    @State private var showsScanner = false
    @State private var showsFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var fileMessage: String?

    private let tint = Color.aviationGold

    enum Stage: Equatable {
        case editing
        case sending(String)
        /// An upload stopped: Try again goes on from the file it stopped at.
        case stopped(String)
        case sent(SentAircraftRequest)
    }

    var body: some View {
        NavigationStack {
            Group {
                if case .sent(let sent) = stage {
                    result(sent)
                } else {
                    formPage
                }
            }
            .navigationTitle(L10n.AircraftRequests.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Cancel while the request is written, Close once it is sent: on the left both times, as every sheet that
                // has nothing to confirm (Apple's sheets guidance; the author's A, 25 Oct 2026). (6.6.0)
                ToolbarItem(placement: .cancellationAction) {
                    if case .sent = stage {
                        Button(L10n.Button.close) { dismiss() }
                    } else {
                        Button(L10n.Button.cancel) { dismiss() }
                            .disabled(isSending)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSending || pending != nil)
        .onAppear {
            if form.registration.isEmpty { form.registration = registration }
            if form.senderEmail.isEmpty { form.senderEmail = rememberedEmail }
            if form.senderName.isEmpty { form.senderName = rememberedName }
            if !registration.isEmpty { Task { await lookUp() } }
            #if DEBUG
            fillSampleIfAsked()
            #endif
        }
        .sheet(isPresented: $showsScanner) {
            DocumentScanner { pages in
                showsScanner = false
                addScan(pages)
            } onCancel: {
                showsScanner = false
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.pdf, .jpeg, .png, .heic],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPhotos(items) }
        }
    }

    private var isSending: Bool {
        if case .sending = stage { return true }
        return false
    }

    /// The form can't change once the request is on the worker: its files are announced.
    private var isLocked: Bool { isSending || pending != nil }

    private var showsProgress: Bool {
        switch stage {
        case .sending, .stopped: return true
        default: return false
        }
    }

    // MARK: - The form

    private var formPage: some View {
        SettingsPage {
            Text(L10n.AircraftRequests.intro)
                .font(.aero(.subheadline))
                .foregroundColor(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            registrationGroup
            if form.lookupIsCurrent {
                aircraftGroup
                if !form.club.trimmingCharacters(in: .whitespaces).isEmpty { senderGroup }
                checklistGroup
                youGroup
                statementsGroup
                sendGroup
            }
        }
        .disabled(isLocked)
        .overlay(alignment: .bottom) {
            if showsProgress { progressCard.padding(16) }
        }
    }

    private var registrationGroup: some View {
        SettingsGroup(title: L10n.AircraftRequests.registrationSection, tint: tint,
                      footer: L10n.AircraftRequests.registrationHint) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    field(L10n.AircraftRequests.registrationLabel, text: $form.registration, capitals: true)
                        .onSubmit { Task { await lookUp() } }
                    Button {
                        Task { await lookUp() }
                    } label: {
                        if lookingUp {
                            ProgressView().accessibilityLabel(L10n.AircraftRequests.lookingUp)
                        } else {
                            Text(L10n.AircraftRequests.lookUp)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(color: tint, isLarge: false))
                    .disabled(lookingUp || form.registration.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let lookupMessage {
                    warning(lookupMessage)
                } else if form.lookupIsCurrent, let lookup = form.lookup {
                    lookupAnswer(lookup)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    @ViewBuilder
    private func lookupAnswer(_ lookup: AircraftLookup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lookup.known ? L10n.AircraftRequests.knownTitle(lookup.registration)
                              : L10n.AircraftRequests.unknownTitle(lookup.registration))
                .font(.aero(.subheadline).weight(.semibold))
                .foregroundColor(.primaryText)
            Text(lookup.known ? L10n.AircraftRequests.knownBody : L10n.AircraftRequests.unknownBody)
                .font(.aero(.caption))
                .foregroundColor(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if lookup.known {
                fact(L10n.AircraftRequests.knownModel, lookup.modelName)
                fact(L10n.AircraftRequests.knownClub, lookup.aeroclub)
                fact(L10n.AircraftRequests.knownVersion, lookup.version)
                fact(L10n.AircraftRequests.knownLanguages, lookup.languages.map { $0.map(Self.languageName).joined(separator: ", ") })
            }
        }
    }

    @ViewBuilder
    private func fact(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.aero(.caption)).foregroundColor(.dimText)
                Text(value).font(.aero(.caption).weight(.medium)).foregroundColor(.primaryText)
            }
        }
    }

    private var aircraftGroup: some View {
        SettingsGroup(title: L10n.AircraftRequests.aircraftSection, tint: tint) {
            if form.kind == .new {
                labelled(L10n.AircraftRequests.otherRegistrationsLabel, hint: L10n.AircraftRequests.otherRegistrationsHint) {
                    field("HB-KFI, HB-KFO", text: $form.otherRegistrations, capitals: true)
                }
                labelled(L10n.AircraftRequests.typeLabel, hint: L10n.AircraftRequests.typeHint) {
                    field("Robin DR400/180", text: $form.aircraftType)
                }
            }
            labelled(L10n.AircraftRequests.clubLabel, hint: L10n.AircraftRequests.clubHint) {
                field("", text: $form.club)
            }
        }
    }

    private var senderGroup: some View {
        SettingsGroup(title: L10n.AircraftRequests.senderSection, tint: tint) {
            choice(L10n.AircraftRequests.forClub, hint: L10n.AircraftRequests.forClubHint, value: .forClub)
            choice(L10n.AircraftRequests.asPilot, hint: L10n.AircraftRequests.asPilotHint, value: .asPilot)
            if form.sendingFor == .asPilot {
                labelled(L10n.AircraftRequests.contactLabel, hint: L10n.AircraftRequests.contactHint) {
                    field("", text: $form.clubContactEmail, keyboard: .emailAddress)
                        .disabled(form.contactUnknown)
                        .opacity(form.contactUnknown ? 0.5 : 1)
                }
                SettingsToggleRow(title: L10n.AircraftRequests.contactUnknown,
                                  subtitle: L10n.AircraftRequests.contactUnknownHint,
                                  tint: tint, isOn: $form.contactUnknown)
            }
        }
    }

    private func choice(_ title: String, hint: String, value: AircraftRequestForm.SendingFor) -> some View {
        Button {
            form.sendingFor = value
        } label: {
            HStack(spacing: 10) {
                SettingsRowLabel(title: title, subtitle: hint, tint: tint)
                Image(systemName: form.sendingFor == value ? "largecircle.fill.circle" : "circle")
                    .font(.aero(size: 20))
                    .foregroundColor(form.sendingFor == value ? tint : .dimText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(form.sendingFor == value ? .isSelected : [])
    }

    private var checklistGroup: some View {
        SettingsGroup(title: L10n.AircraftRequests.checklistSection, tint: tint,
                      footer: form.kind == .update ? L10n.AircraftRequests.filesHintUpdate : L10n.AircraftRequests.filesHintNew) {
            ForEach(form.files) { file in
                fileRow(file)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if VNDocumentCameraViewController.isSupported {
                        Button { showsScanner = true } label: {
                            Label(L10n.AircraftRequests.scan, systemImage: "doc.viewfinder")
                        }
                    }
                    PhotosPicker(selection: $photoItems,
                                 maxSelectionCount: max(1, AircraftRequestIntake.maxFiles - form.files.count),
                                 matching: .images) {
                        Label(L10n.AircraftRequests.photos, systemImage: "photo.on.rectangle")
                    }
                    Button { showsFiles = true } label: {
                        Label(L10n.AircraftRequests.files, systemImage: "folder")
                    }
                }
                .buttonStyle(SecondaryButtonStyle(color: tint, isLarge: false))
                .disabled(form.files.count >= AircraftRequestIntake.maxFiles)
                if VNDocumentCameraViewController.isSupported {
                    Text(L10n.AircraftRequests.scanHint).font(.aero(.caption2)).foregroundColor(.dimText)
                }
                Text(L10n.AircraftRequests.filesTotal(form.files.count, Self.size(form.totalBytes)))
                    .font(.aero(.caption))
                    .foregroundColor(.secondaryText)
                if let fileMessage { warning(fileMessage) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            languages
        }
    }

    private func fileRow(_ file: AircraftRequestFile) -> some View {
        HStack(spacing: 10) {
            SettingsRowLabel(icon: file.kind == .pdf ? "doc.richtext" : "photo",
                             title: file.name, subtitle: Self.size(file.size), tint: tint)
            Button {
                form.files.removeAll { $0.id == file.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.aero(size: 20))
                    .foregroundColor(.dimText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.AircraftRequests.remove(file.name))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var languages: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.AircraftRequests.languagesLabel).font(.aero(.subheadline)).foregroundColor(.primaryText)
            Text(L10n.AircraftRequests.languagesHint)
                .font(.aero(.caption)).foregroundColor(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(AircraftRequestIntake.commonLanguages, id: \.self) { code in
                    languageBox(code)
                }
            }
            Text(L10n.AircraftRequests.otherLanguageLabel).font(.aero(.caption)).foregroundColor(.secondaryText)
            field("", text: $form.otherLanguages)
            Text(L10n.AircraftRequests.otherLanguageHint)
                .font(.aero(.caption2)).foregroundColor(.dimText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func languageBox(_ code: String) -> some View {
        let on = form.languages.contains(code)
        return Button {
            if on { form.languages.removeAll { $0 == code } } else { form.languages.append(code) }
        } label: {
            Text(Self.languageName(code))
                .font(.aero(.subheadline).weight(on ? .semibold : .regular))
                .foregroundColor(on ? .onAccent : .primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(on ? tint : Color.cardBackground))
                .overlay(Capsule().strokeBorder(on ? tint : Color.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var youGroup: some View {
        SettingsGroup(title: L10n.AircraftRequests.youSection, tint: tint) {
            labelled(L10n.AircraftRequests.nameLabel, hint: L10n.AircraftRequests.nameHint) {
                field("", text: $form.senderName, words: true)
            }
            labelled(L10n.AircraftRequests.emailLabel, hint: L10n.AircraftRequests.emailHint) {
                field("", text: $form.senderEmail, keyboard: .emailAddress)
            }
            labelled(L10n.AircraftRequests.notesLabel, hint: L10n.AircraftRequests.notesHint) {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("", text: $form.notes, axis: .vertical)
                        .lineLimit(3...8)
                        .scaledFont(size: 16, relativeTo: .body)
                        .foregroundColor(.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.cockpitBackground))
                    Text(L10n.AircraftRequests.counter(form.notes.count, AircraftRequestIntake.notesMax))
                        .font(.aero(.caption2).monospacedDigit())
                        .foregroundColor(form.notes.count > AircraftRequestIntake.notesMax ? .aviationRed : .dimText)
                }
            }
        }
    }

    private var statementsGroup: some View {
        SettingsGroup(tint: tint) {
            SettingsToggleRow(title: rightsText, tint: tint, isOn: $form.rights)
            SettingsToggleRow(title: L10n.AircraftRequests.privacyLabel, tint: tint, isOn: $form.privacy)
            HStack(spacing: 16) {
                Button(L10n.AircraftRequests.termsLink) { openURL(Self.termsURL) }
                Button(L10n.AircraftRequests.privacyLink) { openURL(Self.privacyURL) }
            }
            .font(.aero(.caption))
            .tint(.altimeterBlue)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var rightsText: String {
        if form.club.trimmingCharacters(in: .whitespaces).isEmpty { return L10n.AircraftRequests.rightsPrivate }
        return form.sendingFor == .forClub ? L10n.AircraftRequests.rightsClub : L10n.AircraftRequests.rightsSelf
    }

    private var sendGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            checkCard
            if showsProblems, !form.problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.AircraftRequests.summary).font(.aero(.subheadline).weight(.semibold))
                    ForEach(Array(form.problems.enumerated()), id: \.offset) { _, problem in
                        Text("• " + Self.text(for: problem)).font(.aero(.caption))
                    }
                }
                .foregroundColor(.aviationAmber)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let message { warning(message) }
            Button {
                Task { await send() }
            } label: {
                Text(L10n.AircraftRequests.submit).frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(color: tint))
        }
    }

    /// The Turnstile check, as the website shows it above its Send: a line while it works on its own,
    /// Cloudflare's widget when it wants a tap.
    private var checkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.AircraftRequests.checkLabel).font(.aero(.caption)).foregroundColor(.secondaryText)
            TurnstileWebView(check: check)
                .frame(height: check.state == .interactive ? 70 : 1)
                .opacity(check.state == .interactive ? 1 : 0.01)
            switch check.state {
            case .loading:
                checkLine(L10n.AircraftRequests.checkLoading, busy: true)
            case .waiting:
                checkLine(L10n.AircraftRequests.checkWorking, busy: true)
            case .interactive:
                EmptyView()
            case .passed:
                Label(L10n.AircraftRequests.checkPassed, systemImage: "checkmark.seal.fill")
                    .font(.aero(.subheadline))
                    .foregroundColor(.aviationGreen)
            case .failed:
                VStack(alignment: .leading, spacing: 8) {
                    warning(L10n.AircraftRequests.checkFailed)
                    Button(L10n.Button.retry) { check.start() }
                        .buttonStyle(SecondaryButtonStyle(color: tint, isLarge: false))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.cardBackground))
        // Loaded once the form gets this far, like the website's widget above its Send.
        .onAppear { if !check.hasStarted { check.start() } }
    }

    private func checkLine(_ text: String, busy: Bool) -> some View {
        HStack(spacing: 8) {
            if busy { ProgressView() }
            Text(text).font(.aero(.subheadline)).foregroundColor(.secondaryText)
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch stage {
            case .sending(let line):
                Text(line).font(.aero(.subheadline)).foregroundColor(.primaryText)
                ProgressView(value: uploadFraction).tint(tint)
            case .stopped(let line):
                warning(line)
                HStack(spacing: 10) {
                    Button(L10n.Button.retry) { Task { await runUploads() } }
                        .buttonStyle(PrimaryButtonStyle(color: tint, isLarge: false))
                    Button(L10n.Button.cancel) { pending = nil; stage = .editing }
                        .buttonStyle(SecondaryButtonStyle(color: tint, isLarge: false))
                }
            default:
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    // MARK: - Sent

    private func result(_ sent: SentAircraftRequest) -> some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.AircraftRequests.resultTitle(sent.ticket), systemImage: "checkmark.circle.fill")
                    .font(.aero(.title3).weight(.bold))
                    .foregroundColor(.aviationGreen)
                Text(L10n.AircraftRequests.resultBody(form.senderEmail.trimmingCharacters(in: .whitespaces)))
                    .font(.aero(.subheadline)).foregroundColor(.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsGroup(title: L10n.AircraftRequests.nextTitle, tint: tint) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.AircraftRequests.nextBody)
                    if form.effectiveSendingFor == .asPilot, !form.club.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(form.contactUnknown ? L10n.AircraftRequests.nextClubNoContact : L10n.AircraftRequests.nextClub)
                    }
                }
                .font(.aero(.subheadline))
                .foregroundColor(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
            }
            if let url = store.pageURL(of: sent) {
                Button {
                    openURL(url)
                } label: {
                    Label(L10n.AircraftRequests.openPage, systemImage: "safari").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(color: tint))
            }
        }
    }

    // MARK: - Pieces

    private func labelled<Content: View>(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.aero(.subheadline)).foregroundColor(.primaryText)
            content()
            if let hint {
                Text(hint).font(.aero(.caption2)).foregroundColor(.dimText).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func field(_ placeholder: String, text: Binding<String>, capitals: Bool = false, words: Bool = false,
                       keyboard: UIKeyboardType = .default) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(capitals ? .characters : words ? .words : .never)
            .autocorrectionDisabled(capitals || keyboard == .emailAddress)
            .keyboardType(keyboard)
            .textContentType(keyboard == .emailAddress ? .emailAddress : nil)
            .scaledFont(size: 16, relativeTo: .body)
            .foregroundColor(.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.cockpitBackground))
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.aero(.caption))
        .foregroundColor(.aviationAmber)
    }

    /// A language in the app's language: "German", "allemand".
    static func languageName(_ code: String) -> String {
        let locale = Locale(identifier: AircraftRequestIntake.locale)
        return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? code
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The website in the request's language: English at the root, the others under their code (/fr, /de).
    private static var site: String {
        let locale = AircraftRequestIntake.locale
        return locale == "en" ? "https://aerocheck.app" : "https://aerocheck.app/\(locale)"
    }
    /// The terms are English in every language, so their anchor is the English one.
    static var termsURL: URL { URL(string: site + "/terms/#40-sending-us-an-aircrafts-checklist")! }
    /// Section 4.3 of the privacy policy, whose anchor is its heading in that language.
    private static let privacyAnchors = [
        "en": "#43-aircraft-requests-intakeaerocheckapp",
        "fr": "#43-demandes-davions-intakeaerocheckapp",
        "de": "#43-flugzeuganfragen-intakeaerocheckapp",
    ]
    static var privacyURL: URL {
        URL(string: site + "/privacy/" + (privacyAnchors[AircraftRequestIntake.locale] ?? privacyAnchors["en"]!))!
    }

    static func text(for problem: AircraftRequestForm.Problem) -> String {
        switch problem {
        case .registrationLookup: return L10n.AircraftRequests.problemRegistrationLookup
        case .otherRegistrationsInvalid(let list): return L10n.AircraftRequests.problemOtherRegistrationsInvalid(list.joined(separator: ", "))
        case .tooManyRegistrations: return L10n.AircraftRequests.problemTooManyRegistrations
        case .typeRequired: return L10n.AircraftRequests.problemTypeRequired
        case .sendingForRequired: return L10n.AircraftRequests.problemSendingForRequired
        case .contactRequired: return L10n.AircraftRequests.problemContactRequired
        case .contactInvalid: return L10n.AircraftRequests.problemContactInvalid
        case .contactIsSender: return L10n.AircraftRequests.problemContactIsSender
        case .emailRequired: return L10n.AircraftRequests.problemEmailRequired
        case .emailInvalid: return L10n.AircraftRequests.problemEmailInvalid
        case .languagesRequired: return L10n.AircraftRequests.problemLanguagesRequired
        case .languageInvalid(let value): return L10n.AircraftRequests.problemLanguageInvalid(value)
        case .languagesTooMany: return L10n.AircraftRequests.problemLanguagesTooMany
        case .filesRequired: return L10n.AircraftRequests.problemFilesRequired
        case .tooManyFiles: return L10n.AircraftRequests.problemTooManyFiles
        case .fileTooBig(let name, let bytes): return L10n.AircraftRequests.problemFileTooBig(name, size(bytes))
        case .totalTooBig(let bytes): return L10n.AircraftRequests.problemTotalTooBig(size(bytes))
        case .notesTooLong: return L10n.AircraftRequests.problemNotesTooLong
        case .rightsRequired: return L10n.AircraftRequests.problemRightsRequired
        case .privacyRequired: return L10n.AircraftRequests.problemPrivacyRequired
        }
    }

    /// What to tell the sender for an error the intake answered.
    static func text(for error: AircraftRequestError) -> String {
        switch error.code {
        case "network": return L10n.AircraftRequests.errorNetwork
        case "invalid_registration": return L10n.AircraftRequests.errorInvalidRegistration
        case "invalid_email": return L10n.AircraftRequests.errorInvalidEmail
        case "club_contact_is_sender": return L10n.AircraftRequests.errorClubContactIsSender
        case "too_many_files", "bad_type", "file_too_large", "total_too_large", "bad_file":
            return L10n.AircraftRequests.errorFiles
        case "unknown_registration": return L10n.AircraftRequests.errorUnknownRegistration
        case "known_registration": return L10n.AircraftRequests.errorKnownRegistration
        case "size_mismatch": return L10n.AircraftRequests.errorSizeMismatch
        case "turnstile_failed", "forbidden": return L10n.AircraftRequests.errorTurnstileFailed
        case "not_found": return L10n.AircraftRequests.errorUploadGone
        case "payload_too_large": return L10n.AircraftRequests.errorPayloadTooLarge
        case "rate_limited": return L10n.AircraftRequests.errorRateLimited
        case "internal": return L10n.AircraftRequests.errorInternal
        case "unavailable": return L10n.AircraftRequests.errorUnavailable
        case "daily_cap": return L10n.AircraftRequests.errorDailyCap
        case "lookup_unavailable": return L10n.AircraftRequests.errorLookupUnavailable
        case "invalid_field", "invalid_json", "rights_required", "privacy_required": return L10n.AircraftRequests.errorField
        default: return L10n.AircraftRequests.errorUnknown
        }
    }

    // MARK: - Actions

    private func lookUp() async {
        guard !lookingUp else { return }
        lookingUp = true
        defer { lookingUp = false }
        lookupMessage = nil
        do {
            let lookup = try await store.lookup(form.registration)
            form.lookup = lookup
            form.registration = lookup.registration
            if lookup.known, form.club.isEmpty, let club = lookup.aeroclub { form.club = club }
        } catch let error as AircraftRequestError {
            form.lookup = nil
            lookupMessage = Self.text(for: error)
        } catch {
            lookupMessage = L10n.AircraftRequests.errorUnknown
        }
    }

    private func send() async {
        message = nil
        showsProblems = true
        guard form.problems.isEmpty else { return }
        guard let token = check.token else {
            message = L10n.AircraftRequests.checkMissing
            return
        }
        guard let submission = form.submission(turnstileToken: token, locale: AircraftRequestIntake.locale) else { return }
        rememberedEmail = submission.senderEmail
        rememberedName = submission.senderName ?? ""
        uploadFraction = 0
        stage = .sending(L10n.AircraftRequests.progressSending)
        let upload: AircraftRequestUpload
        do {
            upload = try await store.create(submission)
        } catch {
            // A token is good for one try, whatever its outcome (the website resets it the same way).
            check.reset()
            stage = .editing
            await refused(error as? AircraftRequestError ?? .unexpected)
            return
        }
        check.reset()
        pending = upload
        nextFile = 0
        await runUploads()
    }

    /// The files, from the one not sent yet, then the completion.
    private func runUploads() async {
        guard let upload = pending else { return }
        let files = form.files
        let count = upload.slots.count
        while nextFile < count {
            let file = files[nextFile]
            let done = nextFile
            uploadFraction = Double(done) / Double(count)
            stage = .sending(L10n.AircraftRequests.progressUpload(done + 1, count, file.name))
            do {
                try await store.upload(file, to: upload.slots[done]) { fraction in
                    Task { @MainActor in uploadFraction = (Double(done) + fraction) / Double(count) }
                }
            } catch let error as AircraftRequestError {
                switch error.code {
                case "not_found", "wrong_state":
                    // The slot expired (24 h) or the request moved on: start again from the form.
                    pending = nil
                    stage = .editing
                    message = Self.text(for: error)
                case "size_mismatch", "bad_file":
                    pending = nil
                    stage = .editing
                    message = Self.text(for: error)
                default:
                    stage = .stopped(L10n.AircraftRequests.uploadStopped(file.name))
                }
                return
            } catch {
                stage = .stopped(L10n.AircraftRequests.uploadStopped(file.name))
                return
            }
            nextFile += 1
        }
        uploadFraction = 1
        stage = .sending(L10n.AircraftRequests.progressFinishing)
        do {
            let sent = try await store.complete(upload)
            pending = nil
            stage = .sent(sent)
            // The "it's in AéroCheck" notice needs the permission: asked now, with its reason in front
            // of the pilot, as a flight's reminders ask it when a flight is first followed.
            Task { await NotificationService.shared.requestAuthorization() }
        } catch let error as AircraftRequestError {
            switch error {
            case .intake(code: "missing_files", _, _, _):
                // Not every file arrived: they are sent once more.
                nextFile = 0
                stage = .stopped(L10n.AircraftRequests.uploadStopped(files.first?.name ?? ""))
            case .intake(code: "wrong_state", _, _, let ticket?):
                pending = nil
                stage = .editing
                message = L10n.AircraftRequests.errorAlreadySent(ticket)
            default:
                stage = .stopped(Self.text(for: error))
            }
        } catch {
            stage = .stopped(L10n.AircraftRequests.errorUnknown)
        }
    }

    /// A refused request: the website's handling of each refusal.
    private func refused(_ error: AircraftRequestError) async {
        guard case .intake(let code, _, let named, _) = error,
              code == "known_registration" || code == "unknown_registration" else {
            message = Self.text(for: error)
            return
        }
        if code == "known_registration", let main = form.lookup?.registration, !named.isEmpty, !named.contains(main) {
            // The first registration is new; some of the others aren't.
            message = L10n.AircraftRequests.errorKnownOthers(named.joined(separator: ", "))
            return
        }
        // AéroCheck's list changed since the lookup: look again, and the form follows.
        let wasUpdate = form.kind == .update
        form.lookup = nil
        await lookUp()
        message = form.kind == .update && !wasUpdate || form.kind == .new && wasUpdate
            ? Self.text(for: error) : L10n.AircraftRequests.errorListChanged
    }

    #if DEBUG
    /// `AEROCHECK_REQUEST_SAMPLE=1`: the form filled in for a check against a local intake (a new
    /// aircraft, a one-page PDF), so only the Turnstile check and Send are left to tap. Never in
    /// Release, and it fills nothing a pilot typed.
    private func fillSampleIfAsked() {
        guard ProcessInfo.processInfo.environment["AEROCHECK_REQUEST_SAMPLE"] == "1", form.registration.isEmpty else { return }
        form.registration = "HB-XYZ"
        form.aircraftType = "Robin DR400/180"
        form.senderEmail = "pilot@example.com"
        form.languages = ["fr"]
        form.rights = true
        form.privacy = true
        let page = UIGraphicsImageRenderer(size: CGSize(width: 1240, height: 1754)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1240, height: 1754))
        }
        if let file = AircraftRequestFile(name: "HB-XYZ-scan.pdf", data: AircraftRequestScan.pdf(of: [page])) {
            form.files = [file]
        }
        Task { await lookUp() }
    }
    #endif

    private func addScan(_ pages: [UIImage]) {
        guard !pages.isEmpty else { return }
        let data = AircraftRequestScan.pdf(of: pages)
        let reg = form.lookup?.registration ?? "checklist"
        if let file = AircraftRequestFile(name: "\(reg)-scan.pdf", data: data) { add([file]) }
    }

    private func addFiles(_ urls: [URL]) {
        var files: [AircraftRequestFile] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let file = AircraftRequestFile(name: url.lastPathComponent, data: data) else {
                fileMessage = L10n.AircraftRequests.fileUnreadable(url.lastPathComponent)
                continue
            }
            files.append(file)
        }
        add(files)
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        var files: [AircraftRequestFile] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let file = AircraftRequestScan.photo(data, name: "photo-\(form.files.count + index + 1)") else {
                fileMessage = L10n.AircraftRequests.fileUnreadable("photo-\(form.files.count + index + 1)")
                continue
            }
            files.append(file)
        }
        photoItems = []
        add(files)
    }

    private func add(_ files: [AircraftRequestFile]) {
        if !files.isEmpty { fileMessage = nil }
        for file in files where form.files.count < AircraftRequestIntake.maxFiles { form.files.append(file) }
    }
}

// MARK: - The requests sent, in the Aircraft tab

/// The requests sent from this device: where each stands, as the website's status page names it. A tap
/// opens the request's page (the history, the proofreading, the club's contact); a long press takes it
/// off the list. (6.3.0)
struct AircraftRequestsGroup: View {
    var tint: Color = .aviationGold
    @ObservedObject private var store = AircraftRequestStore.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !store.requests.isEmpty {
            SettingsGroup(title: L10n.AircraftRequests.requestsSection, tint: tint,
                          footer: L10n.AircraftRequests.requestsFooter) {
                ForEach(store.requests) { request in
                    row(request)
                }
            }
            .task { await store.refreshIfDue() }
        }
    }

    private func row(_ request: SentAircraftRequest) -> some View {
        let status = request.currentStatus
        let words = L10n.AircraftRequests.status(status)
        return Button {
            if let url = store.pageURL(of: request) { openURL(url) }
        } label: {
            HStack(spacing: 10) {
                SettingsRowLabel(icon: Self.icon(status),
                                 title: request.registrations.joined(separator: ", ") + " · " + request.aircraftType,
                                 subtitle: request.ticket + " · " + words.line,
                                 tint: Self.tint(status, accent: tint))
                Text(words.label)
                    .font(.aero(.subheadline).weight(.semibold))
                    .foregroundColor(Self.tint(status, accent: tint))
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.aero(size: 13, weight: .semibold))
                    .foregroundColor(.dimText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { store.remove(request) } label: {
                Label(L10n.AircraftRequests.removeFromList, systemImage: "trash")
            }
        }
    }

    static func icon(_ status: AircraftRequestStatus) -> String {
        switch status {
        case .uploading, .received: return "tray.and.arrow.down"
        case .accepted: return "checkmark.circle"
        case .converting: return "gearshape.2"
        case .proofreading: return "text.magnifyingglass"
        case .testflight: return "hammer"
        case .live: return "airplane"
        case .needInfo: return "questionmark.circle"
        case .declined: return "xmark.circle"
        case .duplicate: return "square.on.square"
        }
    }

    static func tint(_ status: AircraftRequestStatus, accent: Color) -> Color {
        switch status {
        case .live: return .aviationGreen
        case .needInfo: return .aviationAmber
        case .declined, .duplicate: return .secondaryText
        default: return accent
        }
    }
}

// MARK: - Scans and photos

/// A scan's pages as one PDF, and a photo as a file the intake takes.
enum AircraftRequestScan {
    /// The pages, each as a JPEG at most `maxSide` points on its long side, one PDF page each at the
    /// page's own proportions. A ten-page scan stays a few megabytes.
    static func pdf(of pages: [UIImage], maxSide: CGFloat = 1800, quality: CGFloat = 0.7) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        return renderer.pdfData { context in
            for page in pages {
                let image = downscaled(page, maxSide: maxSide)
                let jpeg = image.jpegData(compressionQuality: quality).flatMap(UIImage.init(data:)) ?? image
                // A4 width, the page's own height.
                let width: CGFloat = 595
                let height = width * jpeg.size.height / max(jpeg.size.width, 1)
                let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                jpeg.draw(in: bounds)
            }
        }
    }

    /// A photo from the library as it is when the intake takes it (HEIC, JPEG or PNG under 10 MB);
    /// anything else (a RAW, a huge panorama) as a JPEG.
    static func photo(_ data: Data, name: String) -> AircraftRequestFile? {
        if data.count <= AircraftRequestIntake.maxFileBytes, let file = AircraftRequestFile(name: name, data: data) {
            return file
        }
        guard let image = UIImage(data: data),
              let jpeg = downscaled(image, maxSide: 3000).jpegData(compressionQuality: 0.8) else { return nil }
        return AircraftRequestFile(name: name + ".jpg", data: jpeg)
    }

    static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image }
        let scale = maxSide / side
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Apple's document scanner: the pages, in the order they were taken.
private struct DocumentScanner: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onCancel: onCancel) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(onScan: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onScan = onScan
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onScan((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }
    }
}

// MARK: - The Turnstile check

/// The website's Turnstile check, for the app (aerocheck.app/send/app/): the page runs Cloudflare's
/// widget, invisible unless it wants a tap, and hands the token over through a message handler. Only the
/// website and Cloudflare's challenge may load in it.
@MainActor
final class TurnstileCheck: NSObject, ObservableObject {
    enum State: Equatable {
        case loading
        /// The widget is up and working on its own.
        case waiting
        /// It wants a tap: the web view is shown.
        case interactive
        case passed(String)
        case failed
    }

    @Published private(set) var state: State = .loading
    private(set) var hasStarted = false
    let webView: WKWebView
    private let url: URL
    private var timeout: Task<Void, Never>?

    init(locale: String) {
        url = AircraftRequestIntake.checkPageURL(locale: locale)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 70), configuration: configuration)
        super.init()
        configuration.userContentController.add(MessageRelay(self), name: "aerocheckTurnstile")
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
    }

    /// The token, while it is good.
    var token: String? {
        if case .passed(let token) = state { return token }
        return nil
    }

    func start() {
        hasStarted = true
        state = .loading
        webView.load(URLRequest(url: url))
        watch()
    }

    /// A fresh token: the one taken is good for one try.
    func reset() {
        state = .waiting
        webView.evaluateJavaScript("window.acReset && window.acReset()")
        watch()
    }

    /// Twenty seconds without a token or a tap is a check that won't come.
    private func watch() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.state == .loading || self.state == .waiting { self.state = .failed }
        }
    }

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            if state == .loading { state = .waiting }
        case "interactive":
            timeout?.cancel()
            state = .interactive
        case "token":
            timeout?.cancel()
            if let token = message["token"] as? String, !token.isEmpty { state = .passed(token) }
        case "expired":
            // Cloudflare renews it by itself.
            state = .waiting
            watch()
        case "error", "unsupported":
            timeout?.cancel()
            state = .failed
        default:
            break
        }
    }
}

extension TurnstileCheck: WKNavigationDelegate {
    /// The website and Cloudflare's challenge (and the frames it opens, about:blank and about:srcdoc),
    /// nothing else: a link the page might hold never opens in here.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let target = navigationAction.request.url else { return .cancel }
        let allowed = target.scheme == "about" || target.host.map(AircraftRequestIntake.checkPageHosts.contains) == true
        return allowed ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        state = .failed
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        state = .failed
    }
}

/// The page's messages, without the user content controller keeping the check alive.
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    weak var check: TurnstileCheck?
    init(_ check: TurnstileCheck) { self.check = check }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { check?.received(body) }
    }
}

/// The check's web view, in the sheet.
private struct TurnstileWebView: UIViewRepresentable {
    @ObservedObject var check: TurnstileCheck
    func makeUIView(context: Context) -> WKWebView { check.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
