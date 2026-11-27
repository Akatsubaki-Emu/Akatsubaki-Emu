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
    case exited(Int32)
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
        let requestedLength = maximumLength ?? buffer.count
        guard requestedLength >= 0 else { return nil }
        let requested = min(buffer.count, requestedLength)
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
        if completed == 0 && requested > 0 && offset < size {
            return nil
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

    // This single-threaded test double mirrors exchange semantics; native C++ tests verify atomicity.
    func exchangeByte(_ value: UInt8, offset: UInt64) -> UInt8? {
        guard let previous = readByte(offset: offset),
              writeByte(value, offset: offset) else { return nil }
        return previous
    }

    func exchangeUInt32(_ value: UInt32, offset: UInt64) -> UInt32? {
        guard let previous = readUInt32(offset: offset),
              writeUInt32(value, offset: offset) else { return nil }
        return previous
    }

    func exchangeUInt64(_ value: UInt64, offset: UInt64) -> UInt64? {
        guard let previous = readUInt64(offset: offset),
              writeUInt64(value, offset: offset) else { return nil }
        return previous
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
        return data.withUnsafeMutableBytes { destination -> Bool in
            guard let base = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let target = base.advanced(by: destinationOffset)
            let sourceOffset = Int(offset)
            for index in 0..<length {
                target[index] = bytes[sourceOffset + index]
            }
            return true
        }
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

    static func testExecutePrefixPermissionBoundary() {
        let memory = GuestMemory(size: 8192)
        precondition(memory.write(Data([0x90, 0x91, 0x92, 0x93]), offset: 4094))
        precondition(memory.beginMapping())
        precondition(memory.map(offset: 0, length: 4096, permissions: 5))
        precondition(memory.map(offset: 4096, length: 4096, permissions: 1))

        var window = [UInt8](repeating: 0, count: 4)
        precondition(memory.readPrefix(offset: 4094, maximumLength: 4, into: &window) == 2,
                     "Executable-prefix reads must stop at the first non-executable page")
        precondition(Array(window.prefix(2)) == [0x90, 0x91])
        precondition(memory.readExecuteByte(offset: 4096) == nil)
        precondition(memory.readPrefix(offset: 4096, maximumLength: 4, into: &window) == nil,
                     "A non-executable first byte must be reported as a fetch fault")
        precondition(memory.readPrefix(offset: 4096, maximumLength: 0, into: &window) == 0)
        precondition(memory.readPrefix(offset: 8192, maximumLength: 4, into: &window) == 0)
        precondition(memory.readPrefix(offset: 4094, maximumLength: -1, into: &window) == nil)
        print("Guest execute-prefix permission boundary contract passed")
    }

    static func testByteImmediateInstructions() throws {
        func run(_ code: [UInt8], register: Int, expectedValue: UInt64) throws {
            let memory = GuestMemory(size: 4096)
            precondition(memory.write(Data(code), offset: 0))
#if KENRAN_BUTO_AOT_TESTS
            let aotExecutor = KenranButoAOTExecutor()
            precondition(aotExecutor.refreshAvailability(),
                         "ARM64 AOT test host must provide executable memory")
            let interpreter = X86_64Interpreter(memory: memory, aotExecutor: aotExecutor)
#else
            let interpreter = X86_64Interpreter(memory: memory)
#endif
            try interpreter.reset(entryPoint: 0)
            let exit = try interpreter.run(maxInstructions: 8)
            precondition(exit == .halted, "MOV r8, imm8 sequence did not halt")
            precondition(interpreter.registerValue(register) == expectedValue,
                         "MOV r8, imm8 produced the wrong register value")
            precondition(interpreter.conditionFlags == 0x2,
                         "MOV r8, imm8 must preserve RFLAGS")
#if KENRAN_BUTO_AOT_TESTS
            precondition(aotExecutor.blocksExecuted > 0,
                         "MOV r8, imm8 sequence did not execute through AOT")
#endif
        }

        let baseRAX: [UInt8] = [
            0x48, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11
        ]
        let baseRSP: [UInt8] = [
            0x48, 0xBC, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ]
        let baseR12: [UInt8] = [
            0x49, 0xBC, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88
        ]
        let baseR15: [UInt8] = [
            0x49, 0xBF, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88
        ]

        // Start directly at B0 to verify AOT block-entry eligibility.
        try run([0xB0, 0x7F, 0xF4], register: 0, expectedValue: 0x7F)
        // AH is selected only without REX and changes bits 8...15 of RAX.
        try run(baseRAX + [0xB4, 0xAA, 0xF4],
                register: 0, expectedValue: 0x112233445566AA88)
        // REX.B selects R12B/R15B; all upper bits remain unchanged.
        try run(baseR12 + [0x41, 0xB4, 0x5A, 0xF4],
                register: 12, expectedValue: 0x887766554433225A)
        try run(baseR15 + [0x41, 0xB7, 0xAB, 0xF4],
                register: 15, expectedValue: 0x88776655443322AB)
        // Any REX prefix disables AH; B4 becomes SPL, including REX.R-only.
        try run(baseRSP + [0x40, 0xB4, 0x42, 0xF4],
                register: 4, expectedValue: 0x842)
        try run(baseRSP + [0x44, 0xB4, 0x42, 0xF4],
                register: 4, expectedValue: 0x842)

        print("MOV r8, imm8 register selection, AOT execution and RFLAGS tests passed")
    }

    static func testByteSwapInstructions() throws {
        func run(_ code: [UInt8], register: Int, expectedValue: UInt64,
                 sideExitAddress: UInt64) throws {
            let memory = GuestMemory(size: 4096)
            precondition(memory.write(Data(code), offset: 0))
#if KENRAN_BUTO_AOT_TESTS
            let aotExecutor = KenranButoAOTExecutor()
            precondition(aotExecutor.refreshAvailability(),
                         "ARM64 AOT test host must provide executable memory")

            // Prove BSWAP is in the translated block. A nonzero block count alone
            // is insufficient because the leading MOV could be translated while
            // the interpreter handles BSWAP after an AOT side-exit.
            var directRegisters = [UInt64](repeating: 0, count: 16)
            let directResult = aotExecutor.execute(
                guestCode: Data(code),
                registers: &directRegisters,
                rip: 0,
                rflags: 0x202,
                fsBase: 0,
                gsBase: 0,
                memory: memory,
                maximumInstructions: 4
            )
            precondition(directResult != nil, "AOT BSWAP block must compile and execute")
            let aotResult = directResult!
            precondition(aotResult.guestBytesConsumed == Int(sideExitAddress),
                         "AOT must consume MOV plus BSWAP before the UD2")
            precondition(aotResult.instructionCount == 2,
                         "AOT must execute exactly MOV plus BSWAP")
            precondition(aotResult.exitRip == sideExitAddress,
                         "AOT must side-exit at the UD2 address")
            precondition(aotResult.exitReason == .unsupportedInstruction,
                         "AOT must report the UD2 side-exit")
            precondition(directRegisters[register] == expectedValue,
                         "AOT BSWAP register result mismatch")
            // The executor rejects any block that changes RFLAGS from 0x202.
            precondition(aotExecutor.blocksExecuted == 1,
                         "Direct BSWAP execution must account for one AOT block")
            let interpreter = X86_64Interpreter(memory: memory, aotExecutor: aotExecutor)
#else
            let interpreter = X86_64Interpreter(memory: memory)
#endif
            try interpreter.reset(entryPoint: 0)
            let exit = try interpreter.run(maxInstructions: 4)
            precondition(exit == .unsupportedInstruction(address: sideExitAddress),
                         "BSWAP must side-exit at the following UD2")
            precondition(interpreter.registerValue(register) == expectedValue,
                         "BSWAP produced the wrong register value")
            precondition(interpreter.conditionFlags == 0x2,
                         "BSWAP must preserve RFLAGS")
            precondition(interpreter.instructionCount == 2,
                         "MOV and BSWAP must be the only guest instructions executed")
#if KENRAN_BUTO_AOT_TESTS
            precondition(aotExecutor.blocksExecuted == 2,
                         "Hybrid interpreter must execute the BSWAP block through AOT")
#endif
        }

        let baseRAX: [UInt8] = [
            0x48, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11
        ]
        let baseR9: [UInt8] = [
            0x49, 0xB9, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11
        ]
        let baseR8: [UInt8] = [
            0x49, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11
        ]

        // BSWAP EAX reverses the low 32 bits and zero-extends RAX.
        try run(baseRAX + [0x0F, 0xC8, 0x0F, 0x0B],
                register: 0, expectedValue: 0x88776655, sideExitAddress: 12)
        // REX.W+B selects the full 64-bit R9 register.
        try run(baseR9 + [0x49, 0x0F, 0xC9, 0x0F, 0x0B],
                register: 9, expectedValue: 0x8877665544332211, sideExitAddress: 13)
        // REX.B without REX.W selects R8D and must zero-extend.
        try run(baseR8 + [0x41, 0x0F, 0xC8, 0x0F, 0x0B],
                register: 8, expectedValue: 0x88776655, sideExitAddress: 13)
        // REX.R alone does not extend the opcode-embedded register number.
        try run(baseRAX + [0x44, 0x0F, 0xC8, 0x0F, 0x0B],
                register: 0, expectedValue: 0x88776655, sideExitAddress: 13)

        print("BSWAP EAX/R8D/R9 AOT execution, side-exit and RFLAGS tests passed")
    }

    static func testDescriptorBoundELFSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try ELF64Loader.OpenedFileSnapshot(url: directory)
            preconditionFailure("A directory must not be accepted as an ELF executable")
        } catch ELF64Loader.LoadError.unreadable {
            print("Non-regular ELF source rejection passed")
        }

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

    static func testRejectsNonRegularELFSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try ELF64Loader.OpenedFileSnapshot(url: directory)
            preconditionFailure("A directory must not be accepted as an ELF executable")
        } catch ELF64Loader.LoadError.unreadable {
            print("Non-regular ELF source rejection passed")
        }
    }

    static func testFailedPIERelocationClearsGuestMemory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".invalid-pie")
        try makePIE(relocationType: 1).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let memory = GuestMemory(size: 16 * 1024 * 1024)
        do {
            _ = try ELF64Loader().load(url, into: memory, expectedArchitecture: .x86_64)
            preconditionFailure("An unsupported PIE relocation must fail the ELF load")
        } catch ELF64Loader.LoadError.unsupportedDynamicImage {
            // The failure occurs after PT_LOAD bytes are copied into guest memory.
        }

        precondition(memory.readUInt64(offset: 0x400600) == 0,
                     "A failed ELF relocation must clear the partially loaded guest image")
        print("Failed static PIE relocation clears partial guest memory")
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
        precondition(exit == .exited(0), "Generated hybrid smoke guest did not exit with status 0")
        let smokeMessages = EmulationLog.shared.messages.dropFirst(previousMessageCount)
        // Guest output is stored as line-normalized log entries without newline delimiters.
        precondition(smokeMessages.contains { $0.contains("KENRAN_BUTO_XCHG_OK") },
                     "Generated hybrid smoke guest did not write its marker")
        print("Generated hybrid XCHG smoke ELF executed through the no-JIT interpreter")
    }

    static func testGeneratedRuntimeSmokeELF(at url: URL) throws {
        let memory = GuestMemory(size: 16 * 1024 * 1024)
        let image = try ELF64Loader().load(url, into: memory, expectedArchitecture: .x86_64)
        precondition(image.entryPoint == 0x401000, "Runtime smoke ELF entry point changed")
        precondition(image.programHeaderAddress == 0x400040, "Runtime smoke ELF program headers must be mapped in PT_LOAD")
        precondition(image.programHeaderCount == 2, "Runtime smoke ELF program-header count changed")

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
            randomBytes: Data(repeating: 0x5A, count: 16)
        )
        let interpreter = X86_64Interpreter(memory: memory)
        try interpreter.reset(entryPoint: image.entryPoint)
        try interpreter.setInitialStackPointer(stack.stackPointer)
        let (programBreak, overflow) = image.maximumGuestAddress.addingReportingOverflow(4095)
        precondition(!overflow, "Runtime smoke ELF program break overflow")
        try interpreter.configureLinuxProcess(
            programBreak: programBreak & ~UInt64(4095),
            stackBase: stack.stackBase
        )

        let previousMessageCount = EmulationLog.shared.messages.count
        let exit = try interpreter.run(maxInstructions: 256)
        precondition(exit == .exited(0), "Runtime smoke guest did not exit with status 0")
        let output = EmulationLog.shared.messages.dropFirst(previousMessageCount).joined()
        precondition(output.contains("Linux"), "uname sysname was not written to stdout")
        precondition(output.contains("x86_64"), "uname machine was not written to stdout")
        precondition(output.contains("KENRAN_BUTO_RUNTIME_OK"), "Runtime smoke marker was not written")
        precondition(memory.readByte(offset: 0x402000) == 0x4C, "uname sysname buffer was not populated")
        precondition(memory.readByte(offset: 0x402104) == 0x78, "uname machine buffer was not populated")
        print("Generated runtime smoke ELF executed uname, write and exit through the interpreter")
    }


    static func testGeneratedStdinSmokeELF(at url: URL) throws {
        let memory = GuestMemory(size: 16 * 1024 * 1024)
        let image = try ELF64Loader().load(url, into: memory, expectedArchitecture: .x86_64)
        precondition(image.entryPoint == 0x401000, "stdin smoke ELF entry point changed")
        precondition(image.programHeaderAddress == 0x400040, "stdin smoke ELF program headers must be mapped in PT_LOAD")
        precondition(image.programHeaderCount == 2, "stdin smoke ELF program-header count changed")

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
            randomBytes: Data(repeating: 0x3C, count: 16)
        )
