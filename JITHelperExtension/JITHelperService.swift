import Foundation
import StikJIT
private final class AkatsubakiJITHelperService: @unchecked Sendable {
 static let shared = AkatsubakiJITHelperService()
 private typealias State = AkatsubakiJITHelperState
 private typealias Response = AkatsubakiJITHelperResponse
 private let lock = NSLock()
 private let queue = DispatchQueue(label: "com.xthrx.isteam.stikjit-helper")
 private var isRunning = false
 private var state: State = .idle
 private var message = "Ready"
 private var txmPresent: Bool? = StikJIT.isTXMPresent
 private var progress: Double?
 private init() {}
 func handle(_ request: AkatsubakiJITHelperRequest) -> Response {
  switch request.operation {
  case .status: return snapshot(accepted: true)
  case .prepare:
   guard let data = request.pairingData else { return rejected("A device pairing file is required.") }
   return startOperation("Preparing the Developer Disk Image...") { self.prepare(data) }
  case .enableJIT:
   guard let data = request.pairingData, let pid = request.targetPID, pid > 0 else { return rejected("A valid pairing file and target PID are required.") }
   return startOperation("Starting StikJIT...") { self.enableJIT(pid: pid, data: data, forceScript: request.forceScript) }
  case .resetDDI:
   return startOperation("Resetting the Developer Disk Image cache...") { self.resetDDI() }
  }
 }
 private func startOperation(_ initial: String, work: @escaping () -> Void) -> Response {
  lock.lock()
  guard !isRunning else { let response = snapshotLocked(accepted: false); lock.unlock(); return response }
  isRunning = true; state = .preparing; message = initial; progress = nil; txmPresent = StikJIT.isTXMPresent
  let response = snapshotLocked(accepted: true); lock.unlock()
  queue.async { work(); self.lock.lock(); self.isRunning = false; self.lock.unlock() }
  return response
 }
 private func prepare(_ data: Data) {
  do {
   let (pairingURL, paths) = try makePaths(data)
   defer { try? FileManager.default.removeItem(at: pairingURL) }
   let result = StikJIT.prepareDevice(pairingFile: pairingURL, paths: paths) { stage in self.updatePreparation(stage) }
   switch result {
   case .ready(let security): update(state: .completed, message: "Developer Disk Image is ready.", txmPresent: security.isTXMPresent, progress: 1)
   case .unreachable(let reason): update(state: .failed, message: reason, txmPresent: StikJIT.isTXMPresent)
   case .preparationFailed(let reason): update(state: .failed, message: reason, txmPresent: StikJIT.isTXMPresent)
   }
  } catch { update(state: .failed, message: error.localizedDescription, txmPresent: StikJIT.isTXMPresent) }
 }
 private func enableJIT(pid: Int32, data: Data, forceScript: Bool) {
  do {
   let (pairingURL, paths) = try makePaths(data)
   defer { try? FileManager.default.removeItem(at: pairingURL) }
   try StikJIT.enableJIT(targetPID: pid, pairingFile: pairingURL, ddiPaths: paths, script: .universal, forceScript: forceScript,
    preparationProgress: { stage in self.updatePreparation(stage) },
    progress: { text in self.updateScriptProgress(text) })
   update(state: .completed, message: "StikJIT completed the JIT handoff.", txmPresent: StikJIT.isTXMPresent, progress: 1)
  } catch { update(state: .failed, message: error.localizedDescription, txmPresent: StikJIT.isTXMPresent) }
 }
 private func resetDDI() {
  do {
   let root = try storageRoot()
   try StikJIT.resetCachedDDI(at: DDIPaths.default(in: root))
   update(state: .completed, message: "Developer Disk Image cache cleared.", txmPresent: StikJIT.isTXMPresent, progress: 1)
  } catch { update(state: .failed, message: error.localizedDescription, txmPresent: StikJIT.isTXMPresent) }
 }
 private func makePaths(_ data: Data) throws -> (URL, DDIPaths) {
  let root = try storageRoot(), file = root.appendingPathComponent("pairingFile.plist")
  try data.write(to: file, options: [.atomic, .completeFileProtection])
  try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
  return (file, DDIPaths.default(in: root))
 }
 private func storageRoot() throws -> URL {
  let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
  let root = library.appendingPathComponent("StikJIT", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
  try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
  var values = URLResourceValues()
  values.isExcludedFromBackup = true
  var protectedRoot = root
  try? protectedRoot.setResourceValues(values)
  return root
 }
 private func updatePreparation(_ stage: StikJIT.PreparationStage) {
  switch stage {
  case .checkingReachability: update(state: .preparing, message: "Checking LocalDevVPN and Remote Pairing...")
  case .checkingDDI: update(state: .preparing, message: "Checking the Developer Disk Image...")
  case .downloadingDDI(let fraction, let status): update(state: .preparing, message: status, progress: fraction)
  case .mountingDDI(let fraction): update(state: .preparing, message: "Mounting the Developer Disk Image...", progress: fraction)
  case .verifyingDDI: update(state: .preparing, message: "Verifying the Developer Disk Image...", progress: 1)
  case .ready: update(state: .attaching, message: "Developer Disk Image ready.", progress: 1)
  @unknown default: update(state: .preparing, message: "Preparing the Developer Disk Image...")
  }
 }
 private func updateScriptProgress(_ text: String) {
  let next: State = text.localizedCaseInsensitiveContains("attach_response") ? .attached : .attaching
  update(state: next, message: text, txmPresent: StikJIT.isTXMPresent)
 }
 private func update(state: State, message: String, txmPresent: Bool? = nil, progress: Double? = nil) {
  lock.lock(); self.state = state; self.message = message
  self.txmPresent = txmPresent ?? StikJIT.isTXMPresent; self.progress = progress; lock.unlock()
 }
 private func snapshot(accepted: Bool) -> Response { lock.lock(); defer { lock.unlock() }; return snapshotLocked(accepted: accepted) }
 private func snapshotLocked(accepted: Bool) -> Response { Response(accepted: accepted, state: state, message: message, txmPresent: txmPresent, progress: progress) }
 private func rejected(_ message: String) -> Response { Response(accepted: false, state: .failed, message: message, txmPresent: StikJIT.isTXMPresent, progress: nil) }
}
