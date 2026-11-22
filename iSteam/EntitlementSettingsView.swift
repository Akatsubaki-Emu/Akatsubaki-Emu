import SwiftUI
import Foundation
import StosSign_API
import StosSign_Auth
import StosSign_Common

@MainActor
final class EntitlementViewModel: ObservableObject {
    static let shared = EntitlementViewModel()
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

    private init() {
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
        _ = await addCapability("INCREASED_MEMORY_LIMIT")
    }

    @discardableResult
    func addCapability(_ rawCapability: String) async -> Bool {
        guard !isBusy else { return false }
        let capability = rawCapability.trimmingCharacters(in: .whitespacesAndNewlines)
        guard capability.utf8.count <= 128,
              capability.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            status = "Enter a capability identifier using letters, numbers, dots, underscores or hyphens (maximum 128 characters)."
            return false
        }
        guard let team = selectedTeam, let session else {
            status = "Sign in and select your Apple Developer team first."
            return false
        }

        isBusy = true
        status = "Checking the App ID registered with Apple…"
        defer { isBusy = false }

        do {
            let appIDs = try await AppleAPI.shared.fetchAppIDsForTeam(team: team, session: session)
            guard let appID = appIDs.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                status = "No App ID for \(bundleIdentifier) was found in this team. Install this build with the same Apple account first, then refresh and try again."
                return false
            }

            let existingCapabilities = try await fetchExistingCapabilities(for: appID, session: session)
            if existingCapabilities.contains(where: { $0.type == capability }) {
                status = "Apple already reports \(capability) enabled for \(bundleIdentifier). Reinstall this app through SideStore or AltStore if this installation has not yet received a refreshed provisioning profile."
                return true
            }

            var capabilitiesToEnable = existingCapabilities
            capabilitiesToEnable.append((type: capability, settings: []))
            let capabilityPayload: [[String: Any]] = capabilitiesToEnable.map { item in
                [
                    "type": "bundleIdCapabilities",
                    "attributes": [
                        "enabled": true,
                        "settings": item.settings
                    ],
                    "relationships": [
                        "capability": [
                            "data": [
                                "type": "capabilities",
                                "id": item.type
                            ]
                        ]
                    ]
                ]
            }

            let payload: [String: Any] = [
                "data": [
                    "type": "bundleIds",
                    "id": appID.identifier,
                    "attributes": [
                        "identifier": appID.bundleIdentifier,
                        "teamId": team.identifier,
                        "seedId": team.identifier,
                        "bundleType": "bundle",
                        "name": appID.name,
                        "hasExclusiveManagedCapabilities": false
                    ],
                    "relationships": [
                        "bundleIdCapabilities": ["data": capabilityPayload]
                    ]
                ]
            ]

            let response = try await AppleAPI.shared.sendEditRequest(
                requestURL: AppleAPI.shared.v1URL
                    .appendingPathComponent("bundleIds")
                    .appendingPathComponent(appID.identifier),
                body: payload,
                session: session,
                json: true,
                appendClientId: false
            )
            guard response["data"] as? [String: Any] != nil else {
                let message = response["error"] as? String ?? "Apple did not confirm the capability update."
                throw NSError(
                    domain: "AkatsubakiEntitlements",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
            status = "Apple accepted the \(capability) capability update for \(bundleIdentifier). Existing App ID capabilities and their settings were preserved. Reinstall this app through SideStore or AltStore using the same account so the provisioning profile is regenerated. The running installation cannot update its own code signature."
            return true
        } catch {
            status = error.localizedDescription
            return false
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

    private func fetchExistingCapabilities(
        for appID: AppID,
        session: AppleAPISession
    ) async throws -> [(type: String, settings: [[String: Any]])] {
        let url = AppleAPI.shared.v1URL
            .appendingPathComponent("bundleIds")
            .appendingPathComponent(appID.identifier)
            .appendingPathComponent("bundleIdCapabilities")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let anisette = session.anisetteData
        let dateFormatter = ISO8601DateFormatter()
        let headers: [String: String] = [
            "Content-Type": "application/vnd.api+json",
            "User-Agent": "Xcode",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-us",
            "X-Apple-App-Info": "com.apple.gs.xcode.auth",
            "X-Xcode-Version": "27.0 (27A5218g)",
            "X-Apple-I-Identity-Id": session.dsid,
            "X-Apple-GS-Token": session.authToken,
            "X-Apple-I-MD-M": anisette.machineID,
            "X-Apple-I-MD": anisette.oneTimePassword,
            "X-Apple-I-MD-LU": anisette.localUserID,
            "X-Apple-I-MD-RINFO": "\(anisette.routingInfo)",
            "X-Mme-Device-Id": anisette.deviceUniqueIdentifier,
            "X-MMe-Client-Info": anisette.deviceDescription,
            "X-Apple-I-Client-Time": dateFormatter.string(from: anisette.date),
            "X-Apple-Locale": anisette.locale.identifier,
            "X-Apple-I-Locale": anisette.locale.identifier,
            "X-Apple-I-TimeZone": anisette.timeZone.abbreviation() ?? "GMT"
        ]
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let (data, response) = try await AppleAPI.shared.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "AkatsubakiEntitlements",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Apple could not return the existing App ID capabilities (HTTP \(statusCode)). No capability changes were made."]
            )
        }

        guard let responseDictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = responseDictionary["data"] as? [[String: Any]] else {
            throw NSError(
                domain: "AkatsubakiEntitlements",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Apple returned an unreadable capability list. No capability changes were made."]
            )
        }

        let capabilities = records.compactMap { record -> (type: String, settings: [[String: Any]])? in
            let attributes = record["attributes"] as? [String: Any] ?? [:]
            let relationships = record["relationships"] as? [String: Any] ?? [:]
            let capability = relationships["capability"] as? [String: Any] ?? [:]
            let capabilityData = capability["data"] as? [String: Any] ?? [:]
            let recordID = record["id"] as? String
            let recordSuffix = recordID.flatMap { id -> String? in
                let prefix = appID.identifier + "_"
                return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil
            }
            guard let type = (attributes["capabilityType"] as? String)
                    ?? (capabilityData["id"] as? String)
                    ?? recordSuffix else {
                return nil
            }
            let settings = attributes["settings"] as? [[String: Any]] ?? []
            return (type: type, settings: settings)
        }

        guard capabilities.count == records.count else {
            throw NSError(
                domain: "AkatsubakiEntitlements",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Apple returned capability records that Akatsubaki Emu could not safely preserve. No capability changes were made."]
            )
        }
        return capabilities
    }

    private func prepareForVerification(using handler: @escaping (String?) -> Void) async {
        verificationCodeHandler = handler
        verificationCode = ""
        needsVerificationCode = true
        status = "Enter the verification code sent to your trusted Apple device."
    }
}

struct EntitlementSettingsView: View {
    @StateObject private var model = EntitlementViewModel.shared

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
