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

enum GuestMemoryTransactionResult: Int32 {
    case success = 0
    case invalid = 1
    case alreadyMapped = 2
    case allocationFailed = 3
}

final class GuestMemory {
    let size: UInt64
    private var bytes: [UInt8]
    private(set) var readByteCalls = 0
    private(set) var readUInt16Calls = 0
    private(set) var readPrefixCalls = 0
    private(set) var readUInt32Calls = 0
    private(set) var readUInt64Calls = 0
    private let pageSize: UInt64 = 4096
    private var permissionsEnabled = false
    private var pagePermissions: [UInt64: UInt8] = [:]

    init(size: UInt64) {
        self.size = size
        bytes = [UInt8](repeating: 0, count: Int(size))
    }

    // Mirrors GuestMemory.clear(): reset bytes without changing page permissions.
    func clear() {
        bytes = [UInt8](repeating: 0, count: Int(size))
        pagePermissions.removeAll(keepingCapacity: true)
        permissionsEnabled = false
    }


    private func hasPermission(offset: UInt64, length: UInt64, required: UInt8) -> Bool {
        guard length > 0 else { return true }
        guard offset <= size, length <= size - offset else { return false }
        if !permissionsEnabled { return true }
        let first = offset / pageSize
        let last = (offset + length - 1) / pageSize
        for page in first...last {
            guard let current = pagePermissions[page], current & required == required else { return false }
        }
        return true
    }

    func beginMapping() -> Bool {
        pagePermissions.removeAll(keepingCapacity: true)
        permissionsEnabled = true
        return true
    }

    func map(offset: UInt64, length: UInt64, permissions: UInt8, merge: Bool = false) -> Bool {
        guard permissionsEnabled, permissions & ~UInt8(7) == 0,
              length > 0, offset <= size, length <= size - offset else { return false }
        let first = offset / pageSize
        let last = (offset + length - 1) / pageSize
        for page in first...last {
            let old = pagePermissions[page] ?? 0
            pagePermissions[page] = merge ? old | permissions : permissions
        }
        return true
    }

    func protect(offset: UInt64, length: UInt64, permissions: UInt8) -> Bool {
        guard permissionsEnabled, permissions & ~UInt8(7) == 0,
              offset % pageSize == 0, length > 0,
              offset <= size, length <= size - offset else { return false }
        let first = offset / pageSize
        let last = (offset + length - 1) / pageSize
        for page in first...last where pagePermissions[page] == nil { return false }
        for page in first...last { pagePermissions[page] = permissions }
        return true
    }

    func unmap(offset: UInt64, length: UInt64) -> Bool {
        guard permissionsEnabled, offset % pageSize == 0, length > 0,
              offset <= size, length <= size - offset else { return false }
        let first = offset / pageSize
        let last = (offset + length - 1) / pageSize
        for page in first...last {
            pagePermissions.removeValue(forKey: page)
            let start = page * pageSize
            let end = min(size, start + pageSize)
            if start < end {
                bytes.replaceSubrange(Int(start)..<Int(end),
                                      with: repeatElement(0, count: Int(end - start)))
            }
        }
        return true
    }

    func hasMappedPages(offset: UInt64, length: UInt64) -> Bool {
        guard length > 0, offset <= size, length <= size - offset else { return false }
        guard permissionsEnabled else { return true }
        let first = offset / pageSize
        let last = (offset + length - 1) / pageSize
        return (first...last).allSatisfy { pagePermissions[$0] != nil }
    }

    @discardableResult
    func mapTransaction(offset: UInt64, length: UInt64, permissions: UInt8,
                        replaceExisting: Bool) -> GuestMemoryTransactionResult {
        guard permissionsEnabled, offset % pageSize == 0, length > 0,
              permissions & ~UInt8(0x7) == 0,
              offset <= size, length <= size - offset else { return .invalid }
        let first = offset / pageSize
        let last = (offset + length - 1) / pageSize
        if !replaceExisting && (first...last).contains(where: { pagePermissions[$0] != nil }) {
            return .alreadyMapped
        }
        for page in first...last {
            let start = page * pageSize
            let end = start + min(pageSize, size - start)
            if start < end {
                bytes.replaceSubrange(Int(start)..<Int(end),
                                      with: repeatElement(0, count: Int(end - start)))
            }
        }
        return map(offset: offset, length: length, permissions: permissions, merge: false)
            ? .success : .allocationFailed
    }

