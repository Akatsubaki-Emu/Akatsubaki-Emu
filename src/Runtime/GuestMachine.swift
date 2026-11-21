import Foundation

/// CPU backend boundary. A real emulator implementation must be supplied.
protocol GuestCPUBackend: AnyObject {
    var architecture: VMConfiguration.Architecture { get }
    var instructionCount: UInt64 { get }
    func reset(entryPoint: UInt64) throws
    func setInitialStackPointer(_ pointer: UInt64) throws
    func configureLinuxProcess(programBreak: UInt64, stackBase: UInt64) throws
    func run(maxInstructions: UInt64) throws -> GuestCPUExit
    func requestStop()
    func resume()
}

enum GuestCPUExit: Equatable {
    case instructionLimit
    case halted
    case interrupted
    case unsupportedInstruction(address: UInt64)
    case memoryFault(address: UInt64)
    case backendUnavailable(String)
}

enum GuestEngineError: LocalizedError {
    case invalidInstructionBudget
    case backendNotInstalled(VMConfiguration.Architecture)
    case memoryUnavailable
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case .invalidInstructionBudget:
            return "The guest CPU instruction budget must be greater than zero."
        case .backendNotInstalled(let architecture):
            return "No guest CPU backend is installed for \(architecture.rawValue)."
        case .memoryUnavailable:
            return "Native guest memory could not be allocated on this device."
        case .invalidState(let detail):
            return detail
        }
    }
}

final class GuestMachine {
    enum State: Equatable {
        case stopped, configured, running, paused, failed(String)
    }

    let configuration: VMConfiguration
    let memory: GuestMemory
    /// Host services available to a future CPU/network backend adapter.
    let hostBridge = HostDeviceBridge.shared
    private(set) var state: State = .stopped
    private(set) var lastExit: GuestCPUExit?
    private var cpu: GuestCPUBackend?
    private var hasLoadedImage = false
    private var loadedEntryPoint: UInt64?
    private var initialStackPointer: UInt64?
    private var initialProgramBreak: UInt64?
    private var initialStackBase: UInt64?
    private let executionLock = NSLock()
    private let activeCPULock = NSLock()
    private var activeCPU: GuestCPUBackend?

    private static func alignGuestAddress(_ address: UInt64) throws -> UInt64 {
        let (sum, overflow) = address.addingReportingOverflow(4095)
        guard !overflow else { throw GuestEngineError.invalidState("The ELF image end address overflows the guest address space.") }
        return sum & ~UInt64(4095)
    }

    private func withExecutionLock<T>(_ body: () throws -> T) rethrows -> T {
        executionLock.lock()
        defer { executionLock.unlock() }
        return try body()
    }

    private func setActiveCPU(_ backend: GuestCPUBackend?) {
        activeCPULock.lock()
        activeCPU = backend
        activeCPULock.unlock()
    }

    /// Requests interruption without waiting for executionLock, which is held
    /// for the duration of runBatch. The lock protects the backend reference
    /// while installCPUBackend swaps it between batches.
    @discardableResult
    private func requestActiveStop() -> Bool {
        activeCPULock.lock()
        let backend = activeCPU
        activeCPULock.unlock()
        backend?.requestStop()
        return backend != nil
    }

    init(configuration: VMConfiguration, memorySize: UInt64? = nil) {
        self.configuration = configuration
        // Keep malformed or imported configurations from overflowing the
        // byte conversion or requesting unbounded host memory in this prototype.
        let maximumGuestBytes: UInt64 = 16 * 1024 * 1024 * 1024
        let requestedMB = min(max(configuration.memoryMB, 256), 16_384)
        let defaultSize = UInt64(requestedMB) * 1024 * 1024
        let requestedSize = memorySize.map { min(max($0, GuestMemory.pageSize), maximumGuestBytes) } ?? defaultSize
        self.memory = GuestMemory(size: requestedSize)
        guard self.memory.isAvailable else {
            self.state = .failed("Unable to create the native guest-memory store.")
            return
        }
        // Ship the small x86-64 interpreter as the first runnable backend.
        // Other architectures still require a compatible backend integration.
        if configuration.architecture == .x86_64 {
            self.cpu = X86_64Interpreter(memory: self.memory)
            self.state = .configured
        } else {
            self.state = .failed(
                GuestEngineError.backendNotInstalled(configuration.architecture).localizedDescription
            )
        }
    }

    /// Host device details for a guest RPC adapter. This is not guest-visible
    /// until a backend implements a transport (virtio-serial or a virtual NIC).
    func hostDeviceInfo() -> HostDeviceBridge.DeviceInfo {
        hostBridge.deviceInfo()
    }

    func readHostSharedFile(relativePath: String) throws -> Data {
        try hostBridge.readSharedFile(relativePath: relativePath)
    }

    func writeHostSharedFile(_ data: Data, relativePath: String) throws {
        try hostBridge.writeSharedFile(data, relativePath: relativePath)
    }

    func installCPUBackend(_ backend: GuestCPUBackend) throws {
        guard memory.isAvailable else { throw GuestEngineError.memoryUnavailable }
        guard backend.architecture == configuration.architecture else {
            throw GuestEngineError.backendNotInstalled(configuration.architecture)
        }
        try withExecutionLock {
            if hasLoadedImage {
                guard let loadedEntryPoint, let currentCPU = cpu else {
                    throw GuestEngineError.invalidState("The loaded guest image has no saved entry point or active CPU.")
                }
                try currentCPU.reset(entryPoint: loadedEntryPoint)
                if let initialStackPointer { try currentCPU.setInitialStackPointer(initialStackPointer) }
                try backend.reset(entryPoint: loadedEntryPoint)
                if let initialStackPointer { try backend.setInitialStackPointer(initialStackPointer) }
                if let initialProgramBreak, let initialStackBase {
                    try backend.configureLinuxProcess(programBreak: initialProgramBreak, stackBase: initialStackBase)
                }
            }
            cpu?.requestStop()
            backend.resume()
            cpu = backend
            state = .configured
            lastExit = nil
        }
    }

