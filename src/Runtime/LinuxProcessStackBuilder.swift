import Foundation

struct LinuxProcessStackBuilder {
    struct ProgramHeaders {
        let address: UInt64
        let entrySize: UInt16
        let count: UInt16
    }

    struct Result {
        let stackPointer: UInt64
        let argumentVectorAddress: UInt64
        let environmentVectorAddress: UInt64
        let randomAddress: UInt64
        let executableNameAddress: UInt64
        let stackBase: UInt64
    }

    enum BuildError: LocalizedError {
        case invalidArguments
        case invalidEnvironment
        case stackUnavailable
        case imageOverlapsStack
        case insufficientSpace
        case invalidRandomData

        var errorDescription: String? {
            switch self {
            case .invalidArguments: return "The Linux process argument list is invalid or too large."
            case .invalidEnvironment: return "The Linux process environment is invalid or too large."
            case .stackUnavailable: return "Guest memory is too small for a Linux process stack."
            case .imageOverlapsStack: return "The ELF image overlaps the reserved Linux process stack."
            case .insufficientSpace: return "The Linux process arguments do not fit in the guest stack."
            case .invalidRandomData: return "The Linux process random seed must contain exactly 16 bytes."
            }
        }
    }

    static let stackSize = 1024 * 1024
    static let pageSize: UInt64 = 4096

    func build(executablePath: String, arguments: [String], environment: [String: String],
               memory: GuestMemory, entryPoint: UInt64, programHeaders: ProgramHeaders,
               maximumImageAddress: UInt64, randomBytes: Data? = nil) throws -> Result {
        guard !executablePath.isEmpty, arguments.count <= 4095,
              !executablePath.utf8.contains(0), !arguments.contains(where: { $0.utf8.contains(0) }) else {
            throw BuildError.invalidArguments
        }
        let argumentCount = arguments.count + 1
        guard environment.count <= 4096,
              environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") && !$0.utf8.contains(0) }),
              environment.values.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw BuildError.invalidEnvironment
        }
        let environmentKeys = environment.keys.sorted()
        var totalStringBytes = 0
        func includeStringBytes(_ byteCount: Int) throws {
            let (next, overflow) = totalStringBytes.addingReportingOverflow(byteCount)
            guard !overflow, next <= Self.stackSize / 2 else { throw BuildError.insufficientSpace }
            totalStringBytes = next
        }
        func includeCString(_ value: String) throws {
            let (byteCount, overflow) = value.utf8.count.addingReportingOverflow(1)
            guard !overflow else { throw BuildError.insufficientSpace }
            try includeStringBytes(byteCount)
        }
        try includeCString(executablePath)
        for value in arguments { try includeCString(value) }
        for key in environmentKeys {
            let value = environment[key] ?? ""
            let (keyBytes, keyOverflow) = key.utf8.count.addingReportingOverflow(1)
            let (valueBytes, valueOverflow) = value.utf8.count.addingReportingOverflow(1)
            let (entryBytes, entryOverflow) = keyBytes.addingReportingOverflow(valueBytes)
            guard !keyOverflow, !valueOverflow, !entryOverflow else {
                throw BuildError.insufficientSpace
            }
            try includeStringBytes(entryBytes)
        }
        if let randomBytes, randomBytes.count != 16 { throw BuildError.invalidRandomData }
        guard memory.size > UInt64(Self.stackSize) + Self.pageSize else { throw BuildError.stackUnavailable }

        let alignedTop = memory.size & ~UInt64(0xF)
        let stackBase = alignedTop - UInt64(Self.stackSize)
        guard maximumImageAddress <= stackBase - Self.pageSize else { throw BuildError.imageOverlapsStack }
        let random = randomBytes ?? Self.makeRandomBytes()
        var cursor = Self.stackSize

        func reserveString(_ value: String) throws -> UInt64 {
            let (required, overflow) = value.utf8.count.addingReportingOverflow(1)
            guard !overflow, required <= cursor else { throw BuildError.insufficientSpace }
            cursor -= required
            return stackBase + UInt64(cursor)
        }

        func reserveEnvironmentEntry(_ key: String) throws -> UInt64 {
            let value = environment[key] ?? ""
            let (keyBytes, keyOverflow) = key.utf8.count.addingReportingOverflow(1)
            let (valueBytes, valueOverflow) = value.utf8.count.addingReportingOverflow(1)
            let (required, requiredOverflow) = keyBytes.addingReportingOverflow(valueBytes)
            guard !keyOverflow, !valueOverflow, !requiredOverflow, required <= cursor else {
                throw BuildError.insufficientSpace
            }
            cursor -= required
            return stackBase + UInt64(cursor)
        }