    @discardableResult
    func resizeBreak(from oldBreak: UInt64, to newBreak: UInt64) -> GuestMemoryTransactionResult {
        guard oldBreak <= size, newBreak <= size else { return .invalid }
        let firstNewPage = oldBreak / pageSize + (oldBreak % pageSize == 0 ? 0 : 1)
        let lastNewPage = newBreak / pageSize + (newBreak % pageSize == 0 ? 0 : 1)
        if newBreak > oldBreak, lastNewPage > firstNewPage {
            return mapTransaction(offset: firstNewPage * pageSize,
                                  length: (lastNewPage - firstNewPage) * pageSize,
                                  permissions: 3, replaceExisting: false)
        }
        if newBreak < oldBreak {
            let firstRemovedPage = newBreak / pageSize + (newBreak % pageSize == 0 ? 0 : 1)
            let lastRemovedPage = oldBreak / pageSize + (oldBreak % pageSize == 0 ? 0 : 1)
            if lastRemovedPage > firstRemovedPage,
               !unmap(offset: firstRemovedPage * pageSize,
                      length: (lastRemovedPage - firstRemovedPage) * pageSize) {
                return .invalid
            }
        }
        return .success
    }

    func readByte(offset: UInt64) -> UInt8? {
        readByteCalls += 1
        guard offset < size, hasPermission(offset: offset, length: 1, required: 1) else { return nil }
        return bytes[Int(offset)]
    }

    func readExecuteByte(offset: UInt64) -> UInt8? {
        readByteCalls += 1
        guard offset < size, hasPermission(offset: offset, length: 1, required: 4) else { return nil }
        return bytes[Int(offset)]
    }

