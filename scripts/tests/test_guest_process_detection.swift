import Foundation

#if os(Linux)
extension URL {
    func startAccessingSecurityScopedResource() -> Bool { false }
    func stopAccessingSecurityScopedResource() {}
}
#endif

@main
struct GuestProcessDetectionTests {
    static func put16(_ value: UInt16, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(value & 0xff)
        bytes[offset + 1] = UInt8(value >> 8)
    }

    static func put32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for index in 0..<4 { bytes[offset + index] = UInt8((value >> (index * 8)) & 0xff) }
    }

    static func put64(_ value: UInt64, at offset: Int, in bytes: inout [UInt8]) {
        for index in 0..<8 { bytes[offset + index] = UInt8((value >> (index * 8)) & 0xff) }
    }

    static func makePE() -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x600)
        bytes[0] = 0x4d
        bytes[1] = 0x5a
        put32(0x80, at: 0x3c, in: &bytes)
        bytes[0x80] = 0x50
        bytes[0x81] = 0x45
        put16(0x8664, at: 0x84, in: &bytes)
        put16(1, at: 0x86, in: &bytes)
        put16(0xF0, at: 0x94, in: &bytes)

        let optional = 0x98
        put16(0x20B, at: optional, in: &bytes)
        put32(0x1000, at: optional + 16, in: &bytes)
        put64(0x140000000, at: optional + 24, in: &bytes)
        put32(0x2000, at: optional + 56, in: &bytes)
        put32(0x200, at: optional + 60, in: &bytes)
        put32(16, at: optional + 108, in: &bytes)

        let section = optional + 0xF0
        for (index, byte) in Array(".text".utf8).enumerated() { bytes[section + index] = byte }
        put32(0x1000, at: section + 8, in: &bytes)
        put32(0x1000, at: section + 12, in: &bytes)
        put32(0x200, at: section + 16, in: &bytes)
        put32(0x200, at: section + 20, in: &bytes)
        put32(0x60000020, at: section + 36, in: &bytes)
        return Data(bytes)
    }

    static func makeELF(machine: UInt16 = 0x3E, elfClass: UInt8 = 2) -> Data {
        var bytes = [UInt8](repeating: 0, count: 120)
        bytes[0] = 0x7F
        bytes[1] = 0x45
        bytes[2] = 0x4C
        bytes[3] = 0x46
        bytes[4] = elfClass
        bytes[5] = 1
        bytes[6] = 1
        put16(2, at: 16, in: &bytes)
        put16(machine, at: 18, in: &bytes)
        put32(1, at: 20, in: &bytes)
        put64(0x400000, at: 24, in: &bytes)
        put64(64, at: 32, in: &bytes)
        put16(64, at: 52, in: &bytes)
        put16(56, at: 54, in: &bytes)
        put16(1, at: 56, in: &bytes)
        return Data(bytes)
    }

    static func inspect(_ data: Data) throws -> GuestProcessFormatResult {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("guest-process-\(UUID().uuidString)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return GuestProcessManager.shared.inspect(url)
    }

    static func main() throws {
        guard case .success(.windowsPE) = try inspect(makePE()) else {
            throw NSError(domain: "GuestProcessDetectionTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Valid PE32+ AMD64 image was not recognized"])
        }
        guard case .failure = try inspect(Data([0x4D, 0x5A, 0, 0])) else {
            throw NSError(domain: "GuestProcessDetectionTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "MZ-only file was accepted as Windows PE"])
        }
        guard case .success(.linuxELF) = try inspect(makeELF()) else {
            throw NSError(domain: "GuestProcessDetectionTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Valid ELF64 x86-64 header was not recognized"])
        }
        guard case .failure = try inspect(Data([0x7F, 0x45, 0x4C, 0x46])) else {
            throw NSError(domain: "GuestProcessDetectionTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "ELF magic-only file was accepted"])
        }
        guard case .failure = try inspect(makeELF(machine: 3)) else {
            throw NSError(domain: "GuestProcessDetectionTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported ELF machine was accepted"])
        }
        guard case .failure = try inspect(makeELF(elfClass: 1)) else {
            throw NSError(domain: "GuestProcessDetectionTests", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "ELF32 file was accepted as ELF64"])
        }
        print("Guest executable format detection tests passed")
    }
}
