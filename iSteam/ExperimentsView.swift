import SwiftUI

@MainActor
struct ExperimentsView: View {
    @ObservedObject private var model = EntitlementViewModel.shared
    @State private var capabilityIdentifier = ""

    private var requestedCapability: String {
        capabilityIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section("Add Anything") {
                TextField("Anything", text: $capabilityIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add") {
                    let requested = requestedCapability
                    Task {
                        if await model.addCapability(requested) {
                            capabilityIdentifier = ""
                        }
                    }
                }
                .disabled(model.isBusy || model.selectedTeam == nil || requestedCapability.isEmpty)
                Text("Enter an Apple Developer capability identifier. Apple decides whether it is supported and eligible for this App ID.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Apple Developer account") {
                if let email = model.accountEmail {
                    LabeledContent("Account", value: email)
                } else {
                    Text("Sign in and select a team in Settings → Entitlements before adding a capability.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let team = model.selectedTeam {
                    LabeledContent("Team", value: team.name)
                    LabeledContent("Team ID", value: team.identifier)
                }
            }

            Section("Status") {
                Text(model.status)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Experiments")
    }
}