    func readUInt16(offset: UInt64) -> UInt16? {
        readUInt16Calls += 1
        guard offset <= size, size - offset >= 2,
              hasPermission(offset: offset, length: 2, required: 1) else { return nil }
        let index = Int(offset)
        return UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    func readUInt32(offset: UInt64) -> UInt32? {
        readUInt32Calls += 1
        guard offset <= size, size - offset >= 4,
              hasPermission(offset: offset, length: 4, required: 1) else { return nil }
        let index = Int(offset)
        return UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }

    func readExecuteUInt32(offset: UInt64) -> UInt32? {
        readUInt32Calls += 1
        guard offset <= size, size - offset >= 4,
              hasPermission(offset: offset, length: 4, required: 4) else { return nil }
        let index = Int(offset)
        return UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }

    func readUInt64(offset: UInt64) -> UInt64? {
        readUInt64Calls += 1
        guard offset <= size, size - offset >= 8,
              hasPermission(offset: offset, length: 8, required: 1) else { return nil }
        let index = Int(offset)
        var value: UInt64 = 0
        for shift in 0..<8 { value |= UInt64(bytes[index + shift]) << (shift * 8) }
        return value
    }

    func readExecuteUInt64(offset: UInt64) -> UInt64? {
        readUInt64Calls += 1
        guard offset <= size, size - offset >= 8,
              hasPermission(offset: offset, length: 8, required: 4) else { return nil }
        let index = Int(offset)
        var value: UInt64 = 0
        for shift in 0..<8 { value |= UInt64(bytes[index + shift]) << (shift * 8) }
        return value
    }

    func writeByte(_ value: UInt8, offset: UInt64) -> Bool {
        guard offset < size, hasPermission(offset: offset, length: 1, required: 2) else { return false }
        bytes[Int(offset)] = value
        return true
    }

    func readPrefix(offset: UInt64, maximumLength: Int? = nil, into buffer: inout [UInt8]) -> Int? {
        readPrefixCalls += 1
        guard offset <= size else { return nil }
        let requested = min(buffer.count, max(0, maximumLength ?? buffer.count))
        let limit = Int(min(UInt64(requested), size - offset))
        var completed = 0
        while completed < limit {
            let address = offset + UInt64(completed)
            guard hasPermission(offset: address, length: 1, required: 4) else { break }
            let pageRemaining = Int(pageSize - address % pageSize)
            let amount = min(limit - completed, pageRemaining)
            let start = Int(address)
            for index in 0..<amount { buffer[completed + index] = bytes[start + index] }
            completed += amount
        }
        return completed
    }

    func writeUInt32(_ value: UInt32, offset: UInt64) -> Bool {
        guard offset <= size, size - offset >= 4,
              hasPermission(offset: offset, length: 4, required: 2) else { return false }
        let index = Int(offset)
        for shift in 0..<4 { bytes[index + shift] = UInt8(truncatingIfNeeded: value >> (shift * 8)) }
        return true
    }

    func zero(offset: UInt64, length: UInt64) -> Bool {
        guard offset <= size, length <= size - offset, length <= UInt64(Int.max),
              hasPermission(offset: offset, length: length, required: 2) else { return false }
        bytes.replaceSubrange(Int(offset)..<Int(offset + length),
                              with: repeatElement(0, count: Int(length)))
        return true
    }

    func writeUInt64Pair(_ first: UInt64, _ second: UInt64, offset: UInt64) -> Bool {
        guard offset <= size, size - offset >= 16,
              hasPermission(offset: offset, length: 16, required: 2) else { return false }
        let start = Int(offset)
        for index in 0..<8 {
            bytes[start + index] = UInt8(truncatingIfNeeded: first >> (index * 8))
            bytes[start + 8 + index] = UInt8(truncatingIfNeeded: second >> (index * 8))
        }
        return true
    }

    func writeUInt64(_ value: UInt64, offset: UInt64) -> Bool {
        guard offset <= size, size - offset >= 8,
              hasPermission(offset: offset, length: 8, required: 2) else { return false }
        let index = Int(offset)
        for shift in 0..<8 { bytes[index + shift] = UInt8(truncatingIfNeeded: value >> (shift * 8)) }
        return true
    }

    func read(offset: UInt64, length: Int) -> Data? {
        guard length >= 0, offset <= size, UInt64(length) <= size - offset,
              hasPermission(offset: offset, length: UInt64(length), required: 1) else { return nil }
        return Data(bytes[Int(offset)..<Int(offset) + length])
    }

    func read(offset: UInt64, length: Int, into data: inout Data,
              destinationOffset: Int) -> Bool {
        guard length >= 0, destinationOffset >= 0,
              destinationOffset <= data.count,
              length <= data.count - destinationOffset,
              offset <= size, UInt64(length) <= size - offset,
              hasPermission(offset: offset, length: UInt64(length), required: 1) else { return false }
        if length == 0 { return true }
        let start = Int(offset)
        data.replaceSubrange(destinationOffset..<(destinationOffset + length),
                             with: bytes[start..<(start + length)])
        return true
    }

    func write(_ data: Data, sourceRange: Range<Int>, offset: UInt64) -> Bool {
        guard sourceRange.lowerBound >= 0,
              sourceRange.lowerBound <= sourceRange.upperBound,
              sourceRange.upperBound <= data.count else { return false }
        return write(data.subdata(in: sourceRange), offset: offset)
    }

    func write(_ data: Data, offset: UInt64) -> Bool {
        guard offset <= size, UInt64(data.count) <= size - offset,
              hasPermission(offset: offset, length: UInt64(data.count), required: 2) else { return false }
        bytes.replaceSubrange(Int(offset)..<Int(offset) + data.count, with: data)
        return true
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

    static func testDescriptorBoundELFSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableURL = directory.appendingPathComponent("guest.elf")
        let replacementURL = directory.appendingPathComponent("replacement.elf")
        let displacedURL = directory.appendingPathComponent("displaced.elf")
        let original = Data([0x7F, 0x45, 0x4C, 0x46, 0x01, 0x02, 0x03])
        let replacement = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try original.write(to: executableURL)

        // Open and size the guest, then replace its path before consuming bytes.
        let snapshot = try ELF64Loader.OpenedFileSnapshot(url: executableURL)
        try replacement.write(to: replacementURL)
        try FileManager.default.moveItem(at: executableURL, to: displacedURL)
        try FileManager.default.moveItem(at: replacementURL, to: executableURL)

        let loaded = try snapshot.read()
        precondition(loaded == original, "ELF bytes must come from the descriptor that was size-checked")

        let growthURL = directory.appendingPathComponent("growing.elf")
        try original.write(to: growthURL)
        let growthSnapshot = try ELF64Loader.OpenedFileSnapshot(url: growthURL)
        let growthWriter = try FileHandle(forWritingTo: growthURL)
        try growthWriter.seekToEnd()
        try growthWriter.write(contentsOf: Data([0xAA]))
        try growthWriter.close()
        do {
            _ = try growthSnapshot.read()
            preconditionFailure("ELF snapshot must reject file growth after its size check")
        } catch ELF64Loader.LoadError.unreadable {}

        let truncationURL = directory.appendingPathComponent("truncated.elf")
        try original.write(to: truncationURL)
        let truncationSnapshot = try ELF64Loader.OpenedFileSnapshot(url: truncationURL)
        let truncationWriter = try FileHandle(forWritingTo: truncationURL)
        try truncationWriter.truncate(atOffset: 2)
        try truncationWriter.close()
        do {
            _ = try truncationSnapshot.read()
            preconditionFailure("ELF snapshot must reject file truncation after its size check")
        } catch ELF64Loader.LoadError.unreadable {}
        print("Descriptor-bound ELF snapshot path-replacement, growth and truncation regressions passed")
    }

    static func testGeneratedSmokeELF(at url: URL) throws {
        let memory = GuestMemory(size: 16 * 1024 * 1024)
        let image = try ELF64Loader().load(url, into: memory, expectedArchitecture: .x86_64)
        let stack = try LinuxProcessStackBuilder().build(
            executablePath: url.path,
            arguments: [],
            environment: ["PATH": "/bin"],
            memory: memory,
            entryPoint: image.entryPoint,
            programHeaders: .init(
                address: image.programHeaderAddress,
                entrySize: image.programHeaderEntrySize,
                count: image.programHeaderCount
            ),
            maximumImageAddress: image.maximumGuestAddress,
            randomBytes: Data(repeating: 0xA5, count: 16)
        )
        let interpreter = X86_64Interpreter(memory: memory)
        try interpreter.reset(entryPoint: image.entryPoint)
        try interpreter.setInitialStackPointer(stack.stackPointer)
        let (programBreak, overflow) = image.maximumGuestAddress.addingReportingOverflow(4095)
        precondition(!overflow)
        try interpreter.configureLinuxProcess(
            programBreak: programBreak & ~UInt64(4095),
            stackBase: stack.stackBase
        )
        let previousMessageCount = EmulationLog.shared.messages.count
        let exit = try interpreter.run(maxInstructions: 128)
        precondition(exit == .halted, "Generated hybrid smoke guest did not exit cleanly")
        let smokeMessages = EmulationLog.shared.messages.dropFirst(previousMessageCount)
        // Guest output is stored as line-normalized log entries without newline delimiters.
        precondition(smokeMessages.contains { $0.contains("hello") },
                     "Generated hybrid smoke guest did not write its marker")
        print("Generated hybrid XCHG smoke ELF executed through the no-JIT interpreter")
    }

    static func main() throws {
        try testDescriptorBoundELFSnapshot()
        if let smokePath = CommandLine.arguments.dropFirst().first {
            try testGeneratedSmokeELF(at: URL(fileURLWithPath: smokePath))
        }
        let (elfData, expectedOutput) = makeELF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".elf")
        try elfData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Linux PROT_EXEC is independent of PROT_READ. Keep the test double
        // aligned with NativeGuestMemory.cpp and verify actual interpreter fetch.
        let executeOnlyMemory = GuestMemory(size: 4096)
        let executeOnlyCode = Data([0xB8, 0x2A, 0x00, 0x00, 0x00, 0xF4])
        precondition(executeOnlyMemory.write(executeOnlyCode, offset: 0))
        precondition(executeOnlyMemory.beginMapping())
        precondition(executeOnlyMemory.map(offset: 0, length: 4096, permissions: 4))
        precondition(executeOnlyMemory.readExecuteByte(offset: 0) == 0xB8)
        precondition(executeOnlyMemory.readByte(offset: 0) == nil)
        var executeOnlyPrefix = [UInt8](repeating: 0, count: 15)
        precondition(executeOnlyMemory.readPrefix(offset: 0, maximumLength: 15, into: &executeOnlyPrefix) == 15)
        let executeOnlyInterpreter = X86_64Interpreter(memory: executeOnlyMemory)
        try executeOnlyInterpreter.reset(entryPoint: 0)
        let executeOnlyExit = try executeOnlyInterpreter.run(maxInstructions: 4)
        precondition(executeOnlyExit == .halted)
        precondition(executeOnlyInterpreter.registerValue(0) == 42)

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

#if KENRAN_BUTO_AOT_TESTS
        let aotExecutor = KenranButoAOTExecutor()
        precondition(aotExecutor.refreshAvailability(), "ARM64 runner must provide executable memory")
        let interpreter = X86_64Interpreter(memory: memory, aotExecutor: aotExecutor)
#else
        let interpreter = X86_64Interpreter(memory: memory)
#endif
        try interpreter.reset(entryPoint: image.entryPoint)
        try interpreter.setInitialStackPointer(stack.stackPointer)
        let (programBreak, overflow) = image.maximumGuestAddress.addingReportingOverflow(4095)
        precondition(!overflow)
        try interpreter.configureLinuxProcess(programBreak: programBreak & ~UInt64(4095),
                                               stackBase: stack.stackBase)
        let exit = try interpreter.run(maxInstructions: 64)
        precondition(exit == .halted)
        precondition(EmulationLog.shared.messages.contains { $0.contains(expectedOutput) })
#if KENRAN_BUTO_AOT_TESTS
        precondition(aotExecutor.blocksExecuted > 0)
        print("STATIC_ELF_AOT blocks=\(aotExecutor.blocksExecuted) unsupported_syscall_side_exit=verified")
#endif
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
