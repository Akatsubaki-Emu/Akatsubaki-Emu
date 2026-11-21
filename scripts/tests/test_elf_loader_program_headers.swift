import Foundation

enum VMConfiguration {
    enum Architecture { case x86_64, arm64, riscv64 }
}

final class GuestMemory {
    let size: UInt64
    private var bytes: [UInt8]
    init(size: UInt64) { self.size = size; bytes = [UInt8](repeating: 0, count: Int(size)) }
    func clear() { bytes = [UInt8](repeating: 0, count: Int(size)) }
    func zero(offset: UInt64, length: UInt64) -> Bool {
        guard offset <= size, length <= size - offset else { return false }
        let start = Int(offset), end = start + Int(length)
        bytes.replaceSubrange(start..<end, with: repeatElement(0, count: end - start))
        return true
    }
    func write(_ data: Data, sourceRange: Range<Int>, offset: UInt64) -> Bool {
        guard sourceRange.lowerBound >= 0, sourceRange.upperBound <= data.count,
              sourceRange.lowerBound <= sourceRange.upperBound else { return false }
        return write(data.subdata(in: sourceRange), offset: offset)
    }
    func write(_ data: Data, offset: UInt64) -> Bool {
        guard offset <= size, UInt64(data.count) <= size - offset else { return false }
        bytes.replaceSubrange(Int(offset)..<Int(offset) + data.count, with: data)
        return true
    }
    func readByte(offset: UInt64) -> UInt8? {
        guard offset < size else { return nil }
        return bytes[Int(offset)]
    }
}

func isteam_read_le32(_ data: UnsafePointer<UInt8>, _ length: Int, _ offset: Int,
                      _ output: UnsafeMutablePointer<UInt32>) -> Bool {
    guard offset >= 0, offset <= length, length - offset >= 4 else { return false }
    output.pointee = UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    return true
}

func isteam_read_le64(_ data: UnsafePointer<UInt8>, _ length: Int, _ offset: Int,
                      _ output: UnsafeMutablePointer<UInt64>) -> Bool {
    guard offset >= 0, offset <= length, length - offset >= 8 else { return false }
    var value: UInt64 = 0
    for shift in 0..<8 { value |= UInt64(data[offset + shift]) << (shift * 8) }
    output.pointee = value
    return true
}

@main
struct ELFProgramHeaderTests {
    static func put16(_ value: UInt16, _ offset: Int, _ bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    static func put32(_ value: UInt32, _ offset: Int, _ bytes: inout [UInt8]) {
        for shift in 0..<4 { bytes[offset + shift] = UInt8(truncatingIfNeeded: value >> (shift * 8)) }
    }
    static func put64(_ value: UInt64, _ offset: Int, _ bytes: inout [UInt8]) {
        for shift in 0..<8 { bytes[offset + shift] = UInt8(truncatingIfNeeded: value >> (shift * 8)) }
    }
    static func makeELF(phdrAddress: UInt64 = 0x400040, phdrOffset: UInt64 = 64,
                        phdrFileSize: UInt64 = 112, phdrMemorySize: UInt64 = 112,
                        includePHDR: Bool = true) -> Data {
        var bytes = [UInt8](repeating: 0, count: 4096)
        bytes[0] = 0x7F; bytes[1] = 0x45; bytes[2] = 0x4C; bytes[3] = 0x46
        bytes[4] = 2; bytes[5] = 1; bytes[6] = 1
        put16(2, 16, &bytes); put16(62, 18, &bytes); put32(1, 20, &bytes)
        put64(0x400200, 24, &bytes); put64(64, 32, &bytes)
        put16(64, 52, &bytes); put16(56, 54, &bytes)
        put16(includePHDR ? 2 : 1, 56, &bytes)
        let load = 64
        put32(1, load, &bytes); put32(5, load + 4, &bytes)
        put64(0, load + 8, &bytes); put64(0x400000, load + 16, &bytes)
        put64(0, load + 24, &bytes); put64(4096, load + 32, &bytes)
        put64(4096, load + 40, &bytes); put64(4096, load + 48, &bytes)
        if includePHDR {
            let phdr = load + 56
            put32(6, phdr, &bytes); put32(4, phdr + 4, &bytes)
            put64(phdrOffset, phdr + 8, &bytes); put64(phdrAddress, phdr + 16, &bytes)
            put64(0, phdr + 24, &bytes); put64(phdrFileSize, phdr + 32, &bytes)
            put64(phdrMemorySize, phdr + 40, &bytes); put64(8, phdr + 48, &bytes)
        }
        bytes[0x200] = 0xC3
        return Data(bytes)
    }
    static func load(_ data: Data) throws -> ELF64Loader.Image {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".elf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try ELF64Loader().load(url, into: GuestMemory(size: 4 * 1024 * 1024),
                                      expectedArchitecture: .x86_64)
    }
    static func main() throws {
        let valid = try load(makeELF())
        precondition(valid.programHeaderAddress == 0x400040)
        precondition(valid.entryPoint == 0x400200)
        let fallback = try load(makeELF(includePHDR: false))
        precondition(fallback.programHeaderAddress == 0x400040)
        do {
            _ = try load(makeELF(phdrAddress: 0x400100))
            preconditionFailure("Mismatched PT_PHDR virtual address was accepted")
        } catch ELF64Loader.LoadError.programHeadersNotMapped {}
        do {
            _ = try load(makeELF(phdrOffset: 128))
            preconditionFailure("Mismatched PT_PHDR file offset was accepted")
        } catch ELF64Loader.LoadError.invalidProgramHeaderTable {}
        do {
            _ = try load(makeELF(phdrFileSize: 56))
            preconditionFailure("Truncated PT_PHDR table size was accepted")
        } catch ELF64Loader.LoadError.invalidProgramHeaderTable {}
        do {
            _ = try load(makeELF(phdrMemorySize: 56))
            preconditionFailure("Truncated PT_PHDR memory size was accepted")
        } catch ELF64Loader.LoadError.invalidProgramHeaderTable {}
        print("ELF PT_PHDR mapping and fallback tests passed")
    }
}
