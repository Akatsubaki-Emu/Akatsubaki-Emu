import ExtensionFoundation
import XPC
private struct AkatsubakiJITHelperPeer: XPCPeerHandler {
 func handleIncomingRequest(_ message: AkatsubakiJITHelperRequest) -> (any Encodable)? {
  AkatsubakiJITHelperService.shared.handle(message)
 }
}
@main
struct AkatsubakiJITHelperExtension: AppExtension {
 @AppExtensionPoint.Bind
 var boundAppExtensionPoint: AppExtensionPoint {
  let host = Bundle.main.object(forInfoDictionaryKey: "AkatsubakiHostBundleIdentifier") as? String ?? ""
  return AppExtensionPoint.Identifier(host: host, name: "AkatsubakiJITHelper")
 }
 var configuration: some AppExtensionConfiguration {
  ConnectionHandler(onSessionRequest: { request in request.accept { _ in AkatsubakiJITHelperPeer() } })
 }
}
