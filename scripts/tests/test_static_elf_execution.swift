import Foundation

#if os(Linux)
extension URL {
    func startAccessingSecurityScopedResource() -> Bool { false }
    func stopAccessingSecurityScopedResource() {}
}
#endif

struct VMConfiguration {
    enum Architecture: String { case x86_64, arm64, riscv64 }
}

protocol GuestCPUBackend {
    var architecture: VMConfiguration.Architecture { get }
    var instructionCount: UInt64 { get }
    func reset(entryPoint: UInt64) throws
    func setInitialStackPointer(_ pointer: UInt64) throws
    func configureLinuxProcess(programBreak: UInt64, stackBase: UInt64) throws
    func requestStop()
    func resume()
    func run(maxInstructions: UInt64) throws -> GuestCPUExit
}

enum GuestCPUExit: Equatable {
    case halted, instructionLimit, interrupted
    case memoryFault(address: UInt64)
    case unsupportedInstruction(address: UInt64)
    case backendUnavailable(String)
}

enum GuestEngineError: Error {
    case backendNotInstalled(VMConfiguration.Architecture)
    case invalidInstructionBudget
    case invalidState(String)
}

final class GuestMemory {
    static let pageSize: UInt64 = 4096
    let size: UInt64
    private var bytes: [UInt8]
    private var permissionsEnabled = false
    private var pagePermissions: [UInt64: UInt8] = [:]
    init(size: UInt64) { self.size = size; bytes = [UInt8](repeating: 0, count: Int(size)) }
    private func hasPermission(offset: UInt64, length: UInt64, required: UInt8) -> Bool {
        guard length > 0 else { return true }
        guard offset <= size, length <= size - offset else { return false }
        if !permissionsEnabled { return true }
        let first = offset / Self.pageSize, last = (offset + length - 1) / Self.pageSize
        for page in first...last {
            guard let current = pagePermissions[page], current & required == required else { return false }
        }
        return true
    }
    func beginMapping() -> Bool { pagePermissions.removeAll(keepingCapacity: true); permissionsEnabled = true; return true }
    func map(offset: UInt64, length: UInt64, permissions: UInt8, merge: Bool = false) -> Bool {
        guard permissionsEnabled, permissions & ~UInt8(7) == 0, length > 0, offset <= size, length <= size - offset else { return false }
        let first = offset / Self.pageSize, last = (offset + length - 1) / Self.pageSize
        for page in first...last { let old = pagePermissions[page] ?? 0; pagePermissions[page] = merge ? old | permissions : permissions }
        return true
    }
    func hasMappedPages(offset: UInt64, length: UInt64) -> Bool {
        guard length > 0, offset <= size, length <= size - offset else { return false }
        let first = offset / 4096
        let last = (offset + length - 1) / 4096
        return (first...last).contains { pagePermissions[$0] != nil }
    }

