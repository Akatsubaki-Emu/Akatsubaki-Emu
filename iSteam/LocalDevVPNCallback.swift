import Foundation

/// Interprets the callback sent by LocalDevVPN after attempting to establish the tunnel.
/// A missing status remains successful for compatibility with older LocalDevVPN clients.
/// Ambiguous status values and callbacks for another host are rejected.
enum LocalDevVPNCallback {
    static func didConnect(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.caseInsensitiveCompare("localdevvpn") == .orderedSame else {
            return false
        }

        let statuses = components.queryItems?.filter { $0.name == "status" } ?? []
        guard statuses.count <= 1 else { return false }
        guard let status = statuses.first?.value else {
            return true
        }
        return status.caseInsensitiveCompare("connected") == .orderedSame
    }
}
