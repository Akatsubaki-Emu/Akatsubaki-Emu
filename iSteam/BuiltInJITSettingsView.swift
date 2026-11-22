import SwiftUI
import UniformTypeIdentifiers
import UIKit
@available(iOS 26.0, *)
struct BuiltInJITSettingsView: View {
 @State private var pairingFileName = StikJITPairingFileStore.exists ? "pairingFile.plist" : "Not imported"
 @State private var forceScript = UserDefaults.standard.bool(forKey: "iSteam.jitForceScript")
 @State private var txmStatus = "Unknown"
 @State private var statusMessage = "Import a device pairing file to begin."
 @State private var progress: Double?
 @State private var isImporting = false
 @State private var isBusy = false
 var body: some View {
  Form {
   Section("Bundled helper") {
    Text("Akatsubaki runs StikJIT in an embedded background extension. The separate StikDebug app is not required for this method.")
    Text("LocalDevVPN remains a separate app. Akatsubaki opens it automatically when a VM requests JIT.")
   }
   Section("Device pairing") {
    LabeledContent("Pairing file", value: pairingFileName)
    Button("Import pairing file") { isImporting = true }.disabled(isBusy)
   }
   Section("TXM protocol") {
    LabeledContent("Hardware detection", value: txmStatus)
    Toggle("Force JIT Script when TXM is unknown", isOn: $forceScript)
     .onChange(of: forceScript) { _, value in UserDefaults.standard.set(value, forKey: "iSteam.jitForceScript") }
    Text("This override is used only when StikJIT cannot determine TXM presence. It selects the TXM breakpoint allocator.")
     .font(.footnote).foregroundStyle(.secondary)
   }
   Section("Developer Disk Image") {
    Button("Prepare JIT") { Task { await prepare() } }.disabled(isBusy || !StikJITPairingFileStore.exists)
    Button("Reset cached Developer Disk Image", role: .destructive) { Task { await resetDDI() } }.disabled(isBusy)
    if let progress { ProgressView(value: progress) }
    Text(statusMessage).font(.footnote)
   }
   Section("Network") {
    Button("Open LocalDevVPN") { if let url = URL(string: "localdevvpn://") { UIApplication.shared.open(url) } }
    Text("Connect LocalDevVPN before manual preparation. VM launch activates the VPN flow automatically.")
     .font(.footnote).foregroundStyle(.secondary)
   }
  }
  .navigationTitle("Built-in JIT")
  .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
   switch result {
   case .success(let urls):
    guard let url = urls.first else { return }
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    do {
     try StikJITPairingFileStore.store(Data(contentsOf: url))
     pairingFileName = url.lastPathComponent
     statusMessage = "Pairing file imported."
    } catch { statusMessage = error.localizedDescription }
   case .failure(let error): statusMessage = error.localizedDescription
   }
  }
 }
 @MainActor private func prepare() async {
  do {
   let data = try StikJITPairingFileStore.load()
   isBusy = true; progress = nil
   let response = try await BuiltInJITHelperClient.shared.perform(AkatsubakiJITHelperRequest.prepare(data)) { update in
    statusMessage = update.message
    txmStatus = update.txmPresent.map { $0 ? "Present" : "Absent" } ?? "Unknown"
    progress = update.progress
   }
   isBusy = false; statusMessage = response.message
   txmStatus = response.txmPresent.map { $0 ? "Present" : "Absent" } ?? "Unknown"
   progress = response.progress
  } catch { isBusy = false; statusMessage = error.localizedDescription }
 }
 @MainActor private func resetDDI() async {
  isBusy = true; defer { isBusy = false }
  do {
   let response = try await BuiltInJITHelperClient.shared.perform(.resetDDI)
   statusMessage = response.message; progress = response.progress
  } catch { statusMessage = error.localizedDescription }
 }
}
