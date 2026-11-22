//
//  FetchAnisetteDataOperation.swift
//  AltStore
//
//  Created by Riley Testut on 1/7/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import CryptoKit
import Security
import StosSign_API
import StosSign_Auth
import StosSign_Common

final class AnisetteDataHelper
{
    var socket: URLSessionWebSocketTask?
    
    var url: URL?
    var startProvisioningURL: URL?
    var endProvisioningURL: URL?
    
    var clientInfo: String?
    var userAgent: String?
    
    var mdLu: String?
    var deviceId: String?
    
    var menuAnisetteURL: String?
    
    static var shared: AnisetteDataHelper = AnisetteDataHelper()
    
    
    func resetClientInfo() {
        clientInfo = nil
        userAgent = nil
        mdLu = nil
        deviceId = nil
    }
    
    func getAnisetteData(refresh: Bool = false) async throws -> AnisetteData {
        guard let anisetteURL = self.url,
              anisetteURL.scheme?.lowercased() == "https",
              anisetteURL.host != nil else {
            throw "A valid HTTPS Anisette server is required"
        }

        if refresh {
            try EntitlementAnisetteKeychain.shared.clearAdiPb()
        }

        if let identifier = try EntitlementAnisetteKeychain.shared.loadIdentifier(),
           let adiPb = try EntitlementAnisetteKeychain.shared.loadAdiPb() {
            return try await self.fetchAnisetteV3(identifier, adiPb)
        }
        return try await self.provision()
    }

    // MARK: - COMMON
    