        var environmentPointers: [UInt64] = []
        environmentPointers.reserveCapacity(environmentKeys.count)
        for key in environmentKeys.reversed() {
            environmentPointers.append(try reserveEnvironmentEntry(key))
        }
        environmentPointers.reverse()

        var argumentPointers: [UInt64] = []
        argumentPointers.reserveCapacity(argumentCount)
        for value in arguments.reversed() { argumentPointers.append(try reserveString(value)) }
        argumentPointers.append(try reserveString(executablePath))
        argumentPointers.reverse()

        guard cursor >= 16 else { throw BuildError.insufficientSpace }
        cursor -= 16
        let randomAddress = stackBase + UInt64(cursor)
        let platformAddress = try reserveString("x86_64")

        let auxv: [(UInt64, UInt64)] = [
            (3, programHeaders.address),
            (4, UInt64(programHeaders.entrySize)),
            (5, UInt64(programHeaders.count)),
            (6, Self.pageSize),
            (7, 0),
            (8, 0),
            (9, entryPoint),
            (11, 0),
            (12, 0),
            (13, 0),
            (14, 0),
            (15, platformAddress),
            (16, 0),
            (17, 100),
            (23, 0),
            (25, randomAddress),
            (31, argumentPointers[0]),
            (0, 0)
        ]
        let vectorWordCount = 1 + argumentPointers.count + 1
            + environmentPointers.count + 1 + auxv.count * 2
        let (vectorBytes, vectorBytesOverflow) = vectorWordCount.multipliedReportingOverflow(by: 8)
        guard !vectorBytesOverflow, vectorBytes <= cursor else { throw BuildError.insufficientSpace }
        let vectorStart = (cursor - vectorBytes) & ~15
        var buffer = Data(count: Self.stackSize - vectorStart)
        var writeCursor = Self.stackSize
        func writeString(_ value: String) throws {
            let bytes = value.utf8
            let (required, overflow) = bytes.count.addingReportingOverflow(1)
            guard !overflow, required <= writeCursor else { throw BuildError.insufficientSpace }
            writeCursor -= required
            let offset = writeCursor - vectorStart
            if !bytes.isEmpty { buffer.replaceSubrange(offset..<(offset + bytes.count), with: bytes) }
            buffer[offset + bytes.count] = 0
        }
        for key in environmentKeys.reversed() {
            try writeString("\(key)=\(environment[key] ?? "")")
        }
        for value in arguments.reversed() { try writeString(value) }
        try writeString(executablePath)
        guard writeCursor >= 16 else { throw BuildError.insufficientSpace }
        writeCursor -= 16
        let randomOffset = writeCursor - vectorStart
        buffer.replaceSubrange(randomOffset..<(randomOffset + 16), with: random)
        try writeString("x86_64")
        guard writeCursor == cursor,
              stackBase + UInt64(vectorStart + randomOffset) == randomAddress,
              stackBase + UInt64(writeCursor) == platformAddress else {
            throw BuildError.stackUnavailable
        }

        let vectorWritten = buffer.withUnsafeMutableBytes { destination -> Bool in
            guard let base = destination.baseAddress else { return false }
            var wordIndex = 0
            func writeWord(_ word: UInt64) {
                var littleEndian = word.littleEndian
                withUnsafeBytes(of: &littleEndian) { bytes in
                    if let source = bytes.baseAddress {
                        base.advanced(by: wordIndex * 8)
                            .copyMemory(from: source, byteCount: 8)
                    }
                }
                wordIndex += 1
            }
            writeWord(UInt64(argumentCount))
            for pointer in argumentPointers { writeWord(pointer) }
            writeWord(0)
            for pointer in environmentPointers { writeWord(pointer) }
            writeWord(0)
            for (type, value) in auxv { writeWord(type); writeWord(value) }
            return wordIndex == vectorWordCount
        }
        guard vectorWritten else { throw BuildError.stackUnavailable }

        let stackPointer = stackBase + UInt64(vectorStart)
        guard stackPointer & 0xF == 0,
              memory.write(buffer, sourceRange: 0..<buffer.count, offset: stackPointer) else {
            throw BuildError.stackUnavailable
        }
        let argumentVectorAddress = stackPointer + 8
        let environmentVectorAddress = argumentVectorAddress + UInt64((argumentPointers.count + 1) * 8)
        return Result(stackPointer: stackPointer,
                      argumentVectorAddress: argumentVectorAddress,
                      environmentVectorAddress: environmentVectorAddress,
                      randomAddress: randomAddress,
                      executableNameAddress: argumentPointers[0],
                      stackBase: stackBase)
    }

    private static func makeRandomBytes() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}
