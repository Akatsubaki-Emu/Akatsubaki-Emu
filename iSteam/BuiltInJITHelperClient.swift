import ExtensionFoundation
import Foundation
import XPC
@available(iOS 26.0, *)
@MainActor
final class BuiltInJITHelperClient {
 static let shared = BuiltInJITHelperClient()
 private var process: AppExtensionProcess?
 private var session: XPCSession?
 private var interrupted = false
 private var generation = 0
 private init() {}
 func send(_ request: AkatsubakiJITHelperRequest) async throws -> AkatsubakiJITHelperResponse {
  guard !interrupted else { throw helperError("The bundled StikJIT helper process was interrupted.") }
  try await connectIfNeeded()
  guard let session else { throw helperError("The helper did not create an XPC session.") }
  return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AkatsubakiJITHelperResponse, Error>) in
   do {
    try session.send(request) { (result: Result<AkatsubakiJITHelperResponse, any Error>) in
     switch result {
     case .success(let response): continuation.resume(returning: response)
     case .failure(let error): continuation.resume(throwing: error)
     }
    }
   } catch { continuation.resume(throwing: error) }
  }
 }
 func perform(_ request: AkatsubakiJITHelperRequest, timeoutSeconds: Int = 1200, onProgress: ((AkatsubakiJITHelperResponse) -> Void)? = nil) async throws -> AkatsubakiJITHelperResponse {
  let accepted = try await send(request)
  guard accepted.accepted else { throw helperError(accepted.message) }
  onProgress?(accepted)
  for _ in 0..<(max(1, timeoutSeconds) * 2) {
   let response = try await send(.status)
   onProgress?(response)
   if response.state == .completed || response.state == .failed { return response }
   try await Task.sleep(nanoseconds: 500_000_000)
  }
  throw helperError("Timed out waiting for StikJIT.")
 }
 func invalidate() {
  generation += 1
  let oldSession = session, oldProcess = process
  session = nil; process = nil; interrupted = false
  oldSession?.cancel(reason: "Akatsubaki VM stopped")
  oldProcess?.invalidate()
 }
 private func connectIfNeeded() async throws {
  guard session == nil else { return }
  generation += 1
  let currentGeneration = generation
  let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .akatsubakiJITHelper)
  guard let identity = monitor.identities.first else { throw helperError("Embedded StikJIT extension is missing.") }
  let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity, onInterruption: { [weak self] in
   Task { @MainActor in
    guard let self, self.generation == currentGeneration else { return }
    self.interrupted = true
   }
  }))
  let session = try process.makeXPCSession()
  try session.activate()
  self.process = process; self.session = session
 }
 private func helperError(_ message: String) -> NSError {
  NSError(domain: "AkatsubakiJITHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
 }
}
