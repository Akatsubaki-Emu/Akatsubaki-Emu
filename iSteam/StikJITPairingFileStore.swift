import Foundation
enum StikJITPairingFileStore {
    struct Session { let hostID: String; let hostIRK: String?; let existing: URL?; let pending: URL }
    private static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StikJIT", isDirectory: true) }
    static var pairingFileURL: URL { support.appendingPathComponent("pairingFile.plist") }
    private static var identityURL: URL { support.appendingPathComponent("host-identity.plist") }
    static var hasPairingFile: Bool { (try? load()) != nil }
    static func load() throws -> Data { let d = try Data(contentsOf: pairingFileURL); try validate(d); return d }
    static func storeImported(_ d: Data) throws { try validate(d); try write(d, pairingFileURL); try? FileManager.default.removeItem(at: identityURL) }
    static func prepare() throws -> Session {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let pending = support.appendingPathComponent("pairingFile.pending")
        try? FileManager.default.removeItem(at: pending)
        if let d = try? Data(contentsOf: identityURL),
           let p = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any],
           let id = p["hostIdentifier"] as? String, UUID(uuidString: id) != nil,
           let irk = p["altIRK"] as? Data, irk.count == 16, (try? load()) != nil {
            return Session(hostID: id, hostIRK: irk.map { String(format:"%02x",$0) }.joined(), existing: pairingFileURL, pending: pending)
        }
        return Session(hostID: UUID().uuidString, hostIRK: nil, existing: nil, pending: pending)
    }
    static func save(_ pending: URL, id: String, irk: String) throws {
        let data = try Data(contentsOf: pending); try validate(data)
        guard UUID(uuidString: id) != nil, irk.count == 32 else { throw error("Invalid pairing identity") }
        var key = Data(); var index = irk.startIndex
        for _ in 0..<16 { let next = irk.index(index, offsetBy: 2); guard let b = UInt8(irk[index..<next], radix: 16) else { throw error("Invalid altIRK") }; key.append(b); index = next }
        try write(data, pairingFileURL)
        let identity = try PropertyListSerialization.data(fromPropertyList: ["hostIdentifier":id,"altIRK":key], format:.binary, options:0)
        try write(identity, identityURL); try? FileManager.default.removeItem(at: pending)
    }
    static func reset() throws {
        for url in [pairingFileURL, identityURL, support.appendingPathComponent("pairingFile.pending")] {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
    static func cleanPending(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    private static func validate(_ d: Data) throws {
        guard let p = try PropertyListSerialization.propertyList(from:d,options:[],format:nil) as? [String:Any],
              let pub=p["public_key"] as? Data,pub.count == 32,
              let priv=p["private_key"] as? Data,priv.count == 32,
              let id=p["identifier"] as? String,UUID(uuidString:id) != nil else { throw error("Invalid Apple Remote Pairing property list") }
        if let alt=p["alt_irk"] as? Data,alt.count != 16 { throw error("Invalid pairing altIRK") }
    }
    private static func write(_ d:Data,_ url:URL)throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try d.write(to:url,options:[.atomic,.completeFileProtection])
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:url.path)
        var v=URLResourceValues();v.isExcludedFromBackup=true;var u=url;try? u.setResourceValues(v)
    }
    private static func error(_ m:String)->NSError { NSError(domain:"AkatsubakiPairing",code:1,userInfo:[NSLocalizedDescriptionKey:m]) }
}