    /// Loads an ELF64 image into guest memory and initializes the CPU at its
    /// entry point. Loading requires a compatible, real CPU backend to be installed.
    @discardableResult
    func loadELFImage(at url: URL, arguments: [String] = [], environment: [String: String] = [:]) throws -> ELF64Loader.Image {
        guard memory.isAvailable else { throw GuestEngineError.memoryUnavailable }
        return try withExecutionLock {
            guard let cpu else {
                let error = GuestEngineError.backendNotInstalled(configuration.architecture)
                state = .failed(error.localizedDescription)
                throw error
            }
            do {
                hasLoadedImage = false
                loadedEntryPoint = nil
                initialStackPointer = nil
                initialProgramBreak = nil
                initialStackBase = nil
                guard configuration.architecture == .x86_64 else {
                    throw GuestEngineError.backendNotInstalled(configuration.architecture)
                }
                try cpu.reset(entryPoint: 0)
                let image = try ELF64Loader().load(url, into: memory,
                                                   expectedArchitecture: configuration.architecture)
                let stack = try LinuxProcessStackBuilder().build(
                    executablePath: url.path,
                    arguments: arguments,
                    environment: environment,
                    memory: memory,
                    entryPoint: image.entryPoint,
                    programHeaders: .init(address: image.programHeaderAddress,
                                          entrySize: image.programHeaderEntrySize,
                                          count: image.programHeaderCount),
                    maximumImageAddress: image.maximumGuestAddress
                )
                try cpu.reset(entryPoint: image.entryPoint)
                try cpu.setInitialStackPointer(stack.stackPointer)
                let programBreak = try Self.alignGuestAddress(image.maximumGuestAddress)
                try cpu.configureLinuxProcess(programBreak: programBreak, stackBase: stack.stackBase)
                initialStackPointer = stack.stackPointer
                initialProgramBreak = programBreak
                initialStackBase = stack.stackBase
                loadedEntryPoint = image.entryPoint
                hasLoadedImage = true
                lastExit = nil
                state = .configured
                return image
            } catch {
                state = .failed(error.localizedDescription)
                throw error
            }
        }
    }

    /// Resets CPU registers only. Loaded guest memory is deliberately preserved.
    func reset(entryPoint: UInt64) throws {
        guard memory.isAvailable else { throw GuestEngineError.memoryUnavailable }
        try withExecutionLock {
            guard hasLoadedImage else {
                throw GuestEngineError.invalidState("Load a valid ELF image before resetting the guest CPU.")
            }
            guard let cpu else {
                let error = GuestEngineError.backendNotInstalled(configuration.architecture)
                state = .failed(error.localizedDescription)
                throw error
            }
            do {
                try cpu.reset(entryPoint: entryPoint)
                if let initialStackPointer { try cpu.setInitialStackPointer(initialStackPointer) }
                if let initialProgramBreak, let initialStackBase {
                    try cpu.configureLinuxProcess(programBreak: initialProgramBreak, stackBase: initialStackBase)
                }
                loadedEntryPoint = entryPoint
                lastExit = nil
                state = .configured
            } catch {
                state = .failed(error.localizedDescription)
                throw error
            }
        }
    }

    @discardableResult
    func runBatch(maxInstructions: UInt64) throws -> GuestCPUExit {
        guard maxInstructions > 0 else { throw GuestEngineError.invalidInstructionBudget }
        guard memory.isAvailable else { throw GuestEngineError.memoryUnavailable }
        return try withExecutionLock {
            guard hasLoadedImage else {
                throw GuestEngineError.invalidState("Load a valid ELF image before running the guest CPU.")
            }
            guard state == .configured else {
                throw GuestEngineError.invalidState("The guest must be configured before running; resume a paused guest or load/reset an image first.")
            }
            guard let cpu else {
                let error = GuestEngineError.backendNotInstalled(configuration.architecture)
                state = .failed(error.localizedDescription)
                throw error
            }

            setActiveCPU(cpu)
            defer { setActiveCPU(nil) }
            state = .running
            do {
                let exit = try cpu.run(maxInstructions: maxInstructions)
                lastExit = exit
                switch exit {
                case .instructionLimit: state = .configured
                case .interrupted: state = .paused
                case .halted: state = .stopped
                case .unsupportedInstruction, .memoryFault, .backendUnavailable:
                    state = .failed(String(describing: exit))
                }
                return exit
            } catch {
                state = .failed(error.localizedDescription)
                throw error
            }
        }
    }

    func pause() {
        let wasExecuting = requestActiveStop()
        withExecutionLock {
            // runBatch normally records .paused after observing the stop request.
            // If its instruction budget ended first, preserve the user's pause.
            if wasExecuting && state == .configured {
                state = .paused
            }
        }
    }

    func stop() {
        requestActiveStop()
        withExecutionLock {
            cpu?.requestStop()
            memory.clear()
            hasLoadedImage = false
            loadedEntryPoint = nil
            initialStackPointer = nil
            initialProgramBreak = nil
            initialStackBase = nil
            state = .stopped
            lastExit = nil
        }
    }

    /// Resumes a paused interpreter without resetting registers or guest memory.
    @discardableResult
    func resume() -> Bool {
        withExecutionLock {
            guard state == .paused, let cpu else { return false }
            cpu.resume()
            state = .configured
            return true
        }
    }

}