    func protect(offset: UInt64, length: UInt64, permissions: UInt8) -> Bool {
        guard permissionsEnabled, permissions & ~UInt8(7) == 0, offset % Self.pageSize == 0, length > 0, offset <= size, length <= size - offset else { return false }
        let first = offset / Self.pageSize, last = (offset + length - 1) / Self.pageSize
        for page in first...last where pagePermissions[page] == nil { return false }
        for page in first...last { pagePermissions[page] = permissions }
        return true
    }
    func unmap(offset: UInt64, length: UInt64) -> Bool {
        guard permissionsEnabled, offset % Self.pageSize == 0, length > 0, offset <= size, length <= size - offset else { return false }
        let first = offset / Self.pageSize, last = (offset + length - 1) / Self.pageSize
        for page in first...last {
            pagePermissions.removeValue(forKey: page)
            let start = page * Self.pageSize, end = min(size, start + Self.pageSize)
            if start < end { bytes.replaceSubrange(Int(start)..<Int(end), with: repeatElement(0, count: Int(end - start))) }
        }
        return true
    }
    func clear() { bytes = [UInt8](repeating: 0, count: Int(size)); permissionsEnabled = false; pagePermissions.removeAll(keepingCapacity: true) }
    func zero(offset: UInt64, length: UInt64) -> Bool {
        guard offset <= size, length <= size - offset, length <= UInt64(Int.max), hasPermission(offset: offset, length: length, required: 2) else { return false }
        let start = Int(offset), end = start + Int(length); bytes.replaceSubrange(start..<end, with: repeatElement(0, count: end - start)); return true
    }
    func readByte(offset: UInt64) -> UInt8? { guard offset < size, hasPermission(offset: offset, length: 1, required: 1) else { return nil }; return bytes[Int(offset)] }
    func readExecuteByte(offset: UInt64) -> UInt8? { guard offset < size, hasPermission(offset: offset, length: 1, required: 5) else { return nil }; return bytes[Int(offset)] }
    func readUInt16(offset: UInt64) -> UInt16? {
        guard offset <= size, size - offset >= 2, hasPermission(offset: offset, length: 2, required: 1) else { return nil }
        let i = Int(offset); return UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
    }
    @discardableResult func writeByte(_ value: UInt8, offset: UInt64) -> Bool {
        guard offset < size, hasPermission(offset: offset, length: 1, required: 2) else { return false }; bytes[Int(offset)] = value; return true
    }
    func readPrefix(offset: UInt64, maximumLength: Int? = nil, into buffer: inout [UInt8]) -> Int? {
        guard offset <= size else { return nil }
        let limit = min(buffer.count, max(0, maximumLength ?? buffer.count)); var count = 0
        while count < limit {
            let current = offset + UInt64(count)
            guard current < size, hasPermission(offset: current, length: 1, required: 5) else { break }
            buffer[count] = bytes[Int(current)]; count += 1
        }
        return count
    }
    func readUInt32(offset: UInt64) -> UInt32? {
        guard offset <= size, size - offset >= 4, hasPermission(offset: offset, length: 4, required: 1) else { return nil }
        let i = Int(offset); return UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
    }
    func readExecuteUInt32(offset: UInt64) -> UInt32? {
        guard offset <= size, size - offset >= 4, hasPermission(offset: offset, length: 4, required: 5) else { return nil }
        let i = Int(offset); return UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
    }
    func readUInt64(offset: UInt64) -> UInt64? {
        guard offset <= size, size - offset >= 8, hasPermission(offset: offset, length: 8, required: 1) else { return nil }
        let i = Int(offset); var value: UInt64 = 0; for shift in 0..<8 { value |= UInt64(bytes[i + shift]) << (shift * 8) }; return value
    }
    func readExecuteUInt64(offset: UInt64) -> UInt64? {
        guard offset <= size, size - offset >= 8, hasPermission(offset: offset, length: 8, required: 5) else { return nil }
        let i = Int(offset); var value: UInt64 = 0; for shift in 0..<8 { value |= UInt64(bytes[i + shift]) << (shift * 8) }; return value
    }
    func writeUInt32(_ value: UInt32, offset: UInt64) -> Bool {
        guard offset <= size, size - offset >= 4, hasPermission(offset: offset, length: 4, required: 2) else { return false }
        let i = Int(offset); for shift in 0..<4 { bytes[i + shift] = UInt8(truncatingIfNeeded: value >> (shift * 8)) }; return true
    }
    func writeUInt64Pair(_ first: UInt64, _ second: UInt64, offset: UInt64) -> Bool {
        guard offset <= size, size - offset >= 16, hasPermission(offset: offset, length: 16, required: 2) else { return false }
        let i = Int(offset); for shift in 0..<8 { bytes[i + shift] = UInt8(truncatingIfNeeded: first >> (shift * 8)); bytes[i + 8 + shift] = UInt8(truncatingIfNeeded: second >> (shift * 8)) }; return true
    }
    func writeUInt64(_ value: UInt64, offset: UInt64) -> Bool {
        guard offset <= size, size - offset >= 8, hasPermission(offset: offset, length: 8, required: 2) else { return false }
        let i = Int(offset); for shift in 0..<8 { bytes[i + shift] = UInt8(truncatingIfNeeded: value >> (shift * 8)) }; return true
    }
    func read(offset: UInt64, length: Int) -> Data? {
        guard length >= 0, offset <= size, UInt64(length) <= size - offset, hasPermission(offset: offset, length: UInt64(length), required: 1) else { return nil }
        return Data(bytes[Int(offset)..<Int(offset) + length])
    }
    func write(_ data: Data, offset: UInt64) -> Bool {
        guard offset <= size, UInt64(data.count) <= size - offset, hasPermission(offset: offset, length: UInt64(data.count), required: 2) else { return false }
        bytes.replaceSubrange(Int(offset)..<Int(offset) + data.count, with: data); return true
    }
    func write(_ data: Data, sourceRange: Range<Int>, offset: UInt64) -> Bool {
        guard sourceRange.lowerBound >= 0, sourceRange.upperBound <= data.count, sourceRange.lowerBound <= sourceRange.upperBound else { return false }
        return write(data.subdata(in: sourceRange), offset: offset)
    }
}
final class EmulationLog {
    static let shared = EmulationLog()
    private(set) var messages: [String] = []
    func write(_ message: String) { messages.append(message) }
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
struct StaticELFExecutionTests {
    static func put16(_ value: UInt16, _ offset: Int, _ bytes: inout [UInt8]) {
        for shift in 0..<2 { bytes[offset + shift] = UInt8(truncatingIfNeeded: value >> (shift * 8)) }
    }

