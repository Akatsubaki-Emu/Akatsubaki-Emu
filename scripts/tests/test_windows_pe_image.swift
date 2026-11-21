import Foundation

@main
struct WindowsPEImageTests {
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

    static func makeImage(
        importDirectoryRVA: UInt32,
        importDirectorySize: UInt32,
        relocationDirectoryRVA: UInt32 = 0,
        relocationDirectorySize: UInt32 = 0,
        libraryNameRVA: UInt32 = 0x1030
    ) -> Data {
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
        put32(importDirectoryRVA, at: optional + 120, in: &bytes)
        put32(importDirectorySize, at: optional + 124, in: &bytes)
        put32(relocationDirectoryRVA, at: optional + 152, in: &bytes)
        put32(relocationDirectorySize, at: optional + 156, in: &bytes)

        let section = optional + 0xF0
        for (index, byte) in Array(".text".utf8).enumerated() { bytes[section + index] = byte }
        put32(0x1000, at: section + 8, in: &bytes)
        put32(0x1000, at: section + 12, in: &bytes)
        put32(0x200, at: section + 16, in: &bytes)
        put32(0x200, at: section + 20, in: &bytes)
        put32(0x60000020, at: section + 36, in: &bytes)

        let descriptor = 0x200 + Int(importDirectoryRVA - 0x1000)
        put32(0x1040, at: descriptor, in: &bytes)
        put32(libraryNameRVA, at: descriptor + 12, in: &bytes)
        put32(0x1050, at: descriptor + 16, in: &bytes)
        let libraryOffset = libraryNameRVA >= 0x1000
            ? 0x200 + Int(libraryNameRVA - 0x1000)
            : Int(libraryNameRVA)
        for (index, byte) in (Array("KERNEL32.dll".utf8) + [0]).enumerated() {
            bytes[libraryOffset + index] = byte
        }
        put64(0x1060, at: 0x240, in: &bytes)
        put16(0, at: 0x260, in: &bytes)
        for (index, byte) in (Array("ExitProcess".utf8) + [0]).enumerated() {
            bytes[0x262 + index] = byte
        }
        return Data(bytes)
    }

    static func main() throws {
        let valid = try WindowsPEImage.parse(
            makeImage(importDirectoryRVA: 0x1000, importDirectorySize: 40)
        )
        guard valid.imports.count == 1,
              valid.imports[0].library == "KERNEL32.dll",
              valid.imports[0].name == "ExitProcess" else {
            throw NSError(domain: "WindowsPEImageTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Valid import descriptor was not parsed"])
        }

        do {
            _ = try WindowsPEImage.parse(
                makeImage(importDirectoryRVA: 0x11E8, importDirectorySize: 40)
            )
            throw NSError(domain: "WindowsPEImageTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Import descriptor crossing raw section boundary was accepted"])
        } catch WindowsPEImage.ParseError.unmappedRVA(_) {
        }

        do {
            _ = try valid.fileOffset(forRVA: 0x1F4, length: 20)
            throw NSError(domain: "WindowsPEImageTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Header RVA range crossing SizeOfHeaders was accepted"])
        } catch WindowsPEImage.ParseError.unmappedRVA(_) {
        }

        do {
            _ = try WindowsPEImage.parse(
                makeImage(importDirectoryRVA: 0x1000, importDirectorySize: 40,
                          libraryNameRVA: 0x11F8)
            )
            throw NSError(domain: "WindowsPEImageTests", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "PE string scanning crossed a section raw-data boundary"])
        } catch WindowsPEImage.ParseError.malformed(_) {
        }

        do {
            _ = try WindowsPEImage.parse(
                makeImage(importDirectoryRVA: 0x1000, importDirectorySize: 1)
            )
            throw NSError(domain: "WindowsPEImageTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Import directory smaller than one descriptor was accepted"])
        } catch WindowsPEImage.ParseError.malformed(_) {
        }

        do {
            _ = try WindowsPEImage.parse(
                makeImage(importDirectoryRVA: 0x1000, importDirectorySize: 40,
                          relocationDirectoryRVA: 0x1000, relocationDirectorySize: 1)
            )
            throw NSError(domain: "WindowsPEImageTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Relocation directory smaller than one block was accepted"])
        } catch WindowsPEImage.ParseError.malformed(_) {
        }

        print("Windows PE import directory mapping tests passed")
    }
}
