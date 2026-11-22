import Foundation

/// The AArch64 block ABI is deliberately small and stable:
/// - x0 carries a pointer to sixteen contiguous UInt64 guest registers.
/// - x16 retains that pointer while x0...x15 hold guest RAX...R15.
/// - the translated body may only use x0...x15.
/// - the epilogue writes every guest register back and returns through x30.
///
/// The current translator emits only flag-neutral register/immediate MOV and
/// NOP instructions. Memory, flags, branches, syscalls and privileged state
/// remain interpreter side-exits.
struct KenranButoAOTBlock {
    static let guestRegisterCount = 16
    static let maximumBlockBytes = 4_096

    let machineCode: Data
    let guestBytesConsumed: Int
    let instructionCount: Int

    enum BlockError: LocalizedError {
        case invalidTranslation
        case blockTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidTranslation:
                return "The AOT translation cannot be wrapped in the guest-register ABI."
            case .blockTooLarge:
                return "The wrapped AOT block exceeds the executable-memory limit."
            }
        }
    }

    static func build(from translation: X86_64AOTTranslation) throws -> KenranButoAOTBlock {
        guard translation.isCacheable,
              translation.guestBytesConsumed > 0,
              translation.instructionCount > 0,
              !translation.machineCode.isEmpty,
              translation.machineCode.count.isMultiple(of: 4),
              translation.machineCode.count <= maximumBlockBytes else {
            throw BlockError.invalidTranslation
        }

        var code = Data()
        code.reserveCapacity(4 * (1 + guestRegisterCount * 2 + translation.machineCode.count / 4 + 1))

        // mov x16, x0 — preserve the guest-state pointer outside the guest GPR set.
        appendWord(0xAA0003F0, to: &code)

        // ldr xN, [x16, #(N * 8)] — load guest GPRs into caller-saved x0...x15.
        for register in 0..<guestRegisterCount {
            let index = UInt32(register)
            let instruction = 0xF9400000 | (index << 10) | (UInt32(16) << 5) | index
            appendWord(instruction, to: &code)
        }

        code.append(translation.machineCode)

        // str xN, [x16, #(N * 8)] — persist the guest GPRs before returning.
        for register in 0..<guestRegisterCount {
            let index = UInt32(register)
            let instruction = 0xF9000000 | (index << 10) | (UInt32(16) << 5) | index
            appendWord(instruction, to: &code)
        }

        // ret — x30 is untouched by the translator and remains the host return address.
        appendWord(0xD65F03C0, to: &code)

        guard code.count <= maximumBlockBytes else {
            throw BlockError.blockTooLarge
        }

        return KenranButoAOTBlock(
            machineCode: code,
            guestBytesConsumed: translation.guestBytesConsumed,
            instructionCount: translation.instructionCount
        )
    }

    private static func appendWord(_ instruction: UInt32, to data: inout Data) {
        var littleEndian = instruction.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

/// Owns one sealed executable mapping. Writable memory is never exposed after
/// creation; on iOS 26+ TXM devices the C provider keeps separate RW/RX aliases
/// and leaves the StikDebug session attached.
final class KenranButoExecutableMemory {
    private let region: OpaquePointer

    static var isAvailable: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        // The standalone AOT allocator currently supports only the tested
        // StikDebug/TXM split-WX protocol. Standard iOS JIT remains on the
        // interpreter path until its allocator is independently implemented.
        guard iSteamJITGetProtocolMode() == ISTEAM_JIT_PROTOCOL_STIKDEBUG else {
            return false
        }
        return JITCoordinator.shared.isQEMUJITReady
            && iSteamAOTExecutableMemoryIsAvailable()
        #else
        return iSteamAOTExecutableMemoryIsAvailable()
        #endif
    }

    init(code: Data) throws {
        var errorBuffer = [CChar](repeating: 0, count: 256)
        let createdRegion = code.withUnsafeBytes { codeBytes in
            errorBuffer.withUnsafeMutableBufferPointer { errorBytes in
                iSteamAOTExecutableMemoryCreate(
                    codeBytes.baseAddress,
                    codeBytes.count,
                    errorBytes.baseAddress,
                    errorBytes.count
                )
            }
        }

        guard let createdRegion else {
            let message = String(cString: errorBuffer)
            throw NSError(
                domain: "KenranButoAOT",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message.isEmpty
                    ? "The platform refused executable memory." : message]
            )
        }
        guard iSteamAOTExecutableMemoryEntry(createdRegion) != nil else {
            iSteamAOTExecutableMemoryDestroy(createdRegion)
            throw NSError(
                domain: "KenranButoAOT",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The executable region has no entry point."]
            )
        }

        region = createdRegion
    }

    func execute(registers: inout [UInt64]) -> Bool {
        guard registers.count == KenranButoAOTBlock.guestRegisterCount else { return false }
        return registers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            return iSteamAOTExecutableMemoryInvoke(region, baseAddress)
        }
    }

    deinit {
        iSteamAOTExecutableMemoryDestroy(region)
    }
}