#if KENRAN_BUTO_AOT_TESTS
        let aotExecutor = KenranButoAOTExecutor()
        precondition(aotExecutor.refreshAvailability(), "ARM64 runner must provide executable memory for stdin smoke")
        let interpreter = X86_64Interpreter(memory: memory, aotExecutor: aotExecutor)
#else
        let interpreter = X86_64Interpreter(memory: memory)
#endif
        try interpreter.reset(entryPoint: image.entryPoint)
        try interpreter.setInitialStackPointer(stack.stackPointer)
        let (programBreak, overflow) = image.maximumGuestAddress.addingReportingOverflow(4095)
        precondition(!overflow, "stdin smoke ELF program break overflow")
        try interpreter.configureLinuxProcess(
            programBreak: programBreak & ~UInt64(4095),
            stackBase: stack.stackBase
        )

        let input = Data("hello\n".utf8)
        precondition(interpreter.enqueueStandardInput(input) == input.count,
                     "stdin smoke input was not accepted by the interpreter")
        let previousMessageCount = EmulationLog.shared.messages.count
        let exit = try interpreter.run(maxInstructions: 512)
        precondition(exit == .exited(0), "stdin smoke guest did not exit with status 0")
        let outputMessages = Array(EmulationLog.shared.messages.dropFirst(previousMessageCount))
        let output = outputMessages.joined(separator: "\n")
        precondition(output.contains("KENRAN_BUTO_STDIN_READY"), "stdin smoke guest did not announce its read")
        precondition(output.contains("KENRAN_BUTO_STDIN_OK"), "stdin smoke guest did not write its completion marker")
        guard let readBack = memory.read(offset: stack.stackPointer - 128, length: input.count) else {
            preconditionFailure("stdin smoke input buffer was not readable after guest execution")
        }
        precondition(readBack == input, "stdin smoke input bytes were not written to guest stack memory")
        // A terminal write is a byte stream, but EmulationLog deliberately records
        // each write(1, ...) call as a separate message.
        let echoPrefixIndex = outputMessages.firstIndex { $0.contains("KENRAN_BUTO_STDIN_ECHO:") }
        let echoInputIndex = outputMessages.firstIndex { $0.contains("hello\\n") }
        precondition(
            echoPrefixIndex != nil && echoInputIndex != nil && echoPrefixIndex! < echoInputIndex!,
            "stdin smoke guest did not echo queued input after its prefix"
        )
