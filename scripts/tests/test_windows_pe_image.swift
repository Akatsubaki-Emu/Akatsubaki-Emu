import Foundation

#if os(Linux)
extension URL {
    func startAccessingSecurityScopedResource() -> Bool { false }
    func stopAccessingSecurityScopedResource() {}
}
#endif

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

    static func makeManyOrdinalThunkImage(count: Int) -> Data {
        var bytes = Array(makeImage(importDirectoryRVA: 0x1000, importDirectorySize: 40))
        for index in 0..<count {
            put64(0x8000_0000_0000_0000 | UInt64(index + 1), at: 0x240 + index * 8, in: &bytes)
        }
        put64(0, at: 0x240 + count * 8, in: &bytes)
        return Data(bytes)
    }

    static func makeMultiSectionImage() -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x700)
        bytes[0] = 0x4d
        bytes[1] = 0x5a
        put32(0x80, at: 0x3c, in: &bytes)
        bytes[0x80] = 0x50
        bytes[0x81] = 0x45
        put16(0x8664, at: 0x84, in: &bytes)
        put16(3, at: 0x86, in: &bytes)
        put16(0xF0, at: 0x94, in: &bytes)
        let optional = 0x98
        put16(0x20B, at: optional, in: &bytes)
        put32(0x1000, at: optional + 16, in: &bytes)
        put64(0x140000000, at: optional + 24, in: &bytes)
        put32(0x4000, at: optional + 56, in: &bytes)
        put32(0x200, at: optional + 60, in: &bytes)
        put32(16, at: optional + 108, in: &bytes)
        let table = optional + 0xF0
        // Deliberately store sections in a different order from their RVAs.
        let definitions: [(String, UInt32, UInt32, UInt32)] = [
            (".data", 0x3000, 0x600, 0xC0000040),
            (".rdata", 0x2000, 0x400, 0x40000040),
            (".text", 0x1000, 0x200, 0x60000020)
        ]
        for (index, item) in definitions.enumerated() {
            let offset = table + index * 40
            for (nameIndex, byte) in Array(item.0.utf8).enumerated() { bytes[offset + nameIndex] = byte }
            put32(0x1000, at: offset + 8, in: &bytes)
            put32(item.1, at: offset + 12, in: &bytes)
            put32(0x100, at: offset + 16, in: &bytes)
            put32(item.2, at: offset + 20, in: &bytes)
            put32(item.3, at: offset + 36, in: &bytes)
        }
        return Data(bytes)
    }

    static func makeManySectionImage() -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x4700)
        bytes[0] = 0x4d
        bytes[1] = 0x5a
        put32(0x80, at: 0x3c, in: &bytes)
        bytes[0x80] = 0x50
        bytes[0x81] = 0x45
        put16(0x8664, at: 0x84, in: &bytes)
        put16(32, at: 0x86, in: &bytes)
        put16(0xF0, at: 0x94, in: &bytes)
        let optional = 0x98
        put16(0x20B, at: optional, in: &bytes)
        put32(0x1000, at: optional + 16, in: &bytes)
        put64(0x140000000, at: optional + 24, in: &bytes)
        put32(0x21000, at: optional + 56, in: &bytes)
        put32(0x800, at: optional + 60, in: &bytes)
        put32(16, at: optional + 108, in: &bytes)
        let table = optional + 0xF0
        // Reverse-RVA file order; 32 sections exercise the binary-search path.
        let definitions: [(String, UInt32, UInt32, UInt32)] = (0..<32).reversed().map { index in
            let name = index == 0 ? ".text" : String(format: ".s%02d", index)
            let virtualAddress = UInt32(0x1000 + index * 0x1000)
            let rawOffset = UInt32(0x800 + index * 0x200)
            let characteristics: UInt32 = index == 0 ? 0x60000020 : 0xC0000040
            return (name, virtualAddress, rawOffset, characteristics)
        }
        for (index, item) in definitions.enumerated() {
            let offset = table + index * 40
            for (nameIndex, byte) in Array(item.0.utf8).enumerated() { bytes[offset + nameIndex] = byte }
            put32(0x1000, at: offset + 8, in: &bytes)
            put32(item.1, at: offset + 12, in: &bytes)
            put32(0x100, at: offset + 16, in: &bytes)
            put32(item.2, at: offset + 20, in: &bytes)
            put32(item.3, at: offset + 36, in: &bytes)
        }
        return Data(bytes)
    }

    static func makeTwoSectionImage(
        importDirectoryRVA: UInt32,
        importDirectorySize: UInt32,
        relocationDirectoryRVA: UInt32 = 0,
        relocationDirectorySize: UInt32 = 0
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0x2200)
        bytes[0] = 0x4d
        bytes[1] = 0x5a
        put32(0x80, at: 0x3c, in: &bytes)
        bytes[0x80] = 0x50
        bytes[0x81] = 0x45
        put16(0x8664, at: 0x84, in: &bytes)
        put16(2, at: 0x86, in: &bytes)
        put16(0xF0, at: 0x94, in: &bytes)
        let optional = 0x98
        put16(0x20B, at: optional, in: &bytes)
        put32(0x1000, at: optional + 16, in: &bytes)
        put64(0x140000000, at: optional + 24, in: &bytes)
        put32(0x3000, at: optional + 56, in: &bytes)
        put32(0x200, at: optional + 60, in: &bytes)
        put32(16, at: optional + 108, in: &bytes)
        put32(importDirectoryRVA, at: optional + 120, in: &bytes)
        put32(importDirectorySize, at: optional + 124, in: &bytes)
        put32(relocationDirectoryRVA, at: optional + 152, in: &bytes)
        put32(relocationDirectorySize, at: optional + 156, in: &bytes)
        let table = optional + 0xF0
        for (index, name) in [".text", ".rdata"].enumerated() {
            let offset = table + index * 40
            for (nameIndex, byte) in Array(name.utf8).enumerated() {
                bytes[offset + nameIndex] = byte
            }
            put32(0x1000, at: offset + 8, in: &bytes)
            put32(UInt32(0x1000 + index * 0x1000), at: offset + 12, in: &bytes)
            put32(0x1000, at: offset + 16, in: &bytes)
            put32(UInt32(0x200 + index * 0x1000), at: offset + 20, in: &bytes)
            put32(index == 0 ? 0x60000020 : 0x40000040, at: offset + 36, in: &bytes)
        }
        return bytes
    }

    static func makeCrossSectionThunkImage() -> Data {
        var bytes = makeTwoSectionImage(importDirectoryRVA: 0x1000, importDirectorySize: 40)
        put32(0x1FF8, at: 0x200, in: &bytes)
        put32(0x1030, at: 0x20C, in: &bytes)
        put32(0x1FF8, at: 0x210, in: &bytes)
        for (index, byte) in (Array("KERNEL32.dll".utf8) + [0]).enumerated() {
            bytes[0x230 + index] = byte
        }
        put64(0x8000_0000_0000_0001, at: 0x11F8, in: &bytes)
        put64(0x8000_0000_0000_0002, at: 0x1200, in: &bytes)
        put64(0, at: 0x1208, in: &bytes)
        return Data(bytes)
    }

    static func makeCrossSectionRelocationImage() -> Data {
        var bytes = makeTwoSectionImage(
            importDirectoryRVA: 0,
            importDirectorySize: 0,
            relocationDirectoryRVA: 0x1FF8,
            relocationDirectorySize: 12
        )
        put32(0x1000, at: 0x11F8, in: &bytes)
        put32(12, at: 0x11FC, in: &bytes)
        put16(0xA010, at: 0x1200, in: &bytes)
        put16(0xA020, at: 0x1202, in: &bytes)
        return Data(bytes)
    }

    static func inspectFormat(_ data: Data, name: String, in directory: URL) throws -> GuestExecutableFormat {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        switch GuestProcessManager.shared.inspect(url) {
        case .success(let format):
            return format
        case .failure(let message):
            throw NSError(domain: "WindowsPEImageTests", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func main() throws {
        let validData = makeImage(importDirectoryRVA: 0x1000, importDirectorySize: 40)
        let valid = try WindowsPEImage.parse(validData)
        let inspectionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("akatsubaki-pe-inspection-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inspectionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inspectionDirectory) }

        guard try inspectFormat(validData, name: "valid-amd64.exe", in: inspectionDirectory) == .windowsPE else {
            throw NSError(domain: "WindowsPEImageTests", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "Valid AMD64 PE32+ was not classified as Windows PE"])
        }
        var mzOnly = [UInt8](repeating: 0, count: 64)
        mzOnly[0] = 0x4D
        mzOnly[1] = 0x5A
        put32(0x80, at: 0x3C, in: &mzOnly)
        guard try inspectFormat(Data(mzOnly), name: "dos-only.exe", in: inspectionDirectory) == .unknown else {
            throw NSError(domain: "WindowsPEImageTests", code: 22,
                          userInfo: [NSLocalizedDescriptionKey: "An MZ-only file was incorrectly classified as PE"])
        }
        var wrongMachine = [UInt8](validData)
        put16(0x014C, at: 0x84, in: &wrongMachine)
        guard try inspectFormat(Data(wrongMachine), name: "x86-pe.exe", in: inspectionDirectory) == .unknown else {
            throw NSError(domain: "WindowsPEImageTests", code: 23,
                          userInfo: [NSLocalizedDescriptionKey: "A non-AMD64 PE was incorrectly classified as PE"])
        }
        var wrongOptionalMagic = [UInt8](validData)
        put16(0x010B, at: 0x98, in: &wrongOptionalMagic)
        guard try inspectFormat(Data(wrongOptionalMagic), name: "pe32.exe", in: inspectionDirectory) == .unknown else {
            throw NSError(domain: "WindowsPEImageTests", code: 24,
                          userInfo: [NSLocalizedDescriptionKey: "A PE32 optional header was incorrectly classified as PE32+"])
        }
        var invalidOffset = [UInt8](validData)
        put32(0xFFFF_FFF0, at: 0x3C, in: &invalidOffset)
        guard try inspectFormat(Data(invalidOffset), name: "bad-offset.exe", in: inspectionDirectory) == .unknown else {
            throw NSError(domain: "WindowsPEImageTests", code: 25,
                          userInfo: [NSLocalizedDescriptionKey: "An out-of-range e_lfanew was incorrectly classified as PE"])
        }
        guard try inspectFormat(Data([0x7F, 0x45, 0x4C, 0x46]), name: "hello.elf", in: inspectionDirectory) == .linuxELF else {
            throw NSError(domain: "WindowsPEImageTests", code: 26,
                          userInfo: [NSLocalizedDescriptionKey: "ELF classification regressed"])
        }
        guard valid.imports.count == 1,
              valid.imports[0].library == "KERNEL32.dll",
              valid.imports[0].name == "ExitProcess" else {
            throw NSError(domain: "WindowsPEImageTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Valid import descriptor was not parsed"])
        }

        let multiSection = try WindowsPEImage.parse(makeMultiSectionImage())
        let expectedSmallMappings: [(UInt32, Int)] = [
            (0x1000, 0x200), (0x2000, 0x400), (0x3000, 0x600), (0x30FC, 0x6FC)
        ]
        for (rva, expectedOffset) in expectedSmallMappings {
            guard try multiSection.fileOffset(forRVA: rva, length: 4) == expectedOffset else {
                throw NSError(domain: "WindowsPEImageTests", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "Out-of-order PE sections were not indexed correctly"])
            }
        }
        guard try multiSection.fileOffset(forRVA: 0x2000, length: 0) == 0x300 else {
            throw NSError(domain: "WindowsPEImageTests", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "Zero-length PE boundary mapping changed"])
        }

        // A zero-length cursor at the virtual end of a section with a larger
        // zero-fill tail maps to raw EOF, while the zero-fill bytes stay unmapped.
        let virtualEndImage = try WindowsPEImage.parse(
            makeImage(importDirectoryRVA: 0x1000, importDirectorySize: 40)
        )
        guard try virtualEndImage.fileOffset(forRVA: 0x2000, length: 0) == 0x400 else {
            throw NSError(domain: "WindowsPEImageTests", code: 15,
                          userInfo: [NSLocalizedDescriptionKey: "Virtual-end cursor did not map to raw EOF"])
        }
        do {
            _ = try virtualEndImage.fileOffset(forRVA: 0x1FFF, length: 1)
            throw NSError(domain: "WindowsPEImageTests", code: 16,
                          userInfo: [NSLocalizedDescriptionKey: "PE virtual zero-fill tail was incorrectly treated as file-backed"])
        } catch WindowsPEImage.ParseError.unmappedRVA(_) {
        }
        do {
            _ = try multiSection.fileOffset(forRVA: 0x3100, length: 1)
            throw NSError(domain: "WindowsPEImageTests", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "Raw zero-fill tail was incorrectly treated as file-backed"])
        } catch WindowsPEImage.ParseError.unmappedRVA(_) {
        }

        let manySections = try WindowsPEImage.parse(makeManySectionImage())
        let manyMappings: [(UInt32, Int)] = [
            (0x1000, 0x800), (0x5000, 0x1000), (0x20000, 0x4600), (0x200FC, 0x46FC)
        ]
        for (rva, expectedOffset) in manyMappings {
            guard try manySections.fileOffset(forRVA: rva, length: 4) == expectedOffset else {
                throw NSError(domain: "WindowsPEImageTests", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "32-section PE binary lookup returned an incorrect file offset"])
            }
        }
        do {
            _ = try manySections.fileOffset(forRVA: 0x20100, length: 1)
            throw NSError(domain: "WindowsPEImageTests", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "32-section PE zero-fill tail was incorrectly mapped"])
        } catch WindowsPEImage.ParseError.unmappedRVA(_) {
        }

        let manyThunks = try WindowsPEImage.parse(makeManyOrdinalThunkImage(count: 32))
        guard manyThunks.imports.count == 32,
              manyThunks.imports.first?.ordinal == 1,
              manyThunks.imports.last?.ordinal == 32 else {
            throw NSError(domain: "WindowsPEImageTests", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "Sequential import thunk cursor returned incorrect ordinals"])
        }

        let crossSectionThunks = try WindowsPEImage.parse(makeCrossSectionThunkImage())
        guard crossSectionThunks.imports.count == 2,
              crossSectionThunks.imports[0].ordinal == 1,
              crossSectionThunks.imports[1].ordinal == 2 else {
            throw NSError(domain: "WindowsPEImageTests", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "Cross-section import thunk cursor failed to remap at the raw-data boundary"])
        }

        let crossSectionRelocations = try WindowsPEImage.parse(makeCrossSectionRelocationImage())
        guard crossSectionRelocations.relocations.count == 2,
              crossSectionRelocations.relocations[0].rva == 0x1010,
              crossSectionRelocations.relocations[1].rva == 0x1020 else {
            throw NSError(domain: "WindowsPEImageTests", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "Cross-section relocation cursor failed to remap at the raw-data boundary"])
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
