import Foundation
enum AkatsubakiJITHelperState: String, Codable, Sendable { case idle, preparing, attaching, attached, completed, failed }
enum AkatsubakiJITHelperOperation: String, Codable, Sendable { case prepare, enableJIT, status, resetDDI }
struct AkatsubakiJITHelperRequest: Codable, Sendable {
 let operation: AkatsubakiJITHelperOperation
 let targetPID: Int32?
 let pairingData: Data?
 let forceScript: Bool
 static func prepare(_ data: Data) -> Self { Self(operation: .prepare, targetPID: nil, pairingData: data, forceScript: false) }
 static func enableJIT(targetPID: Int32, pairingData: Data, forceScript: Bool) -> Self { Self(operation: .enableJIT, targetPID: targetPID, pairingData: pairingData, forceScript: forceScript) }
 static var status: Self { Self(operation: .status, targetPID: nil, pairingData: nil, forceScript: false) }
 static var resetDDI: Self { Self(operation: .resetDDI, targetPID: nil, pairingData: nil, forceScript: false) }
}
struct AkatsubakiJITHelperResponse: Codable, Sendable {
 let accepted: Bool
 let state: AkatsubakiJITHelperState
 let message: String
 let txmPresent: Bool?
 let progress: Double?
}
