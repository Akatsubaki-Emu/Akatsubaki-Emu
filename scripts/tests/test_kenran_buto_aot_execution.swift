import Foundation

struct X86_64AOTExecutionResult {
    let guestBytesConsumed: Int
    let instructionCount: Int
}

protocol X86_64AOTExecuting {
    var isAvailable: Bool { get }
    func execute(guestCode: Data,
                 registers: inout [UInt64],
                 maximumInstructions: Int) -> X86_64AOTExecutionResult?
}

@main
struct KenranButoAOTExecutionTests {
    private static func word(_ data: Data, _ index: Int) -> UInt32 {
        let offset = index * 4
        precondition(offset >= 0 && data.count - offset >= 4)
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    static func main() throws {
        // MOV EAX,42; MOV EBX,7; MOV RAX,RBX; NOP; ADD EAX,EBX.
        // The first four instructions are AOT-safe; ADD must side-exit.
        let guest = Data([
            0xB8, 0x2A, 0x00, 0x00, 0x00,
            0xBB, 0x07, 0x00, 0x00, 0x00,
            0x48, 0x89, 0xD8,
            0x90,
            0x01, 0xD8
        ])
        let translator = X86_64AOTTranslator()
        let translation = translator.translate(guest)
        precondition(translation.isCacheable)
        precondition(translation.instructionCount == 4)
        precondition(translation.guestBytesConsumed == 14)
        precondition(translation.stopReason == .unsupportedInstruction)
        precondition(translation.fallbackOffset == 14)

        let block = try KenranButoAOTBlock.build(from: translation)
        precondition(word(block.machineCode, 0) == 0xAA0003F0) // mov x16, x0
        precondition(word(block.machineCode, 1) == 0xF9400200) // ldr x0, [x16]
        precondition(word(block.machineCode, 16) == 0xF9403E0F) // ldr x15, [x16, #120]
        precondition(word(block.machineCode, 17) == word(translation.machineCode, 0))
        precondition(word(block.machineCode, 21) == 0xF9000200) // str x0, [x16]
        precondition(word(block.machineCode, 36) == 0xF9003E0F) // str x15, [x16, #120]
        precondition(word(block.machineCode, 37) == 0xD65F03C0) // ret

        guard KenranButoExecutableMemory.isAvailable else {
            print("Kenran Butō AOT block ABI passed; native execution skipped because this host has no ARM64 executable-memory provider")
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kenran-buto-aot-execution-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let compiler = KenranButoAOTCompiler(cache: TranslationCache(directory: directory))
        let executor = KenranButoAOTExecutor(compiler: compiler, translator: translator)
        var registers = (0..<16).map { UInt64.max &- UInt64($0) }
        let untouched = registers
        let result = executor.execute(
            guestCode: guest,
            registers: &registers,
            maximumInstructions: 8
        )

        precondition(result?.guestBytesConsumed == 14)
        precondition(result?.instructionCount == 4)
        precondition(registers[0] == 7)
        precondition(registers[3] == 7)
        for index in registers.indices where index != 0 && index != 3 {
            precondition(registers[index] == untouched[index])
        }

        // A block longer than the remaining interpreter budget must not run.
        var limitedRegisters = untouched
        let limited = executor.execute(
            guestCode: guest,
            registers: &limitedRegisters,
            maximumInstructions: 1
        )
        precondition(limited == nil)
        precondition(limitedRegisters == untouched)

        print("Kenran Butō AOT ARM64 block ABI, executable dispatch, register preservation, instruction accounting and side-exit passed")
    }
}
