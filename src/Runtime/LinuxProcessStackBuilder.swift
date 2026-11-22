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
        let argv = [executablePath] + arguments
        guard environment.count <= 4096,
              environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") && !$0.utf8.contains(0) }),
              environment.values.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw BuildError.invalidEnvironment
        }
        let envp = environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
        var totalStringBytes = 0
        for value in argv + envp {
            let (next, overflow) = totalStringBytes.addingReportingOverflow(value.utf8.count + 1)
            guard !overflow, next <= Self.stackSize / 2 else { throw BuildError.insufficientSpace }
            totalStringBytes = next
        }
        if let randomBytes, randomBytes.count != 16 { throw BuildError.invalidRandomData }
        guard memory.size > UInt64(Self.stackSize) + Self.pageSize else { throw BuildError.stackUnavailable }

        let alignedTop = memory.size & ~(Self.pageSize - 1)
        let stackBase = alignedTop - UInt64(Self.stackSize)
        guard maximumImageAddress <= stackBase - Self.pageSize else { throw BuildError.imageOverlapsStack }
        guard memory.map(offset: stackBase, length: UInt64(Self.stackSize),
                          permissions: [.read, .write]) else {
            throw BuildError.stackUnavailable
        }
        let random = randomBytes ?? Self.makeRandomBytes()
        var buffer = Data(count: Self.stackSize)
        var cursor = Self.stackSize

        func pushString(_ value: String) throws -> UInt64 {
            let bytes = value.utf8
            let required = bytes.count + 1
            guard required <= cursor else { throw BuildError.insufficientSpace }
            cursor -= required
            if !bytes.isEmpty { buffer.replaceSubrange(cursor..<(cursor + bytes.count), with: bytes) }
            buffer[cursor + bytes.count] = 0
            return stackBase + UInt64(cursor)
        }

        var environmentPointers: [UInt64] = []
        for value in envp.reversed() { environmentPointers.append(try pushString(value)) }
        environmentPointers.reverse()

        var argumentPointers: [UInt64] = []
        for value in argv.reversed() { argumentPointers.append(try pushString(value)) }
        argumentPointers.reverse()

        cursor -= 16
        buffer.replaceSubrange(cursor..<(cursor + 16), with: random)
        let randomAddress = stackBase + UInt64(cursor)
        let platformAddress = try pushString("x86_64")

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
        var words: [UInt64] = [UInt64(argv.count)]
        words.append(contentsOf: argumentPointers)
        words.append(0)
        words.append(contentsOf: environmentPointers)
        words.append(0)
        for (type, value) in auxv { words.append(type); words.append(value) }

        let vectorBytes = words.count * 8
        guard vectorBytes <= cursor else { throw BuildError.insufficientSpace }
        let vectorStart = (cursor - vectorBytes) & ~15
        let vectorWritten = buffer.withUnsafeMutableBytes { destination -> Bool in
            guard let base = destination.baseAddress else { return false }
            for (index, word) in words.enumerated() {
                var littleEndian = word.littleEndian
                withUnsafeBytes(of: &littleEndian) { bytes in
                    if let source = bytes.baseAddress {
                        base.advanced(by: vectorStart + index * 8)
                            .copyMemory(from: source, byteCount: 8)
                    }
                }
            }
            return true
        }
        guard vectorWritten else { throw BuildError.stackUnavailable }

        let stackPointer = stackBase + UInt64(vectorStart)
        guard stackPointer & 0xF == 0,
              memory.write(buffer, sourceRange: vectorStart..<Self.stackSize, offset: stackPointer) else {
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