/// Executes validated AOT blocks when the host has an approved executable-memory
/// path. If JIT/TXM setup is absent, translation fails, or a block is unsupported,
/// the caller receives nil and continues in the x86-64 interpreter.
final class KenranButoAOTExecutor: X86_64AOTExecuting {
    private struct BlockKey: Hashable {
        let guestCode: Data
        let maximumInstructions: Int
        let guestABI: String
    }

    private struct CachedBlock {
        let memory: KenranButoExecutableMemory
        let guestBytesConsumed: Int
        let instructionCount: Int
    }

    private let compiler: KenranButoAOTCompiler
    private let translator: X86_64AOTTranslator
    private let guestABI: String
    private let lock = NSLock()
    private var blocks: [BlockKey: CachedBlock] = [:]
    private var insertionOrder: [BlockKey] = []
    private let maximumCachedBlocks = 64

    init(guestABI: String = "sysv-linux-x86_64",
         compiler: KenranButoAOTCompiler = KenranButoAOTCompiler(),
         translator: X86_64AOTTranslator = X86_64AOTTranslator()) {
        self.guestABI = guestABI
        self.compiler = compiler
        self.translator = translator
    }

    var isAvailable: Bool {
        KenranButoExecutableMemory.isAvailable
    }

    func execute(guestCode: Data,
                 registers: inout [UInt64],
                 maximumInstructions: Int) -> X86_64AOTExecutionResult? {
        guard isAvailable,
              !guestCode.isEmpty,
              registers.count == KenranButoAOTBlock.guestRegisterCount,
              maximumInstructions > 0 else {
            return nil
        }

        let instructionBudget = min(maximumInstructions, X86_64AOTTranslator.maximumInstructionBudget)
        let translation: X86_64AOTTranslation
        if let cached = try? compiler.compile(guestCode, guestABI: guestABI, maximumInstructions: instructionBudget) {
            translation = cached.translation
        } else {
            translation = translator.translate(guestCode)
        }

        guard translation.isCacheable,
              translation.isValid(for: guestCode),
              translation.instructionCount <= instructionBudget,
              translation.guestBytesConsumed <= guestCode.count else {
            return nil
        }

        let key = BlockKey(
            guestCode: guestCode,
            maximumInstructions: instructionBudget,
            guestABI: guestABI
        )

        guard let block = executableBlock(for: key, translation: translation),
              block.memory.execute(registers: &registers) else {
            return nil
        }

        return X86_64AOTExecutionResult(
            guestBytesConsumed: block.guestBytesConsumed,
            instructionCount: block.instructionCount
        )
    }

    private func executableBlock(for key: BlockKey,
                                 translation: X86_64AOTTranslation) -> CachedBlock? {
        lock.lock()
        if let cached = blocks[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let wrapped = try? KenranButoAOTBlock.build(from: translation),
              let memory = try? KenranButoExecutableMemory(code: wrapped.machineCode) else {
            return nil
        }
        let candidate = CachedBlock(
            memory: memory,
            guestBytesConsumed: wrapped.guestBytesConsumed,
            instructionCount: wrapped.instructionCount
        )

        lock.lock()
        defer { lock.unlock() }
        if let winner = blocks[key] {
            return winner
        }
        blocks[key] = candidate
        insertionOrder.append(key)
        if insertionOrder.count > maximumCachedBlocks {
            let expired = insertionOrder.removeFirst()
            blocks.removeValue(forKey: expired)
        }
        return candidate
    }
}
