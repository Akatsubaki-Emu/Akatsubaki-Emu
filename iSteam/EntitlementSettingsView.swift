import SwiftUI
import StosSign_API
import StosSign_Auth
import StosSign_Common

@MainActor
final class EntitlementViewModel: ObservableObject {
    @Published var appleID = ""
    @Published var password = ""
    @Published var verificationCode = ""
    @Published var anisetteServerURL: String
    @Published private(set) var needsVerificationCode = false
    @Published private(set) var isBusy = false
    @Published private(set) var accountEmail: String?
    @Published private(set) var availableTeams: [Team] = []
    @Published private(set) var selectedTeam: Team?
    @Published var status = "Sign in with the Apple account used to install this build."

    private var session: AppleAPISession?
    private var verificationCodeHandler: ((String?) -> Void)?

    init() {
        anisetteServerURL = UserDefaults.standard.string(forKey: "iSteam.anisetteServerURL") ?? "https://ani.sidestore.io"
    }

    var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "Unknown bundle identifier"
    }

    func signIn() async {
        guard !isBusy else { return }
        let configuredURL = anisetteServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let anisetteURL = URL(string: configuredURL),
              anisetteURL.scheme?.lowercased() == "https", anisetteURL.host != nil else {
            status = "Enter a valid HTTPS Anisette server URL."
            return
        }

        isBusy = true
        status = "Connecting to Apple Developer Services…"
        defer {
            password = ""
            isBusy = false
        }

        do {
            AnisetteDataHelper.shared.url = anisetteURL
            UserDefaults.standard.set(configuredURL, forKey: "iSteam.anisetteServerURL")
            let anisetteData = try await AnisetteDataHelper.shared.getAnisetteData()
            let (account, authenticatedSession) = try await AppleAPI.shared.authenticate(
                appleID: appleID,
                password: password,
                anisetteData: anisetteData
            ) { [weak self] completionHandler in
                guard let self else {
                    completionHandler(nil)
                    return
                }
                await self.prepareForVerification(using: completionHandler)
            }

            session = authenticatedSession
            let teams = try await AppleAPI.shared.fetchTeamsForAccount(account: account, session: authenticatedSession)
            accountEmail = account.appleID
            availableTeams = teams
            if teams.count == 1, let team = teams.first {
                selectTeam(team)
            }
            status = "Signed in. Select the team that owns this App ID."
        } catch is CancellationError {
            status = "Sign-in cancelled."
        } catch {
            status = error.localizedDescription
        }
    }

    func submitVerificationCode() {
        guard let handler = verificationCodeHandler else { return }
        verificationCodeHandler = nil
        needsVerificationCode = false
        let code = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        verificationCode = ""
        handler(code.isEmpty ? nil : code)
    }

    func selectTeam(_ team: Team) {
        selectedTeam = team
    }

    func enableIncreasedMemoryLimit() async {
        guard !isBusy else { return }
        guard let team = selectedTeam, let session else {
            status = "Sign in and select your Apple Developer team first."
            return
        }

        isBusy = true
        status = "Checking the App ID registered with Apple…"
        defer { isBusy = false }

        do {
            let appIDs = try await AppleAPI.shared.fetchAppIDsForTeam(team: team, session: session)
            guard let appID = appIDs.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                status = "No App ID for \(bundleIdentifier) was found in this team. Install this build with the same Apple account first, then refresh and try again."
                return
            }

            _ = try await AppleAPI.shared.updateAppID(
                appID,
                capabilities: ["INCREASED_MEMORY_LIMIT"],
                team: team,
                session: session
            )
            status = "Apple accepted the Increased Memory Limit capability update for \(bundleIdentifier). Reinstall this app through SideStore or AltStore using the same account so the provisioning profile is regenerated. The running installation cannot update its own code signature."
        } catch {
            status = error.localizedDescription
        }
    }

    func signOut() {
        session = nil
        accountEmail = nil
        appleID = ""
        availableTeams = []
        selectedTeam = nil
        verificationCodeHandler = nil
        needsVerificationCode = false
        password = ""
        verificationCode = ""
        status = "Signed out."
    }

    private func prepareForVerification(using handler: @escaping (String?) -> Void) {
        verificationCodeHandler = handler
        verificationCode = ""
        needsVerificationCode = true
        status = "Enter the verification code sent to your trusted Apple device."
    }
}

struct EntitlementSettingsView: View {
    @StateObject private var model = EntitlementViewModel()

    var body: some View {
        Form {
            Section("This installation") {
                LabeledContent("Bundle ID", value: model.bundleIdentifier)
                Text("The request is restricted to this exact bundle identifier. Akatsubaki Emu will not modify other App IDs in your account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Anisette server") {
                TextField("HTTPS server URL", text: $model.anisetteServerURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Defaults to https://ani.sidestore.io. You can use another compatible Anisette server if required by your signing setup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Apple Developer account") {
                if let email = model.accountEmail {
                    LabeledContent("Account", value: email)
                    if !model.availableTeams.isEmpty {
                        ForEach(model.availableTeams, id: \.identifier) { team in
                            Button {
                                model.selectTeam(team)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(team.name)
                                        Text(team.identifier)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.selectedTeam?.identifier == team.identifier {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .disabled(model.isBusy)
                        }
                    }
                    Button("Sign Out", role: .destructive) {
                        model.signOut()
                    }
                    .disabled(model.isBusy)
                } else {
                    TextField("Apple Account email", text: $model.appleID)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.isBusy)
                    SecureField("Apple Account password", text: $model.password)
                        .textContentType(.password)
                        .disabled(model.isBusy)
                    Button("Sign In") {
                        Task { await model.signIn() }
                    }
                    .disabled(model.isBusy || model.appleID.isEmpty || model.password.isEmpty)
                }

                if model.needsVerificationCode {
                    TextField("Two-factor verification code", text: $model.verificationCode)
                        .keyboardType(.numberPad)
                    Button("Submit Verification Code") {
                        model.submitVerificationCode()
                    }
                    .disabled(model.verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Entitlement") {
                Button {
                    Task { await model.enableIncreasedMemoryLimit() }
                } label: {
                    if model.isBusy {
                        HStack {
                            ProgressView()
                            Text("Working…")
                        }
                    } else {
                        Text("Enable Increased Memory Limit for Akatsubaki Emu")
                    }
                }
                .disabled(model.isBusy || model.selectedTeam == nil)
                Text("This uses the GetMoreRam/StosSign Apple Developer Services flow. Apple account access and an existing App ID are required.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Status and next step") {
                Text(model.status)
                    .textSelection(.enabled)
                Text("After Apple accepts the change, reinstall this app with SideStore or AltStore. Apple invalidates profiles when App ID capabilities change; the app cannot grant entitlements to its already-running signature.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Entitlements")
    }
}