    static func put32(_ value: UInt32, _ offset: Int, _ bytes: inout [UInt8]) {
        for shift in 0..<4 { bytes[offset + shift] = UInt8(truncatingIfNeeded: value >> (shift * 8)) }
    }

    static func put64(_ value: UInt64, _ offset: Int, _ bytes: inout [UInt8]) {
        for shift in 0..<8 { bytes[offset + shift] = UInt8(truncatingIfNeeded: value >> (shift * 8)) }
    }

    static func makeELF() -> (Data, String) {
        let message = "hello from static ELF\n"
        let messageBytes = Array(message.utf8)
        var bytes = [UInt8](repeating: 0, count: 4096)
        bytes[0...3] = [0x7F, 0x45, 0x4C, 0x46]
        bytes[4] = 2
        bytes[5] = 1
        bytes[6] = 1
        put16(2, 16, &bytes)
        put16(62, 18, &bytes)
        put32(1, 20, &bytes)
        put64(0x400200, 24, &bytes)
        put64(64, 32, &bytes)
        put16(64, 52, &bytes)
        put16(56, 54, &bytes)
        put16(2, 56, &bytes)

        let load = 64
        put32(1, load, &bytes)
        put32(5, load + 4, &bytes)
        put64(0, load + 8, &bytes)
        put64(0x400000, load + 16, &bytes)
        put64(0, load + 24, &bytes)
        put64(4096, load + 32, &bytes)
        put64(4096, load + 40, &bytes)
        put64(4096, load + 48, &bytes)

        let phdr = load + 56
        put32(6, phdr, &bytes)
        put32(4, phdr + 4, &bytes)
        put64(64, phdr + 8, &bytes)
        put64(0x400040, phdr + 16, &bytes)
        put64(0, phdr + 24, &bytes)
        put64(112, phdr + 32, &bytes)
        put64(112, phdr + 40, &bytes)
        put64(8, phdr + 48, &bytes)

        let code: [UInt8] = [
            0xB8, 0x01, 0x00, 0x00, 0x00,
            0xBF, 0x01, 0x00, 0x00, 0x00,
            0x48, 0x8D, 0x35, 0xEF, 0x00, 0x00, 0x00,
            0xBA, UInt8(truncatingIfNeeded: messageBytes.count), 0x00, 0x00, 0x00,
            0x0F, 0x05,
            0xB8, 0x3C, 0x00, 0x00, 0x00,
            0x31, 0xFF,
            0x0F, 0x05
        ]
        bytes.replaceSubrange(0x200..<(0x200 + code.count), with: code)
        bytes.replaceSubrange(0x300..<(0x300 + messageBytes.count), with: messageBytes)
        return (Data(bytes), message)
    }

