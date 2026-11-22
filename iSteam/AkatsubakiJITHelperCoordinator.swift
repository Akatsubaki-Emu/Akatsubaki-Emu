#if os(iOS)
import ExtensionFoundation
import Foundation
import XPC

@available(iOS 26.0, *)
@MainActor
@objc(AkatsubakiJITHelperCoordinator)
final class AkatsubakiJITHelperCoordinator: NSObject {
    private final class ActiveSession {
        let process: AppExtensionProcess
        let session: XPCSession

        init(process: AppExtensionProcess, session: XPCSession) {
            self.process = process
            self.session = session
        }

        deinit {
            session.cancel(reason: "Akatsubaki built-in JIT request finished")
            process.invalidate()
        }
    }

    private static var activeSession: ActiveSession?

    static func enableJIT(targetPID: Int32, pairingData: Data,
                          completion: @escaping (Bool, String) -> Void) {
        Task { @MainActor in
            do {
                let monitor = try await AppExtensionPoint.Monitor(
                    appExtensionPoint: .akatsubakiJITHelper
                )
                guard let identity = monitor.identities.first else {
                    throw NSError(domain: "AkatsubakiJIT", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The embedded JIT helper is missing from this installation."])
                }

                let process = try await AppExtensionProcess(configuration: .init(
                    appExtensionIdentity: identity,
                    onInterruption: {
                        Task { @MainActor in Self.activeSession = nil }
                    }
                ))
                let session = try process.makeXPCSession()
                try session.activate()
                Self.activeSession = ActiveSession(process: process, session: session)

                let request = AkatsubakiJITRequest(targetPID: targetPID, pairingData: pairingData)
                try session.send(request) { (result: Result<AkatsubakiJITResponse, any Error>) in
                    Task { @MainActor in
                        Self.activeSession = nil
                        switch result {
                        case .success(let response):
                            completion(response.success, response.message)
                        case .failure(let error):
                            completion(false, error.localizedDescription)
                        }
                    }
                }
            } catch {
                Self.activeSession = nil
                completion(false, error.localizedDescription)
            }
        }
    }

    static func cancel() {
        activeSession = nil
    }
}
#endif