#if KENRAN_BUTO_AOT_TESTS
        precondition(aotExecutor.blocksExecuted > 0, "stdin smoke guest did not execute any native AOT blocks")
#endif
        print("Generated stdin smoke ELF read queued input, echoed it and exited through the interpreter")
    }

    static func testSignExtensionInstructions() throws {
        func run(_ code: Data, expectedRAX: UInt64, expectedRDX: UInt64) throws {
            let memory = GuestMemory(size: 4096)
            precondition(memory.write(code, offset: 0))
#if KENRAN_BUTO_AOT_TESTS
            let aotExecutor = KenranButoAOTExecutor()
            precondition(aotExecutor.refreshAvailability(), "ARM64 AOT test host must provide executable memory")
            let interpreter = X86_64Interpreter(memory: memory, aotExecutor: aotExecutor)
#else
            let interpreter = X86_64Interpreter(memory: memory)
#endif
            try interpreter.reset(entryPoint: 0)
            let exit = try interpreter.run(maxInstructions: 4)
            precondition(exit == .halted, "Sign-extension instruction sequence did not halt")
            precondition(interpreter.registerValue(0) == expectedRAX, "Incorrect CWDE/CDQE result")
            precondition(interpreter.registerValue(2) == expectedRDX, "Incorrect CDQ/CQO result")
            precondition(interpreter.conditionFlags == 0x2, "Sign-extension instructions must preserve RFLAGS")
#if KENRAN_BUTO_AOT_TESTS
            precondition(aotExecutor.blocksExecuted > 0, "Sign-extension block did not execute through AOT")
#endif
        }

        // CWDE: sign-extend AX into EAX, then CDQ: sign-extend EAX into EDX.
        try run(Data([0xB8, 0x00, 0x80, 0x00, 0x00, 0x98, 0x99, 0xF4]),
                expectedRAX: 0x00000000FFFF8000,
                expectedRDX: 0x00000000FFFFFFFF)
        // CDQE: sign-extend EAX into RAX, then CQO: sign-extend RAX into RDX.
        try run(Data([0xB8, 0x00, 0x00, 0x00, 0x80, 0x48, 0x98, 0x48, 0x99, 0xF4]),
                expectedRAX: 0xFFFFFFFF80000000,
                expectedRDX: UInt64.max)
        // CBW writes only AX: upper RAX bits must survive the 8-to-16-bit extension.
        try run(Data([0xB8, 0x80, 0x00, 0xAD, 0xDE, 0x66, 0x98, 0xF4]),
                expectedRAX: 0x00000000DEADFF80, expectedRDX: 0)
        // CWD writes only DX: upper RDX bits must survive the 16-to-32-bit extension.
        try run(Data([0xB8, 0x00, 0x80, 0x34, 0x12, 0xBA, 0x34, 0x12, 0xCD, 0xAB, 0x66, 0x99, 0xF4]),
                expectedRAX: 0x0000000012348000, expectedRDX: 0x00000000ABCDFFFF)
        // REX.W overrides 0x66 and retains the 64-bit CDQE/CQO forms.
        try run(Data([0xB8, 0x00, 0x00, 0x00, 0x80, 0x66, 0x48, 0x98, 0x66, 0x48, 0x99, 0xF4]),
                expectedRAX: 0xFFFFFFFF80000000, expectedRDX: UInt64.max)

        // A 16-bit prefix on an unimplemented arithmetic instruction must fail closed.
        let unsupportedMemory = GuestMemory(size: 4096)
        precondition(unsupportedMemory.write(Data([0x66, 0x01, 0xC8]), offset: 0))
        let unsupportedInterpreter = X86_64Interpreter(memory: unsupportedMemory)
        try unsupportedInterpreter.reset(entryPoint: 0)
        let unsupportedExit = try unsupportedInterpreter.run(maxInstructions: 1)
        guard case .unsupportedInstruction(address: let unsupportedAddress) = unsupportedExit else {
            preconditionFailure("Unsupported 16-bit arithmetic did not side-exit")
        }
        precondition(unsupportedAddress == 0 && unsupportedInterpreter.instructionPointer == 0)

        // REX.W overrides 0x66, so this remains a 64-bit ADD rather than a 16-bit fallback.
        let rexOverrideMemory = GuestMemory(size: 4096)
        let rexOverrideCode = Data([
            0x48, 0xB8, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x48, 0xB9, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x66, 0x48, 0x01, 0xC8, 0xF4
        ])
        precondition(rexOverrideMemory.write(rexOverrideCode, offset: 0))
        let rexOverrideInterpreter = X86_64Interpreter(memory: rexOverrideMemory)
        try rexOverrideInterpreter.reset(entryPoint: 0)
        let rexOverrideExit = try rexOverrideInterpreter.run(maxInstructions: 4)
        precondition(rexOverrideExit == .halted, "REX.W must override 0x66 for 64-bit ADD")
        precondition(rexOverrideInterpreter.registerValue(0) == 3, "REX.W-prefixed ADD produced the wrong result")

        print("CBW/CWD/CWDE/CDQE/CDQ/CQO and REX.W override interpreter tests passed")
    }

    static func main() throws {
        let transferMemory = GuestMemory(size: 4096)
        let transferPayload = Data([0x10, 0x20, 0x30, 0x40])
        precondition(transferMemory.write(transferPayload, offset: 0x100))
        var transferDestination = Data(count: 6)
        precondition(transferMemory.read(offset: 0x100, length: 4, into: &transferDestination, destinationOffset: 1))
        precondition(transferDestination == Data([0, 0x10, 0x20, 0x30, 0x40, 0]))
        precondition(!transferMemory.read(offset: 0x100, length: 4, into: &transferDestination, destinationOffset: 4))
        precondition(transferMemory.read(offset: 0x100, length: 0, into: &transferDestination, destinationOffset: 6))

        testExecutePrefixPermissionBoundary()
        try testSignExtensionInstructions()
        try testByteImmediateInstructions()
        try testByteSwapInstructions()
        try testDescriptorBoundELFSnapshot()
        try testRejectsNonRegularELFSnapshot()
        try testFailedPIERelocationClearsGuestMemory()
        if let smokePath = CommandLine.arguments.dropFirst().first {
            try testGeneratedSmokeELF(at: URL(fileURLWithPath: smokePath))
        }
        if let runtimeSmokePath = CommandLine.arguments.dropFirst(2).first {
            try testGeneratedRuntimeSmokeELF(at: URL(fileURLWithPath: runtimeSmokePath))
        }
        if let stdinSmokePath = CommandLine.arguments.dropFirst(3).first {
            try testGeneratedStdinSmokeELF(at: URL(fileURLWithPath: stdinSmokePath))
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
        precondition(exit == .exited(0), "Static ELF guest did not exit with status 0")
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
