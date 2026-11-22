import ExtensionFoundation
import Foundation
import StikJIT
import XPC

private struct AkatsubakiJITMessageHandler: XPCPeerHandler {
    private static let workQueue = DispatchQueue(label: "com.xthrx.isteam.stikjit.helper")

    func handleIncomingRequest(_ message: AkatsubakiJITRequest) -> (any Encodable)? {
        Self.workQueue.sync {
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            let root = library.appendingPathComponent("AkatsubakiJIT", isDirectory: true)
            let pairingFile = root.appendingPathComponent("pairingFile.plist")
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try message.pairingData.write(to: pairingFile, options: [.atomic, .completeFileProtection])
                defer { try? FileManager.default.removeItem(at: pairingFile) }

                let paths = DDIPaths.default(in: root.appendingPathComponent("DDI", isDirectory: true))
                try StikJIT.enableJIT(
                    targetPID: message.targetPID,
                    pairingFile: pairingFile,
                    ddiPaths: paths,
                    script: .universal,
                    preparationProgress: { stage in
                        NSLog("[AkatsubakiJIT] %@", String(describing: stage))
                    },
                    progress: { message in
                        NSLog("[AkatsubakiJIT] %@", message)
                    }
                )
                return AkatsubakiJITResponse(success: true, message: "Built-in StikJIT completed the target's JIT breakpoint handshake.")
            } catch {
                return AkatsubakiJITResponse(success: false, message: error.localizedDescription)
            }
        }
    }
}

@main
struct AkatsubakiJITHelperExtension: AppExtension {
    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        #if NIGHTLY_BUILD
        AppExtensionPoint.Identifier(host: "com.xthrx.isteam.nightly", name: "AkatsubakiJITHelper")
        #else
        AppExtensionPoint.Identifier(host: "com.xthrx.isteam", name: "AkatsubakiJITHelper")
        #endif
    }

    var configuration: some AppExtensionConfiguration {
        ConnectionHandler(onSessionRequest: { request in
            request.accept { _ in AkatsubakiJITMessageHandler() }
        })
    }
}