    static func makePIE(relocationType: UInt32 = 8, includeDependency: Bool = false,
                        loadAlignment: UInt64 = 4096) -> Data {
        var bytes = [UInt8](repeating: 0, count: 4096)
        bytes[0...3] = [0x7F, 0x45, 0x4C, 0x46]
        bytes[4] = 2
        bytes[5] = 1
        bytes[6] = 1
        put16(3, 16, &bytes)
        put16(62, 18, &bytes)
        put32(1, 20, &bytes)
        put64(0x200, 24, &bytes)
        put64(64, 32, &bytes)
        put16(64, 52, &bytes)
        put16(56, 54, &bytes)
        put16(3, 56, &bytes)

        let load = 64
        put32(1, load, &bytes)
        put32(7, load + 4, &bytes)
        put64(0, load + 8, &bytes)
        put64(0, load + 16, &bytes)
        put64(0, load + 24, &bytes)
        put64(4096, load + 32, &bytes)
        put64(4096, load + 40, &bytes)
        put64(loadAlignment, load + 48, &bytes)

        let phdr = load + 56
        put32(6, phdr, &bytes)
        put32(4, phdr + 4, &bytes)
        put64(64, phdr + 8, &bytes)
        put64(0x40, phdr + 16, &bytes)
        put64(0, phdr + 24, &bytes)
        put64(168, phdr + 32, &bytes)
        put64(168, phdr + 40, &bytes)
        put64(8, phdr + 48, &bytes)

        let dynamic = load + 112
        let dynamicCount = includeDependency ? 5 : 4
        put32(2, dynamic, &bytes)
        put32(6, dynamic + 4, &bytes)
        put64(0x400, dynamic + 8, &bytes)
        put64(0x400, dynamic + 16, &bytes)
        put64(0, dynamic + 24, &bytes)
        put64(UInt64(dynamicCount * 16), dynamic + 32, &bytes)
        put64(UInt64(dynamicCount * 16), dynamic + 40, &bytes)
        put64(8, dynamic + 48, &bytes)

        var entries: [(UInt64, UInt64)] = []
        if includeDependency { entries.append((1, 0)) }
        entries += [(7, 0x500), (8, 24), (9, 24), (0, 0)]
        for (index, entry) in entries.enumerated() {
            put64(entry.0, 0x400 + index * 16, &bytes)
            put64(entry.1, 0x408 + index * 16, &bytes)
        }
        put64(0x600, 0x500, &bytes)
        put64(UInt64(relocationType), 0x508, &bytes)
        put64(0x700, 0x510, &bytes)
        return Data(bytes)
    }

    static func rejectsPIE(_ data: Data) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pie")
        do {
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            _ = try ELF64Loader().load(url, into: GuestMemory(size: 16 * 1024 * 1024),
                                       expectedArchitecture: .x86_64)
            return false
        } catch {
            try? FileManager.default.removeItem(at: url)
            return true
        }
    }

    static func main() throws {
        let (elfData, expectedOutput) = makeELF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".elf")
        try elfData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let memory = GuestMemory(size: 16 * 1024 * 1024)
        precondition(memory.writeByte(0xA5, offset: memory.size - 1))
        precondition(memory.readByte(offset: memory.size - 1) == 0xA5)
        precondition(!memory.writeByte(0xA5, offset: memory.size))
        let image = try ELF64Loader().load(url, into: memory, expectedArchitecture: .x86_64)
        let stack = try LinuxProcessStackBuilder().build(
            executablePath: url.path,
            arguments: [],
            environment: ["PATH": "/bin"],
            memory: memory,
            entryPoint: image.entryPoint,
            programHeaders: .init(address: image.programHeaderAddress,
                                  entrySize: image.programHeaderEntrySize,
                                  count: image.programHeaderCount),
            maximumImageAddress: image.maximumGuestAddress,
            randomBytes: Data(repeating: 0xA5, count: 16)
        )

        let interpreter = X86_64Interpreter(memory: memory)
        try interpreter.reset(entryPoint: image.entryPoint)
        try interpreter.setInitialStackPointer(stack.stackPointer)
        let (programBreak, overflow) = image.maximumGuestAddress.addingReportingOverflow(4095)
        precondition(!overflow)
        try interpreter.configureLinuxProcess(programBreak: programBreak & ~UInt64(4095),
                                               stackBase: stack.stackBase)
        let exit = try interpreter.run(maxInstructions: 64)
        precondition(exit == .halted)
        precondition(EmulationLog.shared.messages.contains { $0.contains(expectedOutput) })
        let pieURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pie")
        try makePIE().write(to: pieURL)
        defer { try? FileManager.default.removeItem(at: pieURL) }
        let pieMemory = GuestMemory(size: 16 * 1024 * 1024)
        let pieImage = try ELF64Loader().load(pieURL, into: pieMemory, expectedArchitecture: .x86_64)
        precondition(pieImage.entryPoint == 0x400200)
        precondition(pieImage.programHeaderAddress == 0x400040)
        precondition(pieMemory.readUInt64(offset: 0x400600) == 0x400700)
        precondition(rejectsPIE(makePIE(includeDependency: true)))
        precondition(rejectsPIE(makePIE(relocationType: 1)))
        precondition(rejectsPIE(makePIE(loadAlignment: 8 * 1024 * 1024)))
        print("Static ET_EXEC execution and static PIE load-bias/relative-relocation checks passed")
    }
}
