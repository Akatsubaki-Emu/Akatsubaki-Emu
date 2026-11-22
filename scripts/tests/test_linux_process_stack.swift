import Foundation

final class GuestMemory {
    let size: UInt64
    private var bytes: [UInt8]

    init(size: UInt64) {
        self.size = size
        bytes = [UInt8](repeating: 0, count: Int(size))
    }

    func write(_ data: Data, sourceRange: Range<Int>, offset: UInt64) -> Bool {
        guard sourceRange.lowerBound >= 0, sourceRange.upperBound <= data.count,
              offset <= size, UInt64(sourceRange.count) <= size - offset else { return false }
        let destination = Int(offset)
        for index in sourceRange {
            bytes[destination + index - sourceRange.lowerBound] = data[index]
        }
        return true
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

    func readUInt64(offset: UInt64) -> UInt64? {
        guard offset <= size, size - offset >= 8 else { return nil }
        let index = Int(offset)
        var value: UInt64 = 0
        for shift in 0..<8 { value |= UInt64(bytes[index + shift]) << (shift * 8) }
        return value
    }

    func readString(offset: UInt64) -> String? {
        guard offset < size else { return nil }
        var result: [UInt8] = []
        var index = Int(offset)
        while index < bytes.count && bytes[index] != 0 {
            result.append(bytes[index])
            index += 1
        }
        return String(bytes: result, encoding: .utf8)
    }
}

@main
struct LinuxProcessStackTests {
    static func main() throws {
        let memory = GuestMemory(size: 4 * 1024 * 1024)
        let random = Data(repeating: 0xA5, count: 16)
        let result = try LinuxProcessStackBuilder().build(
            executablePath: "/bin/hello",
            arguments: ["--version", "--verbose"],
            environment: ["PATH": "/bin:/usr/bin", "HOME": "/root"],
            memory: memory,
            entryPoint: 0x41000,
            programHeaders: .init(address: 0x40040, entrySize: 56, count: 4),
            maximumImageAddress: 0x50000,
            randomBytes: random
        )

        precondition(result.stackPointer & 0xF == 0)
        precondition(result.stackBase == 0x300000)
        precondition(memory.readUInt64(offset: result.stackPointer) == 3)
        precondition(memory.readString(offset: memory.readUInt64(offset: result.argumentVectorAddress)!) == "/bin/hello")
        precondition(memory.readString(offset: memory.readUInt64(offset: result.argumentVectorAddress + 8)!) == "--version")
        precondition(memory.readString(offset: memory.readUInt64(offset: result.argumentVectorAddress + 16)!) == "--verbose")
        precondition(memory.readUInt64(offset: result.argumentVectorAddress + 24) == 0)
        precondition(memory.readString(offset: result.executableNameAddress) == "/bin/hello")
        precondition((0..<16).allSatisfy {
            memory.readByte(offset: result.randomAddress + UInt64($0)) == 0xA5
        })

        let environmentStart = result.environmentVectorAddress
        precondition(memory.readString(offset: memory.readUInt64(offset: environmentStart)!) == "HOME=/root")
        precondition(memory.readString(offset: memory.readUInt64(offset: environmentStart + 8)!) == "PATH=/bin:/usr/bin")
        precondition(memory.readUInt64(offset: environmentStart + 16) == 0)

        let auxvStart = environmentStart + 24
        var auxiliary: [UInt64: UInt64] = [:]
        var cursor = auxvStart
        while let type = memory.readUInt64(offset: cursor),
              let value = memory.readUInt64(offset: cursor + 8), type != 0 {
            auxiliary[type] = value
            cursor += 16
        }
        precondition(auxiliary[3] == 0x40040)
        precondition(auxiliary[4] == 56)
        precondition(auxiliary[5] == 4)
        precondition(auxiliary[6] == 4096)
        precondition(auxiliary[9] == 0x41000)
        precondition(auxiliary[25] == result.randomAddress)
        precondition(auxiliary[31] == result.executableNameAddress)
        precondition(memory.readUInt64(offset: cursor) == 0)
        precondition(memory.readUInt64(offset: cursor + 8) == 0)

        do {
            _ = try LinuxProcessStackBuilder().build(
                executablePath: "/bad", arguments: [],
                environment: ["BAD=KEY": "x"], memory: memory,
                entryPoint: 1,
                programHeaders: .init(address: 0, entrySize: 56, count: 1),
                maximumImageAddress: 0x50000, randomBytes: random
            )
            preconditionFailure("Invalid environment should fail.")
        } catch LinuxProcessStackBuilder.BuildError.invalidEnvironment {}

        do {
            _ = try LinuxProcessStackBuilder().build(
                executablePath: "/bad", arguments: ["\u{0}"],
                environment: [:], memory: memory, entryPoint: 1,
                programHeaders: .init(address: 0, entrySize: 56, count: 1),
                maximumImageAddress: 0x50000, randomBytes: random
            )
            preconditionFailure("Invalid argument should fail.")
        } catch LinuxProcessStackBuilder.BuildError.invalidArguments {}

        do {
            _ = try LinuxProcessStackBuilder().build(
                executablePath: "/bad", arguments: [], environment: [:],
                memory: memory, entryPoint: 1,
                programHeaders: .init(address: 0, entrySize: 56, count: 1),
                maximumImageAddress: 0x3F0000, randomBytes: random
            )
            preconditionFailure("Image/stack overlap should fail.")
        } catch LinuxProcessStackBuilder.BuildError.imageOverlapsStack {}

        do {
            _ = try LinuxProcessStackBuilder().build(
                executablePath: "/bad", arguments: [], environment: [:],
                memory: memory, entryPoint: 1,
                programHeaders: .init(address: 0, entrySize: 56, count: 1),
                maximumImageAddress: 0x50000, randomBytes: Data([0x01])
            )
            preconditionFailure("Invalid random data should fail.")
        } catch LinuxProcessStackBuilder.BuildError.invalidRandomData {}

        print("Linux x86-64 initial stack, argv/envp, auxv and bounds tests passed")
    }
}
