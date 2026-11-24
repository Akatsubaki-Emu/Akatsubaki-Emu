import Foundation

/// Interprets the callback sent by LocalDevVPN after attempting to establish the tunnel.
/// A missing status remains successful for compatibility with older LocalDevVPN clients.
enum LocalDevVPNCallback {
    static func didConnect(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        guard let status = components.queryItems?.first(where: { $0.name == "status" })?.value else {
            return true
        }
        return status.caseInsensitiveCompare("connected") == .orderedSame
    }
}