    func extractAnisetteData(_ data: Data, _ response: HTTPURLResponse?, v3: Bool) async throws -> AnisetteData {
        // make sure this JSON is in the format we expect
        // convert data to json
        if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] {
            if v3 {
                if json["result"] == "GetHeadersError" {
                    let message = json["message"]
                    self.printOut("Error getting V3 headers: \(message ?? "no message")")
                    if let message = message,
                       message.contains("-45061") {
                        self.printOut("Error message contains -45061 (not provisioned), resetting adi.pb and retrying")
                        try EntitlementAnisetteKeychain.shared.clearAdiPb()
                        return try await provision()
                    } else { throw message ?? "Unknown error" }
                }
            }
            
            // try to read out a dictionary
            // for some reason serial number isn't needed but it doesn't work unless it has a value
            var formattedJSON: [String: String] = ["deviceSerialNumber": "0"]
            if let machineID = json["X-Apple-I-MD-M"] { formattedJSON["machineID"] = machineID }
            if let oneTimePassword = json["X-Apple-I-MD"] { formattedJSON["oneTimePassword"] = oneTimePassword }
            if let routingInfo = json["X-Apple-I-MD-RINFO"] { formattedJSON["routingInfo"] = routingInfo }
            
            if v3 {
                guard let clientInfo = self.clientInfo,
                      let localUserID = self.mdLu,
                      let deviceUniqueIdentifier = self.deviceId else {
                    throw "Anisette client information is not prepared"
                }
                formattedJSON["deviceDescription"] = clientInfo
                formattedJSON["localUserID"] = localUserID
                formattedJSON["deviceUniqueIdentifier"] = deviceUniqueIdentifier
                
                // Generate date stuff on client
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = TimeZone(identifier: "UTC")
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
                let dateString = formatter.string(from: Date())
                formattedJSON["date"] = dateString
                formattedJSON["locale"] = Locale.current.identifier
                formattedJSON["timeZone"] = TimeZone.current.abbreviation()
            } else {
                if let deviceDescription = json["X-MMe-Client-Info"] { formattedJSON["deviceDescription"] = deviceDescription }
                if let localUserID = json["X-Apple-I-MD-LU"] { formattedJSON["localUserID"] = localUserID }
                if let deviceUniqueIdentifier = json["X-Mme-Device-Id"] { formattedJSON["deviceUniqueIdentifier"] = deviceUniqueIdentifier }
                
                if let date = json["X-Apple-I-Client-Time"] { formattedJSON["date"] = date }
                if let locale = json["X-Apple-Locale"] { formattedJSON["locale"] = locale }
                if let timeZone = json["X-Apple-I-TimeZone"] { formattedJSON["timeZone"] = timeZone }
            }
            
            if let response = response,
               let version = response.value(forHTTPHeaderField: "Implementation-Version") {
                self.printOut("Implementation-Version: \(version)")
            } else { self.printOut("No Implementation-Version header") }
            
            self.printOut("Anisette headers prepared successfully")
            self.printOut("Anisette response parsed")
            do {
                let jsonData = try JSONEncoder().encode(formattedJSON)
                let anisette = try JSONDecoder().decode(AnisetteData.self, from: jsonData)
                
                self.printOut("Anisette is valid!")
                return anisette
            } catch {
                self.printOut("Anisette is invalid!!!!")
                if v3 {
                    throw "Invalid anisette (the returned data may not have all the required fields)"
                } else {
                    throw "Invalid anisette (the returned data may not have all the required fields)"
                }
            }
        } else {
            if v3 {
                throw "Invalid anisette (the returned data may not be in JSON)"
            } else {
                throw "Invalid anisette (the returned data may not be in JSON)"
            }
        }
    }
    
    
    // MARK: - V3: PROVISIONING
    
    func provision() async throws -> AnisetteData {
        try await fetchClientInfo()
        self.printOut("Getting provisioning URLs")
        guard let lookupURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup") else {
            throw "Apple provisioning lookup URL is invalid"
        }
        var request = try self.buildAppleRequest(url: lookupURL)
        request.httpMethod = "GET"
        let (data, _) = try await URLSession.shared.data(for: request)

        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
           let startProvisioningString = plist["urls"]?["midStartProvisioning"] as? String,
           let startProvisioningURL = URL(string: startProvisioningString),
           startProvisioningURL.scheme?.lowercased() == "https",
           startProvisioningURL.host != nil,
           let endProvisioningString = plist["urls"]?["midFinishProvisioning"] as? String,
           let endProvisioningURL = URL(string: endProvisioningString),
           endProvisioningURL.scheme?.lowercased() == "https",
           endProvisioningURL.host != nil {
            self.startProvisioningURL = startProvisioningURL
            self.endProvisioningURL = endProvisioningURL
            self.printOut("Provisioning endpoints received")
            return try await self.startProvisioningSession()
        }

        self.printOut("Apple did not return valid HTTPS provisioning URLs")
        throw "Apple didn't give valid HTTPS provisioning URLs. Please try again later"
    }

    func startProvisioningSession() async throws -> AnisetteData {
        guard let anisetteURL = self.url,
              anisetteURL.scheme?.lowercased() == "https",
              anisetteURL.host != nil else {
            throw "A valid HTTPS Anisette server is required"
        }
        let sessionURL = anisetteURL.appendingPathComponent("v3").appendingPathComponent("provisioning_session")
        let provisioningSessionURL = self.webSocketURL(from: sessionURL)
        var wsRequest = URLRequest(url: provisioningSessionURL)
        wsRequest.timeoutInterval = 5
        let socket = URLSession.shared.webSocketTask(with: wsRequest)
        self.socket = socket
        socket.resume()
        try await self.receiveProvisioningMessages(from: socket)
        guard let identifier = try EntitlementAnisetteKeychain.shared.loadIdentifier(),
              let adiPb = try EntitlementAnisetteKeychain.shared.loadAdiPb() else {
            throw "Anisette provisioning completed without storing its device state"
        }
        return try await self.fetchAnisetteV3(identifier, adiPb)
    }

    private func receiveProvisioningMessages(from socket: URLSessionWebSocketTask) async throws {
        self.printOut("Connected")
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            if self.socket === socket {
                self.socket = nil
            }
        }
        
        while true {
            let message = try await socket.receive()
            switch message {
            case .string(let string):
                if try await handleProvisioningMessage(string, socket: socket) {
                    return
                }
            case .data:
                throw "The server sent binary data instead of text"
            @unknown default:
                throw "The server sent an unknown WebSocket message"
            }
        }
    }
    
    private func handleProvisioningMessage(_ string: String, socket: URLSessionWebSocketTask) async throws -> Bool {
        guard let data = string.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw "The server didn't give valid JSON"
        }
        
        guard let result = json["result"] as? String else {
            self.printOut("The server didn't give us a result")
            throw "The server didn't give us a result"
        }
        
        self.printOut("Received result: \(result)")
        switch result {
        case "GiveIdentifier":
            self.printOut("Giving identifier")
            guard let identifier = try EntitlementAnisetteKeychain.shared.loadIdentifier() else {
                throw "The Anisette device identifier is missing"
            }
            try await socket.sendJSON(["identifier": identifier])
            
        case "GiveStartProvisioningData":
            self.printOut("Getting start provisioning data")
            let spim = try await self.fetchStartProvisioningData()
            self.printOut("Giving start provisioning data")
            try await socket.sendJSON(["spim": spim])
            
        case "GiveEndProvisioningData":
            self.printOut("Getting end provisioning data")
            guard let cpim = json["cpim"] as? String else {
                self.printOut("The server didn't give us a cpim")
                throw "The server didn't give us a cpim"
            }
            let endProvisioningData = try await self.fetchEndProvisioningData(cpim: cpim)
            self.printOut("Giving end provisioning data")
            try await socket.sendJSON(endProvisioningData)
            
        case "ProvisioningSuccess":
            self.printOut("Provisioning succeeded!")
            guard let adiPb = json["adi_pb"] as? String else {
                self.printOut("The server didn't give us an adi.pb file")
                throw "The server didn't give us an adi.pb file"
            }
            try EntitlementAnisetteKeychain.shared.storeAdiPb(adiPb)
            return true
            
        default:
            if result.contains("Error") || result.contains("Invalid") || result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                self.printOut("Failing because of \(result)")
                throw result + (json["message"] as? String ?? "")
            }
        }
        
        return false
    }
    
    private func fetchStartProvisioningData() async throws -> String {
        let body = [
            "Header": [String: Any](),
            "Request": [String: Any](),
        ]
        guard let startProvisioningURL = self.startProvisioningURL else {
            throw "Apple start-provisioning URL is missing"
        }
        var request = try self.buildAppleRequest(url: startProvisioningURL)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
           let spim = plist["Response"]?["spim"] as? String {
            return spim
        } else {
            self.printOut("Apple did not return valid start provisioning data")
            throw "Apple didn't give valid start provisioning data. Please try again later"
        }
    }
    
    private func fetchEndProvisioningData(cpim: String) async throws -> [String: String] {
        let body = [
            "Header": [String: Any](),
            "Request": [
                "cpim": cpim,
            ],
        ]
        guard let endProvisioningURL = self.endProvisioningURL else {
            throw "Apple finish-provisioning URL is missing"
        }
        var request = try self.buildAppleRequest(url: endProvisioningURL)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
           let ptm = plist["Response"]?["ptm"] as? String,
           let tk = plist["Response"]?["tk"] as? String {
            return ["ptm": ptm, "tk": tk]
        } else {
            self.printOut("Apple did not return valid end provisioning data")
            throw "Apple didn't give valid end provisioning data. Please try again later"
        }
    }
    
    private func webSocketURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        
        switch components.scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            break
        }
        
        return components.url ?? url
    }
    
    func buildAppleRequest(url: URL) throws -> URLRequest {
        guard let clientInfo = self.clientInfo,
              let userAgent = self.userAgent,
              let localUserID = self.mdLu,
              let deviceIdentifier = self.deviceId else {
            throw "Anisette client information is not prepared"
        }

        var request = URLRequest(url: url)
        request.setValue(clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(localUserID, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(deviceIdentifier, forHTTPHeaderField: "X-Mme-Device-Id")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        request.setValue(formatter.string(from: Date()), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(TimeZone.current.abbreviation(), forHTTPHeaderField: "X-Apple-I-TimeZone")
        return request
    }

    // MARK: - V3: FETCHING
    
    func fetchClientInfo() async throws {
        self.clientInfo = "<iMac18,3> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        self.userAgent = "AuthKit/1 (Macintosh; OS X 27.0) (com.apple.akd/1.0)"

        var decoded: Data?
        if let identifier = try EntitlementAnisetteKeychain.shared.loadIdentifier(),
           let candidate = Data(base64Encoded: identifier),
           candidate.count == 16 {
            decoded = candidate
        } else {
            try EntitlementAnisetteKeychain.shared.clearIdentifier()
            try EntitlementAnisetteKeychain.shared.clearAdiPb()
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                throw "Couldn't generate Anisette identifier"
            }
            let generated = Data(bytes)
            try EntitlementAnisetteKeychain.shared.storeIdentifier(generated.base64EncodedString())
            decoded = generated
        }

        guard let decoded, decoded.count == 16 else {
            throw "Stored Anisette identifier is invalid"
        }
        self.mdLu = decoded.sha256().hexEncodedString()
        let bytes = [UInt8](decoded)
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        self.deviceId = uuid.uuidString.uppercased()
    }

    func fetchAnisetteV3(_ identifier: String, _ adiPb: String) async throws -> AnisetteData {
        try await fetchClientInfo()
        guard let anisetteURL = self.url,
              anisetteURL.scheme?.lowercased() == "https",
              anisetteURL.host != nil else {
            throw "A valid HTTPS Anisette server is required"
        }
        self.printOut("Fetching anisette V3")
        let headersURL = anisetteURL.appendingPathComponent("v3").appendingPathComponent("get_headers")
        var request = URLRequest(url: headersURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": identifier,
            "adi_pb": adiPb
        ], options: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return try await self.extractAnisetteData(data, response as? HTTPURLResponse, v3: true)
    }

    private func printOut(_ text: String?) {}

}

extension URLSessionWebSocketTask {
    func sendJSON(_ dictionary: [String: String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [])
        guard let message = String(data: data, encoding: .utf8) else {
            throw "Could not encode the Anisette WebSocket message"
        }
        try await self.send(.string(message))
    }
}

extension Data {
    // https://stackoverflow.com/a/25391020
    func sha256() -> Data {
        Data(SHA256.hash(data: self))
    }
    
    // https://stackoverflow.com/a/40089462
    func hexEncodedString() -> String {
        return self.map { String(format: "%02hhX", $0) }.joined()
    }
    
}


extension String: LocalizedError {
    var errorDescription: String? { self }
}
