import Foundation

struct AkatsubakiJITRequest: Codable, Sendable {
    let targetPID: Int32
    let pairingData: Data
}

struct AkatsubakiJITResponse: Codable, Sendable {
    let success: Bool
    let message: String
}
